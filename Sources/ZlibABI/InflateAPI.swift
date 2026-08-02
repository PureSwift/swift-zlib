// InflateAPI.swift - the streaming decompression entry points
//
// This is the half that reads untrusted bytes, and the half most consumers actually use:
// `uncompress` exists for when the whole input is in memory, and everything else goes through
// here.
//
// The delicate part is not the decoding, which is the engine's. It is `avail_in`. zlib promises
// that when a stream ends, `next_in` points at the byte *after* it — that is how a caller finds
// a second member, or the data following an embedded stream. Getting it wrong is invisible in
// a single-stream round trip and breaks every concatenated one.
//
// What makes it simple here is a property of the reader underneath rather than anything done at
// this level: it never takes a byte it was not about to read from, so every byte it has taken
// is one the stream genuinely used, and the count needs no adjusting. Trying to correct for
// read-ahead at this level instead is worse than unnecessary — a byte held back is a byte the
// caller offers again and this layer skips again, and the stream stops dead.

import CZlib
import LZ77
import Zlib

final class InflateStream {
    enum Engine {
        case zlib(Decompressor)
        case raw(Inflate)
    }

    var engine: Engine
    var wrapper: Wrapper
    var windowBits: Int32

    /// Set once the stream has reported `Z_STREAM_END`, so that calling again is a no-op rather
    /// than a second attempt at a finished stream.
    var ended = false

    init(wrapper: Wrapper, windowBits: Int32) {
        self.wrapper = wrapper
        self.windowBits = windowBits
        self.engine = wrapper == .raw ? .raw(Inflate()) : .zlib(Decompressor())
    }

    func reset() {
        self.engine = self.wrapper == .raw ? .raw(Inflate()) : .zlib(Decompressor())
        self.ended = false
    }

    var isFinished: Bool {
        switch self.engine {
        case let .zlib(stream): return stream.isFinished
        case let .raw(stream): return stream.isFinished
        }
    }

    /// The running checksum, which the caller reads from `strm.adler`.
    ///
    /// Raw streams carry no checksum, and the reference leaves the field alone for them.
    var checksum: UInt32? {
        switch self.engine {
        case let .zlib(stream): return stream.checksum
        case .raw: return nil
        }
    }

    var pulledInputCount: Int {
        switch self.engine {
        case let .zlib(stream): return stream.pulledInputCount
        case let .raw(stream): return stream.pulledInputCount
        }
    }

    func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        switch self.engine {
        case let .zlib(stream): stream.setInput(bytes)
        case let .raw(stream): stream.setInput(bytes)
        }
    }

    func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(DeflateError) -> Int {
        switch self.engine {
        case let .zlib(stream): return try stream.inflate(into: destination, count: count)
        case let .raw(stream): return try stream.inflate(into: destination, count: count)
        }
    }
}

@c @implementation
public func inflateInit_(
    _ strm: z_streamp!,
    _ version: UnsafePointer<CChar>!,
    _ stream_size: Int32
) -> Int32 {
    inflateInit2_(strm, 15, version, stream_size)
}

@c @implementation
public func inflateInit2_(
    _ strm: z_streamp!,
    _ windowBits: Int32,
    _ version: UnsafePointer<CChar>!,
    _ stream_size: Int32
) -> Int32 {
    if let failure = checkInitArguments(version, stream_size) { return failure }
    guard let strm else { return Status.streamError }

    guard let (wrapper, bits) = Wrapper.forWindowBits(windowBits) else {
        setMessage(strm, zError(Status.streamError))
        return Status.streamError
    }

    guard wrapper != .unsupported else {
        // Reported rather than silently decoded as zlib: gzip framing that is read as a zlib
        // header produces a plausible-looking failure much later, or worse, does not fail.
        swiftzlib_report_unimplemented("inflateInit2_ with gzip or automatic window bits")
        setMessage(strm, zError(Status.streamError))
        return Status.streamError
    }

    strm.pointee.msg = nil
    strm.pointee.total_in = 0
    strm.pointee.total_out = 0
    strm.pointee.adler = 1
    strm.pointee.data_type = 2 // Z_UNKNOWN, until the stream says otherwise.

    attach(InflateStream(wrapper: wrapper, windowBits: bits), to: strm)

    return Status.ok
}

