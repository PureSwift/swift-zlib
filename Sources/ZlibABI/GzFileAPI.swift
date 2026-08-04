// GzFileAPI.swift - the file-shaped half of the API
//
// These are the entry points that make a `.gz` behave like a file: open it, read and write it,
// ask where you are in it. They are a thin skin over `GzFile`, which does the work.
//
// The conventions are stdio's rather than zlib's, and that is the trap in this family. `gzread`
// answers in bytes and reports failure as -1; `gzfread` answers in *items* and reports failure
// as a short count; `gzgets` answers with the caller's own pointer or null; `gzgetc` answers
// with an int so that -1 can mean end-of-file without colliding with the byte 0xFF. Each is
// spelled out at the function that has it, because a boundary that guesses is a boundary that
// eventually guesses wrong.
//
// The other thing shaping this file is that `gzFile` is not opaque. `zlib.h` defines its three
// fields and makes `gzgetc` a macro that consumes a byte from them directly — no call reaches
// here at all. So the handle really is a `struct gzFile_s`, with the Swift state kept behind
// it, and every entry point runs through `withFile`, which reconciles what the macro took on
// the way in and republishes the buffer on the way out. An entry point that skipped that would
// work perfectly until a caller mixed `gzgetc` with anything else.

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

import CZlib
import LZ77

// A handle is one allocation holding the three fields the caller may read, followed by a
// pointer to the Swift object holding everything else. The caller sees only the first part, and
// only ever through the `gzgetc` macro.

private let stateSlotOffset = MemoryLayout<gzFile_s>.stride

private func makeHandle(_ object: GzFile) -> gzFile {
    let size = stateSlotOffset + MemoryLayout<UnsafeMutableRawPointer>.stride
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: size,
        alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment
    )
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)

    stateSlot(raw).pointee = Unmanaged.passRetained(object).toOpaque()

    return raw.assumingMemoryBound(to: gzFile_s.self)
}

private func stateSlot(_ raw: UnsafeMutableRawPointer) -> UnsafeMutablePointer<UnsafeMutableRawPointer?> {
    (raw + stateSlotOffset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
}

private func handle(_ file: gzFile?) -> GzFile? {
    guard let file else { return nil }
    guard let slot = stateSlot(UnsafeMutableRawPointer(file)).pointee else { return nil }

    return Unmanaged<GzFile>.fromOpaque(slot).takeUnretainedValue()
}

private func releaseHandle(_ file: gzFile) {
    let raw = UnsafeMutableRawPointer(file)

    if let slot = stateSlot(raw).pointee {
        Unmanaged<GzFile>.fromOpaque(slot).release()
    }

    raw.deallocate()
}

/// Runs `body` with the handle's Swift state, having first accounted for whatever the `gzgetc`
/// macro consumed without telling anyone, and republishing the buffer afterwards.
private func withFile<T>(_ file: gzFile?, _ fallback: T, _ body: (GzFile) -> T) -> T {
    guard let file, let state = handle(file) else { return fallback }

    // The macro only ever decrements `have` and advances `next` in step, so the shortfall is
    // exactly how many bytes went that way.
    let published = Int(file.pointee.have)
    let actual = state.availableOutput

    if published < actual {
        state.consumeDirect(actual - published)
    }

    defer {
        file.pointee.have = UInt32(state.availableOutput)
        file.pointee.next = state.outputPointer
        file.pointee.pos = Int(state.position)
    }

    return body(state)
}

/// Reads a mode string: "r"/"w"/"a", an optional level digit, and the letters zlib defines.
private struct FileMode {
    var mode: GzFile.Mode = .read
    var append = false
    var exclusive = false
    var level: Int32 = 6
    var direct = false

    init?(_ text: UnsafePointer<CChar>) {
        var sawDirection = false
        var index = 0

        while text[index] != 0 {
            let character = UInt8(bitPattern: text[index])
            index += 1

            switch character {
            case UInt8(ascii: "r"):
                self.mode = .read
                sawDirection = true
            case UInt8(ascii: "w"):
                self.mode = .write
                sawDirection = true
            case UInt8(ascii: "a"):
                self.mode = .write
                self.append = true
                sawDirection = true
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                self.level = Int32(character - UInt8(ascii: "0"))
            case UInt8(ascii: "x"):
                self.exclusive = true
            case UInt8(ascii: "T"):
                self.direct = true
            // Accepted and ignored: "b" is meaningless where there is no text mode, and the
            // strategy letters name coding choices this encoder does not offer. A caller asking
            // for one wants its data compressed, not an error.
            case UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "h"),
                 UInt8(ascii: "R"), UInt8(ascii: "F"), UInt8(ascii: "+"):
                break
            default:
                return nil
            }
        }

        guard sawDirection else { return nil }
    }
}

