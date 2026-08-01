// Boundary.swift - the conventions every exported function here obeys
//
// zlib's return conventions are not uniform, and guessing per call site is how a boundary
// rots. They are named once here so that each `@c` function below reads as a statement about
// what it does rather than about what integer it happens to hand back.
//
// Nothing in this module decides anything about compression. It converts between C's
// conventions and the engine's, and that is deliberately all it does — the moment the engine
// starts being shaped by what is convenient here, the Swift library and the Embedded build
// stop being the same code as the shared object.

import CZlib

/// zlib's status codes, from `zlib.h`.
///
/// Spelled out rather than taken from the imported header because the header gives them as
/// macros, which arrive in Swift as `Int32` constants that are easy to confuse with a count.
enum Status {
    static let ok: Int32 = 0
    static let streamEnd: Int32 = 1
    static let needDictionary: Int32 = 2
    static let errno: Int32 = -1
    static let streamError: Int32 = -2
    static let dataError: Int32 = -3
    static let memoryError: Int32 = -4
    static let bufferError: Int32 = -5
    static let versionError: Int32 = -6
}

/// The version this library claims to be.
///
/// It has to satisfy every client's own check: `deflateInit` and friends are macros that bake
/// `ZLIB_VERSION` into the caller at *its* compile time and pass it back in, and the library
/// compares only the major version. Claiming the reference's version is therefore both what
/// makes older clients work and what makes `zlibVersion()` agree with the header a client read.
let versionString = "1.3.1"

/// A C string with the lifetime of the program, for the several functions that return one.
///
/// Returning a pointer into a Swift `String` would hand back storage that is gone before the
/// caller reads it. These are allocated once, never freed, and never written — which is what
/// the callers assume, since none of them frees what it gets back.
func staticCString(_ value: String) -> UnsafePointer<CChar> {
    let bytes = Array(value.utf8)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)

    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }

    buffer[bytes.count] = 0

    return UnsafePointer(buffer)
}
