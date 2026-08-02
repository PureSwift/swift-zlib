// HeaderAPI.swift - the gzip metadata a caller supplies or asks for
//
// A gzip member carries a name, a comment, a modification time and a few flags, none of which
// affect decoding. They are here because tools want them: `gunzip` names the file it writes
// from the member's name field, and a caller writing one wants to put it there.
//
// The read side is the awkward one. zlib fills in buffers the *caller* owns and sized, so the
// contract is a set of capacity fields the library must respect and length fields it must set.
// Writing past `name_max` would corrupt the caller's memory rather than this library's, which
// is the kind of mistake a drop-in has no business making.

import CZlib
import GZip

@c @implementation
public func deflateSetHeader(_ strm: z_streamp!, _ head: gz_headerp!) -> Int32 {
    guard let strm, let state = attached(strm, as: DeflateStream.self) else {
        return Status.streamError
    }

    // Only a gzip stream has anywhere to put this, and the reference likewise refuses rather
    // than accepting a header it would silently drop.
    guard case let .gzip(compressor) = state.engine, compressor.canSetHeader else {
        return Status.streamError
    }

    guard let head else { return Status.streamError }

    var header = Header()
    header.isText = head.pointee.text != 0
    header.modificationTime = UInt32(truncatingIfNeeded: head.pointee.time)
    header.operatingSystem = UInt8(truncatingIfNeeded: head.pointee.os)
    header.hasHeaderChecksum = head.pointee.hcrc != 0

    if let extra = head.pointee.extra {
        header.extra = Array(UnsafeBufferPointer(start: extra, count: Int(head.pointee.extra_len)))
    }

    header.fileName = head.pointee.name.map(nullTerminatedBytes)
    header.comment = head.pointee.comment.map(nullTerminatedBytes)

    // Copied now rather than read when the header is written. The reference reads it later and
    // so requires the struct to stay alive until then; copying is stricter, and the difference
    // is only visible to a caller that fills the struct in after asking for it to be used.
    compressor.header = header

    return Status.ok
}

@c @implementation
public func inflateGetHeader(_ strm: z_streamp!, _ head: gz_headerp!) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateStream.self) else {
        return Status.streamError
    }

    guard let head else { return Status.streamError }

    // Only a gzip stream has a header to report. A `.detect` stream might still turn out to be
    // one, so it is accepted and answered once it has decided.
    switch state.engine {
    case .gzip, .undecided:
        break
    case .zlib, .raw:
        return Status.streamError
    }

    head.pointee.done = 0
    state.headerRequest = head

    return Status.ok
}

/// Fills in a caller's `gz_header` from a member that has been read, respecting every capacity
/// it declared.
func reportHeader(_ head: gz_headerp, _ header: Header) {
    head.pointee.text = header.isText ? 1 : 0
    head.pointee.time = UInt(header.modificationTime)
    head.pointee.xflags = Int32(header.extraFlags)
    head.pointee.os = Int32(header.operatingSystem)
    head.pointee.hcrc = header.hasHeaderChecksum ? 1 : 0

    if let extra = header.extra {
        // `extra_len` is the field's true length even when less of it was copied, which is how
        // a caller learns its buffer was too small.
        head.pointee.extra_len = UInt32(extra.count)
        copy(extra, into: head.pointee.extra, capacity: head.pointee.extra_max)
    } else {
        head.pointee.extra_len = 0
    }

    copyTerminated(header.fileName, into: head.pointee.name, capacity: head.pointee.name_max)
    copyTerminated(header.comment, into: head.pointee.comment, capacity: head.pointee.comm_max)

    head.pointee.done = 1
}

private func copy(_ bytes: [UInt8], into destination: UnsafeMutablePointer<UInt8>?, capacity: UInt32) {
    guard let destination, capacity > 0 else { return }

    let count = min(bytes.count, Int(capacity))
    bytes.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: count) }
}

/// Copies a name or comment, terminator included, truncated to what the caller declared room
/// for.
///
/// The terminator is one of the bytes copied rather than something reserved space for, which
/// means a field too long for its buffer arrives *unterminated*. That is what the reference
/// does, verified against it rather than assumed, and it is reproduced here deliberately: a
/// caller that copies exactly `name_max` bytes would otherwise get different bytes from this
/// library than from the one it was written against, and being a drop-in is worth more than
/// improving on a contract callers have already been written to.
///
/// A caller wanting a string it can safely `strlen` sizes the buffer for one.
private func copyTerminated(
    _ bytes: [UInt8]?,
    into destination: UnsafeMutablePointer<UInt8>?,
    capacity: UInt32
) {
    guard let destination, capacity > 0 else { return }

    guard let bytes else {
        destination[0] = 0
        return
    }

    let terminated = bytes + [0]
    let count = min(terminated.count, Int(capacity))

    terminated.withUnsafeBufferPointer {
        destination.update(from: $0.baseAddress!, count: count)
    }
}

private func nullTerminatedBytes(_ pointer: UnsafeMutablePointer<UInt8>) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = 0

    while pointer[index] != 0 {
        bytes.append(pointer[index])
        index += 1
    }

    return bytes
}