@c @implementation
public func gzopen(_ path: UnsafePointer<CChar>!, _ mode: UnsafePointer<CChar>!) -> gzFile! {
    open(path, mode)
}

@c @implementation
public func gzopen64(_ path: UnsafePointer<CChar>!, _ mode: UnsafePointer<CChar>!) -> gzFile! {
    open(path, mode)
}

private func open(_ path: UnsafePointer<CChar>?, _ mode: UnsafePointer<CChar>?) -> gzFile? {
    guard let path, let mode, let parsed = FileMode(mode) else { return nil }

    var flags: Int32 = parsed.mode == .read ? O_RDONLY : (O_WRONLY | O_CREAT)

    if parsed.mode == .write {
        flags |= parsed.append ? O_APPEND : O_TRUNC
        if parsed.exclusive { flags |= O_EXCL }
    }

    let descriptor = systemOpen(path, flags, 0o666)
    guard descriptor >= 0 else { return nil }

    return attachFile(descriptor, parsed)
}

@c @implementation
public func gzdopen(_ fd: Int32, _ mode: UnsafePointer<CChar>!) -> gzFile! {
    guard fd >= 0, let mode, let parsed = FileMode(mode) else { return nil }
    return attachFile(fd, parsed)
}

private func attachFile(_ descriptor: Int32, _ parsed: FileMode) -> gzFile {
    let file = GzFile(descriptor: descriptor, mode: parsed.mode)
    file.level = parsed.level
    file.writeDirect = parsed.mode == .write && parsed.direct

    return makeHandle(file)
}

// -- reading -----------------------------------------------------------------

/// Returns bytes read, 0 at the end of the file, or -1 on error — stdio's convention, not
/// zlib's, so a caller must not test this against `Z_OK`.
@c @implementation
public func gzread(_ file: gzFile!, _ buf: UnsafeMutableRawPointer!, _ len: UInt32) -> Int32 {
    withFile(file, -1) { state in
        guard state.mode == .read, let buf else { return -1 }

        // The reference refuses a request it could not report the size of, rather than
        // returning a truncated count that a caller would read as success.
        guard len <= UInt32(Int32.max) else {
            state.fail(Status.streamError, "request does not fit in an int")
            return -1
        }

        let got = state.read(into: buf.assumingMemoryBound(to: UInt8.self), count: Int(len))

        if got == 0, state.errorCode != 0 { return -1 }

        return Int32(got)
    }
}

/// Returns the number of whole *items* read, which is why a partial item at the end of the file
/// is not counted — and why this cannot report an error except as a short count.
@c @implementation
public func gzfread(
    _ buf: UnsafeMutableRawPointer!,
    _ size: Int,
    _ nitems: Int,
    _ file: gzFile!
) -> Int {
    withFile(file, 0) { state in
        guard state.mode == .read, let buf, size > 0 else { return 0 }

        let (total, overflowed) = size.multipliedReportingOverflow(by: nitems)
        guard !overflowed else { return 0 }

        let got = state.read(into: buf.assumingMemoryBound(to: UInt8.self), count: total)

        return got / size
    }
}

/// Returns the byte as an unsigned value, or -1 at the end of the file — which is why the
/// result is an `int` and not a `char`.
@c @implementation
public func gzgetc(_ file: gzFile!) -> Int32 {
    withFile(file, -1) { state in
        var byte: UInt8 = 0

        let got = withUnsafeMutablePointer(to: &byte) { state.read(into: $0, count: 1) }

        return got == 1 ? Int32(byte) : -1
    }
}

