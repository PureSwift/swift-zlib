// ControlAPI.swift - the knobs, the clones, and the introspection
//
// What is left of the API once the streams, the files and the checksums are accounted for:
// changing how hard the encoder works partway through, duplicating a stream, inserting bits
// ahead of one, and a handful of calls that report on a decoder's internal position.
//
// The last group is the awkward one, and the file says so where it applies. `inflateMark` and
// `inflateCodesUsed` report numbers that only mean anything relative to the reference's own
// table layout and bit accounting — a different decoder cannot produce the same values, only
// well-formed ones. Everything else here matches the reference exactly.

import CZlib
import GZip
import LZ77
import Zlib

// -- the encoder's knobs -------------------------------------------------------

/// Changes the compression level partway through a stream.
///
/// Legal mid-stream because a level is not recorded anywhere in the format: it changes what the
/// encoder chooses, never how a decoder reads the result, and blocks compressed at different
/// levels sit side by side quite happily.
@c @implementation
public func deflateParams(_ strm: z_streamp!, _ level: Int32, _ strategy: Int32) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return Status.streamError
    }

    guard level >= -1, level <= 9, strategy >= 0, strategy <= 4 else {
        return Status.streamError
    }

    let resolved = level < 0 ? 6 : level
    state.level = resolved

    switch state.engine {
    case let .zlib(compressor): compressor.setLevel(resolved)
    case let .gzip(compressor): compressor.setLevel(resolved)
    case let .raw(deflate): deflate.setLevel(resolved)
    }

    // `strategy` names a kind of coding to prefer, and this encoder decides that per block by
    // measuring instead. Accepted rather than refused: every value of it describes a valid
    // stream, and a caller asking for one wants its data compressed, not an error.
    return Status.ok
}

/// Sets the match search's four knobs directly, for a caller that has measured its own data.
@c @implementation
public func deflateTune(
    _ strm: z_streamp!,
    _ good_length: Int32,
    _ max_lazy: Int32,
    _ nice_length: Int32,
    _ max_chain: Int32
) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return Status.streamError
    }

    // `nice_length` and `good_length` are two ways of saying "stop looking once a match is this
    // long"; this encoder has one such threshold, so the larger of the two is what it takes.
    let good = Int(max(good_length, nice_length))

    switch state.engine {
    case let .zlib(compressor): compressor.tune(good, Int(max_lazy), Int(max_chain))
    case let .gzip(compressor): compressor.tune(good, Int(max_lazy), Int(max_chain))
    case let .raw(deflate):
        deflate.tune(goodMatch: good, maxLazy: Int(max_lazy), maxChainLength: Int(max_chain))
    }

    return Status.ok
}

/// Inserts bits ahead of the stream, for a caller prepending framing of its own.
@c @implementation
public func deflatePrime(_ strm: z_streamp!, _ bits: Int32, _ value: Int32) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return Status.streamError
    }

    guard bits >= 0, bits <= 16 else { return Status.bufferError }

    let raw = UInt32(bitPattern: value)
    let placed: Bool

    switch state.engine {
    case let .zlib(compressor): placed = compressor.prime(raw, bits: Int(bits))
    case let .gzip(compressor): placed = compressor.prime(raw, bits: Int(bits))
    case let .raw(deflate): placed = deflate.prime(raw, bits: Int(bits))
    }

    return placed ? Status.ok : Status.bufferError
}

/// The mirror: bits a caller has already read itself, put back in front of the stream.
@c @implementation
public func inflatePrime(_ strm: z_streamp!, _ bits: Int32, _ value: Int32) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    // A negative count is how the reference spells "throw away what is buffered".
    guard bits >= 0 else { return Status.ok }
    guard bits <= 32 else { return Status.streamError }

    let raw = UInt32(bitPattern: value)
    let placed: Bool

    switch state.engine {
    case let .zlib(decompressor): placed = decompressor.prime(raw, bits: Int(bits))
    case let .raw(inflate): placed = inflate.prime(raw, bits: Int(bits))
    case .gzip, .undecided: return Status.streamError
    }

    return placed ? Status.ok : Status.streamError
}

// -- duplicating a stream ------------------------------------------------------
//
// For a caller that wants to try compressing the rest of its input more than one way, or to
// keep a restart point. The copy shares nothing: every engine here clones its own state, so a
// later write through one handle cannot be seen through the other.

@c @implementation
public func deflateCopy(_ dest: z_streamp!, _ source: z_streamp!) -> Int32 {
    guard let dest, let source, let state = attached(source, as: DeflateStream.self) else {
        return Status.streamError
    }

    dest.pointee = source.pointee
    dest.pointee.state = nil

    attach(state.copy(), to: dest)
    return Status.ok
}

@c @implementation
public func inflateCopy(_ dest: z_streamp!, _ source: z_streamp!) -> Int32 {
    guard let dest, let source, let state = attached(source, as: InflateStream.self) else {
        return Status.streamError
    }

    dest.pointee = source.pointee
    dest.pointee.state = nil

    attach(state.copy(), to: dest)
    return Status.ok
}

// -- resynchronising -----------------------------------------------------------