@c @implementation
public func inflate(_ strm: z_streamp!, _ flush: Int32) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    guard strm.pointee.next_out != nil || strm.pointee.avail_out == 0 else {
        return Status.streamError
    }

    if state.ended { return Status.streamEnd }

    let available = Int(strm.pointee.avail_in)

    if available > 0, let next = strm.pointee.next_in {
        state.setInput(UnsafeBufferPointer(start: next, count: available))
    } else {
        state.setInput(UnsafeBufferPointer(start: nil, count: 0))
    }

    var produced = 0
    let capacity = Int(strm.pointee.avail_out)

    do {
        produced = try state.inflate(
            into: strm.pointee.next_out ?? UnsafeMutablePointer(bitPattern: 1)!,
            count: capacity
        )
    } catch {
        // A malformed stream, a bad checksum, a distance reaching out of the window: the data
        // is wrong, which is a different thing from this library being unable to continue, and
        // callers act on the difference.
        _ = consume(strm, state, produced: 0)
        setMessage(strm, zError(Status.dataError))
        return Status.dataError
    }

    let used = consume(strm, state, produced: produced)

    if state.isFinished {
        state.ended = true
        return Status.streamEnd
    }

    // Nothing taken and nothing made: no progress was possible, and this call repeated with the
    // same arguments would do nothing again. Saying Z_OK here is what spins a caller's loop
    // forever, since Z_OK is exactly the answer that means "call me again".
    //
    // Not fatal, and not the same as an error in the data: the caller supplies more input or
    // more room and carries on. `flush` does not enter into it — a starved stream is starved
    // whether or not the caller has said there is more coming.
    if used == 0, produced == 0 {
        return Status.bufferError
    }

    return Status.ok
}

/// Writes back everything the caller reads after a call: how much input went, how much output
/// came, and the checksum so far. Returns how much input was used.
@discardableResult
private func consume(
    _ strm: z_streamp,
    _ state: InflateStream,
    produced: Int
) -> Int {
    let used = state.pulledInputCount

    if used > 0 {
        strm.pointee.next_in += used
        strm.pointee.avail_in -= UInt32(used)
        strm.pointee.total_in += UInt(used)
    }

    if produced > 0 {
        strm.pointee.next_out += produced
        strm.pointee.avail_out -= UInt32(produced)
        strm.pointee.total_out += UInt(produced)
    }

    if let checksum = state.checksum {
        strm.pointee.adler = UInt(checksum)
    }

    return used
}

@c @implementation
public func inflateEnd(_ strm: z_streamp!) -> Int32 {
    guard let strm, attached(strm, as: InflateStream.self) != nil else {
        return Status.streamError
    }

    detach(strm, as: InflateStream.self)
    return Status.ok
}

@c @implementation
public func inflateReset(_ strm: z_streamp!) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    state.reset()
    strm.pointee.total_in = 0
    strm.pointee.total_out = 0
    strm.pointee.adler = 1
    strm.pointee.msg = nil

    return Status.ok
}

/// Resets without clearing the counters, which is what the gz layer wants between members.
@c @implementation
public func inflateResetKeep(_ strm: z_streamp!) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    state.reset()
    strm.pointee.msg = nil

    return Status.ok
}

@c @implementation
public func inflateReset2(_ strm: z_streamp!, _ windowBits: Int32) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    guard let (wrapper, bits) = Wrapper.forWindowBits(windowBits), wrapper != .unsupported else {
        return Status.streamError
    }

    state.wrapper = wrapper
    state.windowBits = bits

    return inflateReset(strm)
}
