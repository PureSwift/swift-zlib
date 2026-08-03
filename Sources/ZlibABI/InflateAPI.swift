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
import GZip
import LZ77
import Zlib

final class InflateStream {
    enum Engine {
        case zlib(Zlib.Decompressor)
        case gzip(GZip.Decompressor)
        case raw(Inflate)
        /// Nothing built yet, because which wrapper this is has not been decided. Resolved by
        /// ``decide(from:)`` as soon as one byte of the stream is in hand.
        case undecided
    }

    var engine: Engine
    var wrapper: Wrapper
    var windowBits: Int32

    /// Set once the stream has reported `Z_STREAM_END`, so that calling again is a no-op rather
    /// than a second attempt at a finished stream.
    var ended = false

    /// A caller's `gz_header` waiting to be filled in, from `inflateGetHeader`. Cleared once
    /// answered, so a header is reported once rather than rewritten on every call.
    var headerRequest: gz_headerp?

    /// Whether the trailer is checked, which `inflateValidate` turns off.
    var validatesChecksum = true

    /// How much of the sync marker `inflateSync` has matched so far, kept across calls because
    /// the four bytes may be split across as many buffers.
    var syncMatched = 0

    /// An independent copy, sharing nothing.
    func copy() -> InflateStream {
        let clone = InflateStream(wrapper: self.wrapper, windowBits: self.windowBits)

        switch self.engine {
        case let .zlib(decompressor): clone.engine = .zlib(decompressor.copy())
        case let .gzip(decompressor): clone.engine = .gzip(decompressor.copy())
        case let .raw(inflate): clone.engine = .raw(inflate.copy())
        case .undecided: clone.engine = .undecided
        }

        clone.ended = self.ended
        clone.validatesChecksum = self.validatesChecksum
        clone.syncMatched = self.syncMatched

        // Deliberately not carried over: a `gz_header` belongs to whoever asked for it, and a
        // copy filling in the original's buffers would write through a pointer its own caller
        // never handed over.
        clone.headerRequest = nil

        return clone
    }

    init(wrapper: Wrapper, windowBits: Int32) {
        self.wrapper = wrapper
        self.windowBits = windowBits
        self.engine = Self.engine(for: wrapper)
    }

    func reset() {
        self.engine = Self.engine(for: self.wrapper)
        self.ended = false
    }

    private static func engine(for wrapper: Wrapper) -> Engine {
        switch wrapper {
        case .zlib: return .zlib(Zlib.Decompressor())
        case .gzip: return .gzip(GZip.Decompressor())
        case .raw: return .raw(Inflate())
        case .detect: return .undecided
        }
    }

    /// Picks the wrapper from the stream's first byte.
    ///
    /// §2.3.1 gives a gzip member the fixed magic 0x1f, and RFC 1950 §2.2 puts the compression
    /// method in the low nibble of the first byte, which for deflate makes it 0x?8. The two
    /// cannot collide, so one byte decides it — which is why this waits for one rather than
    /// guessing, and why a caller that has supplied nothing yet gets told to supply something.
    func decide(from first: UInt8) {
        self.engine = first == 0x1F
            ? .gzip(GZip.Decompressor())
            : .zlib(Zlib.Decompressor())
    }

    var isUndecided: Bool {
        if case .undecided = self.engine { return true }
        return false
    }

    var isFinished: Bool {
        switch self.engine {
        case let .zlib(stream): return stream.isFinished
        case let .gzip(stream): return stream.isFinished
        case let .raw(stream): return stream.isFinished
        case .undecided: return false
        }
    }

    /// The running checksum, which the caller reads from `strm.adler`.
    ///
    /// Raw streams carry no checksum, and the reference leaves the field alone for them.
    var checksum: UInt32? {
        switch self.engine {
        case let .zlib(stream): return stream.checksum
        case let .gzip(stream): return stream.checksum
        case .raw, .undecided: return nil
        }
    }

    var pulledInputCount: Int {
        switch self.engine {
        case let .zlib(stream): return stream.pulledInputCount
        case let .gzip(stream): return stream.pulledInputCount
        case let .raw(stream): return stream.pulledInputCount
        case .undecided: return 0
        }
    }

    func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        switch self.engine {
        case let .zlib(stream): stream.setInput(bytes)
        case let .gzip(stream): stream.setInput(bytes)
        case let .raw(stream): stream.setInput(bytes)
        case .undecided: break
        }
    }

    func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(DeflateError) -> Int {
        switch self.engine {
        case let .zlib(stream): return try stream.inflate(into: destination, count: count)
        case let .gzip(stream): return try stream.inflate(into: destination, count: count)
        case let .raw(stream): return try stream.inflate(into: destination, count: count)
        case .undecided: return 0
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

    if state.isUndecided {
        guard available > 0, let next = strm.pointee.next_in else {
            // Nothing to decide from yet. Not an error: the caller supplies a byte and asks
            // again, which is exactly what Z_BUF_ERROR asks it to do.
            return Status.bufferError
        }

        state.decide(from: next.pointee)
    }

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

    // A gzip header becomes available partway through, well before the stream ends, and a
    // caller that asked for it wants it as soon as it is there rather than at the end.
    if let request = state.headerRequest,
       case let .gzip(decompressor) = state.engine,
       decompressor.headerIsComplete {
        reportHeader(request, decompressor.header)
        state.headerRequest = nil
    }

    let used = consume(strm, state, produced: produced)

    // A stream that has named its dictionary can go no further until it is supplied. The id
    // goes where the reference puts it — in `adler`, displacing the running checksum until the
    // dictionary arrives — and the status is its own, because a caller that mistakes this for
    // progress loops forever.
    if case let .zlib(decompressor) = state.engine, decompressor.needsDictionary {
        if let id = decompressor.dictionaryId {
            strm.pointee.adler = UInt(id)
        }

        return Status.needDictionary
    }

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

    guard let (wrapper, bits) = Wrapper.forWindowBits(windowBits) else {
        return Status.streamError
    }

    state.wrapper = wrapper
    state.windowBits = bits

    return inflateReset(strm)
}
