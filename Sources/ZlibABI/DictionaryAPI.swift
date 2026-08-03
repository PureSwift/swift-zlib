// DictionaryAPI.swift - compressing against text that is not in the stream
//
// A preset dictionary is context both sides are assumed to hold already: matches may point into
// it from the very first byte, so a stream never has to spend its opening bytes rebuilding a
// vocabulary the decoder could have had. That is what makes it worth having for many small
// messages that share their shape — protocol headers, log lines, JSON with the same keys.
//
// The read side has a shape worth noticing. A stream that needs one says so and *stops*, with
// `Z_NEED_DICT` and the dictionary's checksum in `adler` — not an error, since the stream is
// perfectly well formed, but fatal if a caller treats it as ordinary progress and carries on.

import CZlib
import GZip
import LZ77
import Zlib

@c @implementation
public func deflateSetDictionary(
    _ strm: z_streamp!,
    _ dictionary: UnsafePointer<UInt8>!,
    _ dictLength: UInt32
) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self), let dictionary else {
        return Status.streamError
    }

    let bytes = UnsafeBufferPointer(start: dictionary, count: Int(dictLength))

    switch state.engine {
    case let .zlib(compressor):
        guard compressor.setDictionary(bytes) else { return Status.streamError }

        // The reference reports the dictionary's checksum here, which is what a decoder will
        // compare against — not the stream's own running checksum, which covers only the data.
        var checksum = Adler32()
        checksum.update(bytes)
        strm.pointee.adler = UInt(checksum.value)

    case let .raw(deflate):
        // Raw DEFLATE has nowhere to record that a dictionary was used, so the two sides have
        // to have agreed out of band. Priming the window is the whole of it.
        deflate.primeWindow(bytes)

    case .gzip:
        // gzip's header has no field for one, and the reference refuses rather than writing a
        // member whose decoder could not know what it was compressed against.
        return Status.streamError
    }

    return Status.ok
}

@c @implementation
public func deflateGetDictionary(
    _ strm: z_streamp!,
    _ dictionary: UnsafeMutablePointer<UInt8>!,
    _ dictLength: UnsafeMutablePointer<UInt32>!
) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return Status.streamError
    }

    let bytes: [UInt8]

    switch state.engine {
    case let .zlib(compressor): bytes = compressor.dictionary
    case let .gzip(compressor): bytes = compressor.dictionary
    case let .raw(deflate): bytes = deflate.dictionary
    }

    copyDictionary(bytes, into: dictionary, length: dictLength)
    return Status.ok
}

@c @implementation
public func inflateSetDictionary(
    _ strm: z_streamp!,
    _ dictionary: UnsafePointer<UInt8>!,
    _ dictLength: UInt32
) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self), let dictionary else {
        return Status.streamError
    }

    let bytes = UnsafeBufferPointer(start: dictionary, count: Int(dictLength))

    switch state.engine {
    case let .zlib(decompressor):
        // The reference checks the dictionary is the one the stream names, and refuses a
        // different one rather than decoding to plausible rubbish.
        if let expected = decompressor.dictionaryId {
            var checksum = Adler32()
            checksum.update(bytes)

            guard checksum.value == expected else { return Status.dataError }
        }

        guard decompressor.setDictionary(bytes) else { return Status.streamError }

    case let .raw(inflate):
        inflate.primeWindow(bytes)

    case .gzip, .undecided:
        return Status.streamError
    }

    return Status.ok
}

@c @implementation
public func inflateGetDictionary(
    _ strm: z_streamp!,
    _ dictionary: UnsafeMutablePointer<UInt8>!,
    _ dictLength: UnsafeMutablePointer<UInt32>!
) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    let bytes: [UInt8]

    switch state.engine {
    case let .zlib(decompressor): bytes = decompressor.dictionary
    case let .gzip(decompressor): bytes = decompressor.dictionary
    case let .raw(inflate): bytes = inflate.dictionary
    case .undecided: bytes = []
    }

    copyDictionary(bytes, into: dictionary, length: dictLength)
    return Status.ok
}

/// Hands back a dictionary the way both getters do: the length always, the bytes only if the
/// caller asked for them.
///
/// A null buffer with a non-null length is how a caller asks how much room it would need, so
/// the length is written whether or not there is anywhere to put the bytes.
private func copyDictionary(
    _ bytes: [UInt8],
    into destination: UnsafeMutablePointer<UInt8>?,
    length: UnsafeMutablePointer<UInt32>?
) {
    if let destination {
        bytes.withUnsafeBufferPointer {
            if let base = $0.baseAddress {
                destination.update(from: base, count: bytes.count)
            }
        }
    }

    length?.pointee = UInt32(bytes.count)
}
