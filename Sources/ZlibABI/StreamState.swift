// StreamState.swift - owning state a caller holds a pointer to
//
// `z_stream` is the caller's struct, not this library's. The caller allocates it, reads and
// writes `next_in`, `avail_in`, `total_out`, `msg` and `adler` directly, and passes it back on
// every call — so its layout is the contract, and the only field this library owns is `state`.
//
// What goes in `state` is a pointer to a Swift object held here by an unmanaged reference:
// retained when a stream is initialised, released when it is ended, and never touched by the
// caller. That is the whole trick that lets a Swift engine sit under a C struct — nothing about
// the engine has to be expressible as C, because the caller never sees it.
//
// The lifetime rules are unforgiving in both directions. A missing release is a leak in the
// client's address space; a double release is a crash the client gets blamed for. So attaching
// and detaching happen only here, in one place each.

import CZlib

/// How a stream's DEFLATE data is wrapped.
///
/// zlib spells this as the sign and magnitude of `windowBits`, which is compact but means every
/// caller of `inflateInit2_` is doing arithmetic to say something with three cases.
enum Wrapper {
    case zlib
    case raw
    /// Requested but not built: gzip framing, and the auto-detecting mode that accepts either.
    case unsupported

    /// - Parameter windowBits: as `inflateInit2_` and `deflateInit2_` define it — 8...15 for
    ///   zlib, negative for raw, +16 for gzip, +32 for detect-either.
    static func forWindowBits(_ windowBits: Int32) -> (wrapper: Wrapper, bits: Int32)? {
        switch windowBits {
        // 0 means "take the window from the stream's own header", which only inflate can
        // honour, and which this decoder satisfies by always keeping the largest window.
        case 0:
            return (.zlib, 15)
        case 8 ... 15:
            // A window of 256 is not expressible: the header records `windowBits - 8` in four
            // bits and 8 is the smallest, but the reference silently promotes 8 to 9 because
            // its own encoder cannot emit a 256-byte window either.
            return (.zlib, max(9, windowBits))
        case -15 ... -9:
            return (.raw, -windowBits)
        case -8:
            return (.raw, 9)
        case 24 ... 31, 40 ... 47:
            return (.unsupported, 15)
        default:
            return nil
        }
    }
}

/// Checks the two things every `*Init_` entry point is handed, and for the same reason.
///
/// `deflateInit` and `inflateInit` are macros, so the version string and struct size that arrive
/// here were compiled into the *caller*, not passed by it deliberately. They are how a client
/// built against a different zlib says so, and refusing the mismatch here is the whole point:
/// the alternative is writing through a struct whose fields are somewhere else.
func checkInitArguments(_ version: UnsafePointer<CChar>!, _ streamSize: Int32) -> Int32? {
    guard let version, version[0] == CChar(UInt8(ascii: "1")) else {
        return Status.versionError
    }

    guard Int(streamSize) == MemoryLayout<z_stream>.size else {
        return Status.versionError
    }

    return nil
}

/// Attaches `object` to `strm`, taking a reference the stream now owns.
func attach<Object: AnyObject>(_ object: Object, to strm: z_streamp) {
    strm.pointee.state = OpaquePointer(Unmanaged.passRetained(object).toOpaque())
}

/// The object attached to `strm`, or nil if there is none or it is of another kind.
///
/// Deliberately not checking *which* kind: a caller passing an inflate stream to a deflate
/// function is a bug this library cannot detect from the pointer alone, and pretending
/// otherwise would only make the check look more thorough than it is.
func attached<Object: AnyObject>(_ strm: z_streamp?, as type: Object.Type) -> Object? {
    guard let strm, let state = strm.pointee.state else { return nil }

    return Unmanaged<Object>.fromOpaque(UnsafeRawPointer(state)).takeUnretainedValue()
}

/// Releases the object attached to `strm` and clears the field, so that a second call finds
/// nothing rather than releasing again.
func detach<Object: AnyObject>(_ strm: z_streamp, as type: Object.Type) {
    guard let state = strm.pointee.state else { return }

    Unmanaged<Object>.fromOpaque(UnsafeRawPointer(state)).release()
    strm.pointee.state = nil
}

/// Records an error message on the stream, which callers print and some test for.
///
/// The pointer has to outlive the call and is never freed by the caller, so these are the
/// same permanently-allocated strings `zError` hands out.
func setMessage(_ strm: z_streamp, _ message: UnsafePointer<CChar>?) {
    strm.pointee.msg = UnsafeMutablePointer(mutating: message)
}
