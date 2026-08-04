// The file layer's calls into the C library, under names nothing in it shadows.
//
// `GzFile` has methods named `read`, `write` and `close`, so inside them the bare libc names
// resolve to the methods and the calls have to be qualified. Qualifying by module would
// hard-wire one platform's module name — `Glibc.read` names nothing on Bionic or Darwin —
// so the disambiguation happens once, here, where the bare names still mean the C library
// and the per-platform import is the only platform-specific line.

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

@inline(__always)
func systemOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ permissions: mode_t) -> Int32 {
    open(path, flags, permissions)
}

@inline(__always)
func systemRead(_ descriptor: Int32, _ destination: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(descriptor, destination, count)
}

@inline(__always)
func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    write(descriptor, bytes, count)
}

@inline(__always)
func systemClose(_ descriptor: Int32) -> Int32 {
    close(descriptor)
}

// `off_t` is `Int` under Glibc and `Int64` under Bionic, Musl and Darwin — same width, spelled
// through a different C type. The conversion happens here so the file layer's own arithmetic
// stays in `Int`.
@inline(__always)
func systemSeek(_ descriptor: Int32, _ offset: Int, _ whence: Int32) -> Int {
    Int(lseek(descriptor, off_t(offset), whence))
}
