// DeflateAPI.swift - the streaming compression entry points
//
// The mirror of InflateAPI, and easier in the one place that one is hard: the encoder takes a
// caller's whole input buffer at once, copying it into its own window, so there is never a
// partially-consumed buffer to account for. What it does have that the decoder does not is
// `flush`, which is the caller asking for output it can act on before the stream is over.

import CZlib
import LZ77
import Zlib

final class DeflateStream {
    enum Engine {
        case zlib(Compressor)
        case raw(Deflate)
    }

    var engine: Engine
    let wrapper: Wrapper
    let windowBits: Int32
    var level: Int32

    /// Set once the stream has reported `Z_STREAM_END`.
    var ended = false

    init(level: Int32, wrapper: Wrapper, windowBits: Int32) {
        self.level = level
        self.wrapper = wrapper
        self.windowBits = windowBits
        self.engine = wrapper == .raw
            ? .raw(Deflate(level: level, windowBits: windowBits))
            : .zlib(Compressor(level: level, windowBits: windowBits))
    }

    func reset() {
        self.engine = self.wrapper == .raw
            ? .raw(Deflate(level: self.level, windowBits: self.windowBits))
            : .zlib(Compressor(level: self.level, windowBits: self.windowBits))
        self.ended = false
    }

    var isFinished: Bool {
        switch self.engine {
        case let .zlib(stream): return stream.isFinished
        case let .raw(stream): return stream.isFinished
        }
    }

    var needsInput: Bool {
        switch self.engine {
        case let .zlib(stream): return stream.needsInput
        case let .raw(stream): return stream.needsInput
        }
    }

    var checksum: UInt32? {
        switch self.engine {
        case let .zlib(stream): return stream.checksum
        case .raw: return nil
        }
    }

    func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        switch self.engine {
        case let .zlib(stream): stream.setInput(bytes)
        case let .raw(stream): stream.setInput(bytes)
        }
    }

    func deflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int,
        ending: Deflate.Ending
    ) throws(DeflateError) -> Int {
        switch self.engine {
        case let .zlib(stream):
            return try stream.deflate(into: destination, count: count, ending: ending)
        case let .raw(stream):
            return try stream.deflate(into: destination, count: count, ending: ending)
        }
    }
}

@c @implementation
public func deflateInit_(
    _ strm: z_streamp!,
    _ level: Int32,
    _ version: UnsafePointer<CChar>!,
    _ stream_size: Int32
) -> Int32 {
    deflateInit2_(strm, level, 8, 15, 8, 0, version, stream_size)
}

@c @implementation
public func deflateInit2_(
    _ strm: z_streamp!,
    _ level: Int32,
    _ method: Int32,
    _ windowBits: Int32,
    _ memLevel: Int32,
    _ strategy: Int32,
    _ version: UnsafePointer<CChar>!,
    _ stream_size: Int32
) -> Int32 {
    if let failure = checkInitArguments(version, stream_size) { return failure }
    guard let strm else { return Status.streamError }

    guard method == 8 else { return Status.streamError } // Z_DEFLATED is the only one defined.
    guard level >= -1, level <= 9 else { return Status.streamError }
    guard memLevel >= 1, memLevel <= 9 else { return Status.streamError }
    guard strategy >= 0, strategy <= 4 else { return Status.streamError }

    guard let (wrapper, bits) = Wrapper.forWindowBits(windowBits), windowBits != 0 else {
        return Status.streamError
    }

    guard wrapper != .unsupported else {
        swiftzlib_report_unimplemented("deflateInit2_ with gzip window bits")
        setMessage(strm, zError(Status.streamError))
        return Status.streamError
    }

    // `strategy` is a hint about what kind of coding will pay off, and this encoder has one
    // kind. Accepted rather than refused because every value of it describes a valid stream,
    // and a caller asking for Z_RLE wants its data compressed, not an error.

    strm.pointee.msg = nil
    strm.pointee.total_in = 0
    strm.pointee.total_out = 0
    strm.pointee.adler = 1
    strm.pointee.data_type = 2 // Z_UNKNOWN

    attach(
        DeflateStream(level: level < 0 ? 6 : level, wrapper: wrapper, windowBits: bits),
        to: strm
    )

    return Status.ok
}