/// The same, as a real function rather than the macro `zlib.h` also defines under this name.
@c @implementation
public func gzgetc_(_ file: gzFile!) -> Int32 {
    gzgetc(file)
}

@c @implementation
public func gzungetc(_ c: Int32, _ file: gzFile!) -> Int32 {
    withFile(file, -1) { state in
        guard c >= 0, state.pushBack(UInt8(truncatingIfNeeded: c)) else { return -1 }
        return c
    }
}

/// Reads a line into the caller's buffer, terminator included, and returns that same buffer —
/// or null at the end of the file. `fgets`, in other words.
@c @implementation
public func gzgets(
    _ file: gzFile!,
    _ buf: UnsafeMutablePointer<CChar>!,
    _ len: Int32
) -> UnsafeMutablePointer<CChar>! {
    withFile(file, nil) { state -> UnsafeMutablePointer<CChar>? in
    guard state.mode == .read, let buf, len > 0 else { return nil }

    var written = 0

    // One short of the buffer, because what comes back is a C string and the terminator has to
    // fit whatever else does.
    while written < Int(len) - 1 {
        var byte: UInt8 = 0

        let got = withUnsafeMutablePointer(to: &byte) {
            state.read(into: $0, count: 1)
        }

        if got == 0 { break }

        buf[written] = CChar(bitPattern: byte)
        written += 1

        if byte == UInt8(ascii: "\n") { break }
    }

    guard written > 0 else { return nil }

    buf[written] = 0
    return buf
    }
}

@c @implementation
public func gzdirect(_ file: gzFile!) -> Int32 {
    withFile(file, 0) { state in
        (state.mode == .write ? state.writeDirect : state.isDirect) ? 1 : 0
    }
}

// -- writing -----------------------------------------------------------------

/// Returns bytes written, or 0 on error — so unlike `gzread`, failure and "nothing asked for"
/// are the same answer, which is the reference's convention and not this library's choice.
@c @implementation
public func gzwrite(_ file: gzFile!, _ buf: UnsafeRawPointer!, _ len: UInt32) -> Int32 {
    withFile(file, 0) { state in
        guard state.mode == .write, let buf else { return 0 }

        return Int32(state.write(buf.assumingMemoryBound(to: UInt8.self), count: Int(len)))
    }
}

@c @implementation
public func gzfwrite(
    _ buf: UnsafeRawPointer!,
    _ size: Int,
    _ nitems: Int,
    _ file: gzFile!
) -> Int {
    withFile(file, 0) { state in
        guard state.mode == .write, let buf, size > 0 else { return 0 }

        let (total, overflowed) = size.multipliedReportingOverflow(by: nitems)
        guard !overflowed else { return 0 }

        return state.write(buf.assumingMemoryBound(to: UInt8.self), count: total) / size
    }
}

@c @implementation
public func gzputc(_ file: gzFile!, _ c: Int32) -> Int32 {
    withFile(file, -1) { state in
        var byte = UInt8(truncatingIfNeeded: c)
        let put = withUnsafePointer(to: &byte) { state.write($0, count: 1) }

        return put == 1 ? Int32(byte) : -1
    }
}

@c @implementation
public func gzputs(_ file: gzFile!, _ s: UnsafePointer<CChar>!) -> Int32 {
    withFile(file, -1) { state in
        guard state.mode == .write, let s else { return -1 }

        let length = strlen(s)
        guard length > 0 else { return 0 }

        let put = s.withMemoryRebound(to: UInt8.self, capacity: length) {
            state.write($0, count: length)
        }

        return put > 0 ? Int32(put) : -1
    }
}

@c @implementation
public func gzflush(_ file: gzFile!, _ flush: Int32) -> Int32 {
    withFile(file, Status.streamError) { state in
        guard state.mode == .write, flush >= 0, flush <= 4 else { return Status.streamError }

        let ending: Deflate.Ending = flush == 4 ? .finish : .flush
        return state.flush(ending) ? Status.ok : state.errorCode
    }
}

