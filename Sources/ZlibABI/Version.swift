// Version.swift - what this library says it is
//
// `zlibVersion` is not cosmetic. Every client that calls `deflateInit` calls a macro that
// passes the `ZLIB_VERSION` string the *client* was compiled against, and the library refuses
// the call if the major version does not match. So the version reported here is part of the
// ABI in the same way the symbol names are.

import CZlib

@c @implementation
public func zlibVersion() -> UnsafePointer<CChar>! {
    version
}

private nonisolated(unsafe) let version = staticCString(versionString)

/// The text for a status code, as `zlib.h` documents it.
@c @implementation
public func zError(_ err: Int32) -> UnsafePointer<CChar>! {
    switch err {
    case Status.streamEnd: return messages.streamEnd
    case Status.needDictionary: return messages.needDictionary
    case Status.ok: return messages.ok
    case Status.errno: return messages.errno
    case Status.streamError: return messages.streamError
    case Status.dataError: return messages.dataError
    case Status.memoryError: return messages.memoryError
    case Status.bufferError: return messages.bufferError
    case Status.versionError: return messages.versionError
    default: return messages.ok
    }
}

/// Allocated once, because every one of these is handed out as a pointer the caller does not
/// free and may hold for as long as it likes.
private nonisolated(unsafe) let messages = (
    streamEnd: staticCString("stream end"),
    needDictionary: staticCString("need dictionary"),
    ok: staticCString(""),
    errno: staticCString("file error"),
    streamError: staticCString("stream error"),
    dataError: staticCString("data error"),
    memoryError: staticCString("insufficient memory"),
    bufferError: staticCString("buffer error"),
    versionError: staticCString("incompatible version")
)

/// A description of how this library was built, in the bit layout `zlib.h` specifies.
///
/// The type-size fields are the ones that matter: a client comparing its own
/// `zlibCompileFlags()` against the library's is checking that the two agree about how wide a
/// `uLong` is before it trusts a struct laid out with them.
@c @implementation
public func zlibCompileFlags() -> UInt {
    var flags: UInt = 0

    flags |= sizeCode(MemoryLayout<UInt32>.size) << 0 // uInt
    flags |= sizeCode(MemoryLayout<UInt>.size) << 2 // uLong
    flags |= sizeCode(MemoryLayout<UnsafeRawPointer>.size) << 4 // voidpf
    flags |= sizeCode(MemoryLayout<Int>.size) << 6 // z_off_t

    // Bits 8 upward describe build options this library does not have: no debug build, no
    // assembly, no Windows calling convention, and none of the reference's compile-time
    // omissions of the gz layer. All of them are correctly zero.
    return flags
}

/// The two-bit encoding `zlib.h` uses for a type's width: 0 for two bytes, then one step per
/// doubling.
private func sizeCode(_ size: Int) -> UInt {
    switch size {
    case 2: return 0
    case 4: return 1
    case 8: return 2
    default: return 3
    }
}