@c @implementation
public func deflate(_ strm: z_streamp!, _ flush: Int32) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return Status.streamError
    }

    guard flush >= 0, flush <= 6 else { return Status.streamError }
    guard strm.pointee.next_out != nil || strm.pointee.avail_out == 0 else {
        return Status.streamError
    }

    if state.ended { return Status.streamEnd }

    let available = Int(strm.pointee.avail_in)

    if available > 0, let next = strm.pointee.next_in {
        // Taken whole: the encoder copies it into its own window, so there is no such thing as
        // a partially consumed input buffer here, and `avail_in` always ends at zero.
        state.setInput(UnsafeBufferPointer(start: next, count: available))
    }

    let ending: Deflate.Ending
    switch flush {
    case 4: ending = .finish                    // Z_FINISH
    case 2, 3: ending = .flush                  // Z_SYNC_FLUSH, Z_FULL_FLUSH
    default: ending = .none
    }

    var produced = 0
    let capacity = Int(strm.pointee.avail_out)

    do {
        while produced < capacity {
            let made = try state.deflate(
                into: (strm.pointee.next_out ?? UnsafeMutablePointer(bitPattern: 1)!) + produced,
                count: capacity - produced,
                ending: ending
            )

            produced += made
            if made == 0 { break }
        }
    } catch {
        setMessage(strm, zError(Status.streamError))
        return Status.streamError
    }

    if available > 0 {
        strm.pointee.next_in += available
        strm.pointee.avail_in = 0
        strm.pointee.total_in += UInt(available)
    }

    if produced > 0 {
        strm.pointee.next_out += produced
        strm.pointee.avail_out -= UInt32(produced)
        strm.pointee.total_out += UInt(produced)
    }

    if let checksum = state.checksum {
        strm.pointee.adler = UInt(checksum)
    }

    if ending == .finish, state.isFinished {
        state.ended = true
        return Status.streamEnd
    }

    // Nothing taken and nothing made: no progress was possible, and repeating the call would do
    // nothing again. Z_OK is the answer that means "call me again", so returning it here spins
    // the caller's loop; Z_BUF_ERROR says to supply more input or more room first.
    if available == 0, produced == 0 {
        return Status.bufferError
    }

    return Status.ok
}

@c @implementation
public func deflateEnd(_ strm: z_streamp!) -> Int32 {
    guard let strm, attached(strm, as: DeflateStream.self) != nil else {
        return Status.streamError
    }

    detach(strm, as: DeflateStream.self)
    return Status.ok
}

@c @implementation
public func deflateReset(_ strm: z_streamp!) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return Status.streamError
    }

    state.reset()
    strm.pointee.total_in = 0
    strm.pointee.total_out = 0
    strm.pointee.adler = 1
    strm.pointee.msg = nil

    return Status.ok
}

@c @implementation
public func deflateResetKeep(_ strm: z_streamp!) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return Status.streamError
    }

    state.reset()
    strm.pointee.msg = nil

    return Status.ok
}

/// An upper bound on what `deflate` will produce for `sourceLen` bytes on this stream.
///
/// Reproduces the reference's bound rather than deriving one from this encoder: a caller sizes
/// a buffer with this and then compresses into it, so any answer smaller than the reference's
/// would overrun a buffer that the reference would have sized correctly.
@c @implementation
public func deflateBound(_ strm: z_streamp!, _ sourceLen: UInt) -> UInt {
    let base = sourceLen
        &+ ((sourceLen &+ 7) >> 3)
        &+ ((sourceLen &+ 63) >> 6)
        &+ 5

    // The wrapper's own bytes on top: six for zlib's header and trailer, none for raw.
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return base &+ 6
    }

    return state.wrapper == .raw ? base : base &+ 6
}

/// How much output is generated but not yet handed over.
@c @implementation
public func deflatePending(
    _ strm: z_streamp!,
    _ pending: UnsafeMutablePointer<UInt32>!,
    _ bits: UnsafeMutablePointer<Int32>!
) -> Int32 {
    guard let strm, attached(strm, as: DeflateStream.self) != nil else {
        return Status.streamError
    }

    // Everything this encoder produces is handed over within the call that produced it, so
    // there is never anything waiting between calls. Reported rather than left untouched,
    // because a caller reads these to decide whether to drain again.
    pending?.pointee = 0
    bits?.pointee = 0

    return Status.ok
}
