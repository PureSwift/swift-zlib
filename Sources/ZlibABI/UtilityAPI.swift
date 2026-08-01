// UtilityAPI.swift - the one-shot buffer-to-buffer entry points
//
// `compress` and `uncompress` are what a caller reaches for when the whole input is already in
// memory, which is most callers. In the reference these are thin wrappers over the streaming
// API; here they are written directly on the engine, because the engine is already shaped to
// be driven a buffer at a time and there is nothing for a stream object to add.
//
// The contract that matters in both directions is `destLen`: in on entry as the room available,
// out on return as the room used. Getting that backwards, or not writing it on the error paths
// the reference writes it on, is the kind of mistake that corrupts a caller rather than this
// library.

import CZlib
import Zlib

@c @implementation
public func compressBound(_ sourceLen: UInt) -> UInt {
    // The reference's bound, reproduced exactly: five bytes per stored block of 16 KiB or so,
    // plus the zlib header and trailer, plus slack. Reproduced rather than derived because a
    // caller sizes its buffer with this and then calls `compress`, so the only bound that is
    // safe is one at least as large as the reference's — and matching it exactly means a
    // caller that sized a buffer from the reference's answer is equally safe here.
    sourceLen &+ (sourceLen >> 12) &+ (sourceLen >> 14) &+ (sourceLen >> 25) &+ 13
}

@c @implementation
public func compress(
    _ dest: UnsafeMutablePointer<UInt8>!,
    _ destLen: UnsafeMutablePointer<UInt>!,
    _ source: UnsafePointer<UInt8>!,
    _ sourceLen: UInt
) -> Int32 {
    compress2(dest, destLen, source, sourceLen, -1)
}

@c @implementation
public func compress2(
    _ dest: UnsafeMutablePointer<UInt8>!,
    _ destLen: UnsafeMutablePointer<UInt>!,
    _ source: UnsafePointer<UInt8>!,
    _ sourceLen: UInt,
    _ level: Int32
) -> Int32 {
    guard let dest, let destLen, source != nil || sourceLen == 0 else {
        return Status.streamError
    }

    guard level >= -1, level <= 9 else { return Status.streamError }

    let capacity = Int(destLen.pointee)
    // The reference's default is 6, and -1 is how a caller spells "whatever that is".
    let compressor = Compressor(level: level < 0 ? 6 : level)

    var produced = 0

    do {
        if sourceLen > 0 {
            compressor.setInput(UnsafeBufferPointer(start: source, count: Int(sourceLen)))
        }

        while !compressor.isFinished {
            guard produced < capacity else {
                // Out of room with the stream unfinished. The reference reports this without
                // writing a length, because a partial deflate stream is not something a caller
                // can do anything with.
                return Status.bufferError
            }

            produced += try compressor.deflate(
                into: dest + produced,
                count: capacity - produced,
                ending: .finish
            )
        }
    } catch {
        return Status.streamError
    }

    destLen.pointee = UInt(produced)
    return Status.ok
}

@c @implementation
public func uncompress(
    _ dest: UnsafeMutablePointer<UInt8>!,
    _ destLen: UnsafeMutablePointer<UInt>!,
    _ source: UnsafePointer<UInt8>!,
    _ sourceLen: UInt
) -> Int32 {
    var consumed = sourceLen

    return withUnsafeMutablePointer(to: &consumed) { pointer in
        uncompress2(dest, destLen, source, pointer)
    }
}

@c @implementation
public func uncompress2(
    _ dest: UnsafeMutablePointer<UInt8>!,
    _ destLen: UnsafeMutablePointer<UInt>!,
    _ source: UnsafePointer<UInt8>!,
    _ sourceLen: UnsafeMutablePointer<UInt>!
) -> Int32 {
    guard let dest, let destLen, let sourceLen, source != nil || sourceLen.pointee == 0 else {
        return Status.streamError
    }

    let capacity = Int(destLen.pointee)
    let available = Int(sourceLen.pointee)
    let stream = Decompressor()

    var produced = 0

    do {
        if available > 0 {
            stream.setInput(UnsafeBufferPointer(start: source, count: available))
        }

        while true {
            let made = try stream.inflate(into: dest + produced, count: capacity - produced)
            produced += made

            if stream.isFinished { break }

            // Nothing produced and the stream is not done: either the output buffer is full or
            // the input ran out, and the two are different errors to a caller sizing buffers.
            if made == 0 {
                return produced >= capacity ? Status.bufferError : Status.dataError
            }
        }
    } catch {
        // A malformed stream, a bad checksum, a match reaching out of the window: all of them
        // are the data being wrong rather than this library being unable to proceed.
        return Status.dataError
    }

    destLen.pointee = UInt(produced)
    sourceLen.pointee = UInt(available)
    return Status.ok
}