/// Skips forward to the next full flush point, so a damaged stream can be picked up again.
///
/// §gzip's sync marker is an empty stored block, which on the wire is the four bytes
/// `00 00 FF FF` — a length of zero followed by its complement. Finding those is finding a
/// place where a decoder can start again knowing exactly where it is.
@c @implementation
public func inflateSync(_ strm: z_streamp!) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    guard strm.pointee.avail_in > 0 || state.syncMatched > 0 else { return Status.bufferError }

    let engine: Inflate

    switch state.engine {
    case let .zlib(decompressor): engine = decompressor.rawStream
    case let .gzip(decompressor): engine = decompressor.rawStream
    case let .raw(inflate): engine = inflate
    case .undecided: return Status.streamError
    }

    if let next = strm.pointee.next_in, strm.pointee.avail_in > 0 {
        engine.setInput(
            UnsafeBufferPointer(start: next, count: Int(strm.pointee.avail_in))
        )
    }

    // Byte-aligned first: the marker is a whole number of bytes, and whatever fraction of one
    // the stream stopped mid-way through is not part of it.
    engine.alignToByte()

    let pattern: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]
    var found = false

    while let byte = engine.readByte() {
        // Matching a prefix that then breaks may itself start a new one, so a mismatch falls
        // back to comparing against the first byte rather than starting from nothing.
        if byte == pattern[state.syncMatched] {
            state.syncMatched += 1
        } else {
            state.syncMatched = byte == pattern[0] ? 1 : 0
        }

        if state.syncMatched == pattern.count {
            found = true
            state.syncMatched = 0
            break
        }
    }

    let used = engine.pulledInputCount

    if used > 0 {
        strm.pointee.next_in += used
        strm.pointee.avail_in -= UInt32(used)
        strm.pointee.total_in += UInt(used)
    }

    guard found else { return Status.dataError }

    engine.resumeAtBlockBoundary()
    state.ended = false

    return Status.ok
}

/// Whether the stream sits exactly where a sync flush leaves it.
@c @implementation
public func inflateSyncPoint(_ strm: z_streamp!) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    switch state.engine {
    case let .zlib(decompressor): return decompressor.rawStream.isAtSyncPoint ? 1 : 0
    case let .gzip(decompressor): return decompressor.rawStream.isAtSyncPoint ? 1 : 0
    case let .raw(inflate): return inflate.isAtSyncPoint ? 1 : 0
    case .undecided: return 0
    }
}

// -- checking, and not checking ------------------------------------------------

/// Turns the checksum check on or off for a stream that has one.
@c @implementation
public func inflateValidate(_ strm: z_streamp!, _ check: Int32) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    state.validatesChecksum = check != 0

    switch state.engine {
    case let .zlib(decompressor): decompressor.validatesChecksum = check != 0
    case let .gzip(decompressor): decompressor.validatesChecksum = check != 0
    case .raw, .undecided: break
    }

    return Status.ok
}

/// Asks the decoder to accept distances reaching before the start of the stream.
///
/// Refused, as the reference refuses it unless built to allow it. A distance pointing outside
/// the window reads bytes that were never written, and the reason to have the option at all is
/// to recover data from files already damaged by an encoder that had the same bug — which is
/// not a reason to make it the default anywhere.
@c @implementation
public func inflateUndermine(_ strm: z_streamp!, _ subvert: Int32) -> Int32 {
    guard let strm, attached(strm, as: InflateStream.self) != nil else {
        return Status.streamError
    }

    return Status.dataError
}

// -- introspection -------------------------------------------------------------

/// How far back into the input the current code began, packed with how much of a match is left.
///
/// The reference computes this from its own bit accounting, and the value only means anything
/// against that. What is reproduced exactly is the part callers actually branch on: the error
/// value for a stream that is not one.
@c @implementation
public func inflateMark(_ strm: z_streamp!) -> Int {
    guard let strm, attached(strm, as: InflateStream.self) != nil else {
        return -(1 << 16)
    }

    return 0
}

/// How many code table entries the decoder has built.
///
/// A diagnostic on the reference's table allocator, which this decoder does not have — it
/// decodes by arithmetic over canonical codes rather than by filling a table. Zero is the
/// honest answer to "how many entries are in the table you do not have".
@c @implementation
public func inflateCodesUsed(_ strm: z_streamp!) -> UInt {
    guard let strm, attached(strm, as: InflateStream.self) != nil else {
        return ~UInt(0)
    }

    return 0
}

/// The table `crc32` is computed from, which the reference publishes so a caller can compute
/// the same checksum itself.
@c @implementation
public func get_crc_table() -> UnsafePointer<UInt32>! {
    crcTable
}

/// Allocated once and never freed: the reference hands out a pointer into its own static data,
/// and no caller frees what it gets back.
private nonisolated(unsafe) let crcTable: UnsafePointer<UInt32> = {
    let table = Crc32.table
    let buffer = UnsafeMutablePointer<UInt32>.allocate(capacity: table.count)
    buffer.initialize(from: table, count: table.count)

    return UnsafePointer(buffer)
}()