@c @implementation
public func gzsetparams(_ file: gzFile!, _ level: Int32, _ strategy: Int32) -> Int32 {
    withFile(file, Status.streamError) { state in
        guard state.mode == .write, level >= -1, level <= 9,
              strategy >= 0, strategy <= 4
        else {
            return Status.streamError
        }

        // Ending the current member and starting another is how this honours the change. The
        // reference alters the encoder inside one member; concatenated members decompress to
        // the same bytes, so what differs is the size of the file and not what a reader gets.
        guard state.startNewMember() else { return state.errorCode }

        state.level = level < 0 ? 6 : level
        return Status.ok
    }
}

// -- position and state --------------------------------------------------------

@c @implementation
public func gztell(_ file: gzFile!) -> Int {
    withFile(file, -1) { Int($0.position) }
}

@c @implementation
public func gztell64(_ file: gzFile!) -> Int {
    gztell(file)
}

@c @implementation
public func gzoffset(_ file: gzFile!) -> Int {
    withFile(file, -1) { Int($0.compressedOffset) }
}

@c @implementation
public func gzoffset64(_ file: gzFile!) -> Int {
    gzoffset(file)
}

@c @implementation
public func gzseek(_ file: gzFile!, _ offset: Int, _ whence: Int32) -> Int {
    seek(file, Int64(offset), whence)
}

@c @implementation
public func gzseek64(_ file: gzFile!, _ offset: Int, _ whence: Int32) -> Int {
    seek(file, Int64(offset), whence)
}

private func seek(_ file: gzFile?, _ offset: Int64, _ whence: Int32) -> Int {
    withFile(file, -1) { state in
        // §gzseek: SEEK_END is not supported, because knowing where the end is would mean
        // decompressing the whole file to find out.
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = state.position + offset
        default:
            state.fail(Status.streamError, "SEEK_END is not supported")
            return -1
        }

        let result = state.seek(to: target)
        return result < 0 ? -1 : Int(result)
    }
}

@c @implementation
public func gzrewind(_ file: gzFile!) -> Int32 {
    withFile(file, Status.streamError) { state in
        guard state.mode == .read else { return Status.streamError }
        return state.rewind() ? Status.ok : Status.errno
    }
}

@c @implementation
public func gzeof(_ file: gzFile!) -> Int32 {
    withFile(file, 0) { $0.isAtEnd ? 1 : 0 }
}

/// Reports the last error, and writes its code through `errnum` if the caller wants it.
@c @implementation
public func gzerror(
    _ file: gzFile!,
    _ errnum: UnsafeMutablePointer<Int32>!
) -> UnsafePointer<CChar>! {
    guard let state = handle(file) else {
        errnum?.pointee = Status.streamError
        return zError(Status.streamError)
    }

    errnum?.pointee = state.errorCode
    return state.errorMessage ?? zError(state.errorCode)
}


@c @implementation
public func gzclearerr(_ file: gzFile!) {
    handle(file)?.clearError()
}

/// The buffer size to use, which may only be set before anything has been read or written —
/// after that the buffers exist and hold data that changing their size would strand.
@c @implementation
public func gzbuffer(_ file: gzFile!, _ size: UInt32) -> Int32 {
    // Plain -1 on every failure, which is what the reference returns here rather than one of
    // the Z_ codes — this is one of the entry points whose conventions are stdio's.
    withFile(file, -1) { state in
        guard !state.hasTransferred, size > 0 else { return -1 }

        state.bufferSize = Int(size)
        return Status.ok
    }
}

// -- closing --------------------------------------------------------------------

@c @implementation
public func gzclose(_ file: gzFile!) -> Int32 {
    guard let file, let state = handle(file) else { return Status.streamError }

    let status = state.close()
    releaseHandle(file)

    return status
}

/// Closing a file opened for reading, which the reference distinguishes so that a program doing
/// only one of the two can be linked without the other half.
@c @implementation
public func gzclose_r(_ file: gzFile!) -> Int32 {
    guard let state = handle(file), state.mode == .read else { return Status.streamError }
    return gzclose(file)
}

@c @implementation
public func gzclose_w(_ file: gzFile!) -> Int32 {
    guard let state = handle(file), state.mode == .write else { return Status.streamError }
    return gzclose(file)
}
