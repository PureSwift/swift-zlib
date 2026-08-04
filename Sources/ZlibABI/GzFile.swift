// GzFile.swift - the state behind a gzFile handle
//
// The gz layer is the only part of zlib that touches files, and it is the reason `gzFile` is
// opaque where `z_stream` is not: nothing in it is the caller's to read, so all of it can live
// in Swift and be reached through a pointer the caller only ever passes back.
//
// What it adds over the streaming API is buffering and position. A caller of `gzread` asks for
// however many bytes it likes and expects them, so this holds compressed bytes on one side and
// decompressed bytes on the other, and refills whichever ran out. A caller of `gztell` expects
// a position in the *uncompressed* stream, which nothing below this layer tracks.
//
// Two behaviours here are not obvious from the header and are what a real file exercises. A
// `.gz` may hold several members one after another and must read as their concatenation. And a
// file that is not gzip at all is copied through unchanged rather than refused, which is what
// makes `zcat` work on a plain text file.
//
// The third is not a behaviour but a constraint, and it shapes everything below: `gzFile` is
// only *semi*-opaque. `zlib.h` defines `struct gzFile_s` with three public fields and makes
// `gzgetc` a macro that reads a byte straight out of them, without calling the library at all.
// So the decompressed buffer has to live at a stable address this library publishes, and every
// entry point has to notice on the way in how much the caller took while its back was turned.
// That is why the output buffer here is allocated rather than an `Array`, whose storage is free
// to move the moment it is appended to.

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

import GZip
import LZ77

final class GzFile {
    enum Mode {
        case read
        case write
    }

    let descriptor: Int32
    let mode: Mode

    /// Whether this handle closes the descriptor. `gzdopen` adopts one the caller owns, and the
    /// reference closes it too, so this is only false for a descriptor that failed to open.
    var ownsDescriptor = true

    var level: Int32 = 6

    /// How much to read or write at a time. `gzbuffer` changes it, and only before any transfer
    /// has happened — after that the buffers exist and hold data.
    var bufferSize = 8192
    private(set) var hasTransferred = false

    // -- reading ------------------------------------------------------------------

    private var decompressor: GZip.Decompressor?

    /// Compressed bytes read from the file and not yet decoded.
    private var input: [UInt8] = []
    private var inputOffset = 0

    /// Decompressed bytes not yet handed to the caller.
    ///
    /// At a stable address because the caller is given a pointer into it: the `gzgetc` macro
    /// reads through that pointer and decrements the count itself.
    private var outputStorage: UnsafeMutablePointer<UInt8>?
    private var outputCount = 0
    private var outputOffset = 0

    /// Whether the file turned out not to be gzip at all, in which case its bytes are the
    /// answer and nothing is decoded. §gzopen calls this "transparent"; `gzdirect` reports it.
    private(set) var isDirect = false

    /// Whether the first bytes have been looked at, which is what decides ``isDirect``.
    private var hasLooked = false

    private var reachedEnd = false

    // -- writing ------------------------------------------------------------------

    private var compressor: GZip.Compressor?

    /// Whether a `.gz` is being written at all. `gzopen` with "T" in the mode writes the bytes
    /// through unchanged, which is how a caller asks for a file it can also read directly.
    var writeDirect = false

    private var scratch: [UInt8] = []

    // -- shared -------------------------------------------------------------------

    /// The position in the *uncompressed* stream, which is what `gztell` reports.
    private(set) var position: Int64 = 0

    private(set) var errorCode: Int32 = 0
    private(set) var errorMessage: UnsafePointer<CChar>?

    init(descriptor: Int32, mode: Mode) {
        self.descriptor = descriptor
        self.mode = mode
    }

    deinit {
        self.outputStorage?.deallocate()
    }

    private func ensureOutput() {
        guard self.outputStorage == nil else { return }

        self.outputStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: self.bufferSize)
        self.outputStorage?.initialize(repeating: 0, count: self.bufferSize)
    }

    // -- what the caller can reach without calling ---------------------------------

    /// How many decompressed bytes are ready, which is what `gzFile_s.have` publishes.
    var availableOutput: Int {
        self.outputCount - self.outputOffset
    }

    /// Where those bytes are, which is what `gzFile_s.next` publishes.
    var outputPointer: UnsafeMutablePointer<UInt8>? {
        self.outputStorage.map { $0 + self.outputOffset }
    }

    /// Accounts for bytes the caller took through the `gzgetc` macro rather than through a
    /// call, which is the only way this library learns they are gone.
    func consumeDirect(_ count: Int) {
        self.outputOffset += count
        self.position += Int64(count)
    }

    func fail(_ code: Int32, _ message: String) {
        self.errorCode = code
        self.errorMessage = staticCString(message)
    }

    func clearError() {
        self.errorCode = 0
        self.errorMessage = nil
    }

    var isAtEnd: Bool {
        // The reference reports end-of-file only once a read has actually run out, not when the
        // last byte happens to have been handed over, so a caller reading exactly the file's
        // length sees `gzeof` false until it asks once more.
        self.reachedEnd && self.availableOutput == 0
    }

    /// Where the file is positioned in its *compressed* bytes, which `gzoffset` reports.
    var compressedOffset: Int64 {
        let raw = systemSeek(self.descriptor, 0, SEEK_CUR)
        guard raw >= 0 else { return -1 }

        // Whatever has been read from the file but not yet decoded is not part of what has been
        // consumed, so it comes back off.
        return Int64(raw) - Int64(self.input.count - self.inputOffset)
    }

    // -- reading ------------------------------------------------------------------

    /// Fills `destination` with up to `count` decompressed bytes, returning how many.
    ///
    /// Zero means the end of the file, which is a different answer from an error, and callers
    /// distinguish them with ``errorCode``.
    func read(into destination: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        self.hasTransferred = true
        var produced = 0

        while produced < count {
            if self.availableOutput > 0, let ready = self.outputPointer {
                let take = min(count - produced, self.availableOutput)
                (destination + produced).update(from: ready, count: take)

                self.outputOffset += take
                produced += take
                self.position += Int64(take)
                continue
            }

            guard self.fillOutput() else { break }
        }

        return produced
    }

    /// Decodes the next batch into ``output``. Returns false at the end of the file or on error.
    private func fillOutput() -> Bool {
        self.ensureOutput()
        guard let storage = self.outputStorage else { return false }

        self.outputCount = 0
        self.outputOffset = 0

        while true {
            if self.inputOffset >= self.input.count, !self.fillInput() {
                // No more compressed bytes. A decoder mid-member has been cut off.
                if let decompressor, !decompressor.isFinished, !self.isDirect {
                    self.fail(Status.dataError, "unexpected end of file")
                }

                self.reachedEnd = true
                return false
            }

            if !self.hasLooked { self.look() }

            if self.isDirect {
                // Not a gzip file: its bytes are the answer.
                let take = min(self.bufferSize, self.input.count - self.inputOffset)

                self.input.withUnsafeBufferPointer {
                    storage.update(from: $0.baseAddress! + self.inputOffset, count: take)
                }

                self.inputOffset += take
                self.outputCount = take
                return true
            }

            guard let decompressor else { return false }

            var made = 0

            do {
                try self.input.withUnsafeMutableBufferPointer { buffer in
                    decompressor.setInput(
                        UnsafeBufferPointer(
                            start: buffer.baseAddress! + self.inputOffset,
                            count: buffer.count - self.inputOffset
                        )
                    )

                    made = try decompressor.inflate(into: storage, count: self.bufferSize)
                }
            } catch let error as DeflateError {
                self.fail(Status.dataError, String(describing: error.message))
                self.reachedEnd = true
                return false
            } catch {
                self.fail(Status.dataError, "data error")
                self.reachedEnd = true
                return false
            }

            self.inputOffset += decompressor.pulledInputCount
            self.outputCount = made

            if decompressor.isFinished {
                // A .gz may hold several members, and reads as their concatenation. Anything
                // after the last one that is not another member ends the file rather than
                // being decoded as one.
                if self.startsAnotherMember() {
                    self.decompressor = GZip.Decompressor()
                } else {
                    self.reachedEnd = true
                    return made > 0
                }
            }

            if made > 0 { return true }
        }
    }

    /// Whether what follows is another gzip member, refilling far enough to tell.
    private func startsAnotherMember() -> Bool {
        while self.input.count - self.inputOffset < 2 {
            if !self.fillInput() { return false }
        }

        return self.input[self.inputOffset] == 0x1F && self.input[self.inputOffset + 1] == 0x8B
    }

    /// Decides whether this is a gzip file at all, from its first two bytes.
    private func look() {
        self.hasLooked = true

        while self.input.count - self.inputOffset < 2 {
            if !self.fillInput() { break }
        }

        let remaining = self.input.count - self.inputOffset

        if remaining >= 2,
           self.input[self.inputOffset] == 0x1F,
           self.input[self.inputOffset + 1] == 0x8B {
            self.decompressor = GZip.Decompressor()
        } else {
            self.isDirect = true
        }
    }

    /// Reads more compressed bytes. Returns false at the end of the file.
    @discardableResult
    private func fillInput() -> Bool {
        // Anything already consumed is dropped rather than kept, so this does not grow with the
        // file.
        if self.inputOffset > 0 {
            self.input.removeFirst(self.inputOffset)
            self.inputOffset = 0
        }

        let before = self.input.count
        self.input.append(contentsOf: repeatElement(0, count: self.bufferSize))

        let got: Int = self.input.withUnsafeMutableBufferPointer { buffer in
            Self.readRetrying(self.descriptor, buffer.baseAddress! + before, self.bufferSize)
        }

        if got < 0 {
            self.input.removeLast(self.bufferSize)
            self.fail(Status.errno, "error reading file")
            return false
        }

        self.input.removeLast(self.bufferSize - got)
        return got > 0
    }

    /// `read` may come back short or be interrupted, and neither means the file ended.
    private static func readRetrying(
        _ descriptor: Int32,
        _ destination: UnsafeMutablePointer<UInt8>,
        _ count: Int
    ) -> Int {
        while true {
            let got = systemRead(descriptor, destination, count)
            if got >= 0 { return got }
            if errno == EINTR { continue }
            return -1
        }
    }

    // -- writing ------------------------------------------------------------------

    func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int {
        self.hasTransferred = true

        guard count > 0 else { return 0 }

        if self.writeDirect {
            guard self.writeAll(bytes, count) else { return 0 }
            self.position += Int64(count)
            return count
        }

        if self.compressor == nil {
            self.compressor = GZip.Compressor(level: self.level)
        }

        guard let compressor else { return 0 }

        compressor.setInput(UnsafeBufferPointer(start: bytes, count: count))

        guard self.drain(compressor, ending: .none) else { return 0 }

        self.position += Int64(count)
        return count
    }

    /// Takes everything the compressor will give and writes it to the file.
    private func drain(_ compressor: GZip.Compressor, ending requested: Deflate.Ending) -> Bool {
        if self.scratch.count != self.bufferSize {
            self.scratch = [UInt8](repeating: 0, count: self.bufferSize)
        }

        // A flush is asked for once and then drained. Asking again on each turn of this loop
        // would emit another empty block and another sync marker every time, and since each one
        // is output, the loop would never see the compressor go quiet.
        var ending = requested

        while true {
            var made = 0

            do {
                made = try self.scratch.withUnsafeMutableBufferPointer {
                    try compressor.deflate(into: $0.baseAddress!, count: $0.count, ending: ending)
                }
            } catch {
                self.fail(Status.streamError, "compression failed")
                return false
            }

            if made > 0 {
                let ok = self.scratch.withUnsafeBufferPointer {
                    self.writeAll($0.baseAddress!, made)
                }

                guard ok else { return false }
            }

            if ending == .finish {
                if compressor.isFinished { return true }
                if made == 0 { return true }
                continue
            }

            if ending == .flush || ending == .fullFlush {
                ending = .none
                continue
            }

            if made == 0 { return true }
        }
    }

    @discardableResult
    private func writeAll(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var written = 0

        while written < count {
            let put = systemWrite(self.descriptor, bytes + written, count - written)

            if put < 0 {
                if errno == EINTR { continue }
                self.fail(Status.errno, "error writing file")
                return false
            }

            written += put
        }

        return true
    }

    /// Ends the current member and starts a new one, which is how this layer honours a change
    /// of compression level partway through.
    ///
    /// The reference keeps one member and changes the encoder's parameters inside it. Several
    /// members concatenated decompress to exactly the same bytes, so the difference is in the
    /// output's size and not in what a reader gets back.
    func startNewMember() -> Bool {
        guard let compressor else { return true }
        guard self.drain(compressor, ending: .finish) else { return false }

        self.compressor = nil
        return true
    }

    func flush(_ ending: Deflate.Ending) -> Bool {
        guard self.mode == .write, !self.writeDirect else { return true }
        guard let compressor else { return true }

        guard self.drain(compressor, ending: ending) else { return false }

        if ending == .finish {
            self.compressor = nil
        }

        return true
    }

    // -- positioning ---------------------------------------------------------------

    /// Rewinds a file being read, so that seeking backwards has somewhere to start.
    func rewind() -> Bool {
        guard self.mode == .read else { return false }
        guard systemSeek(self.descriptor, 0, SEEK_SET) >= 0 else {
            self.fail(Status.errno, "cannot seek")
            return false
        }

        self.decompressor = nil
        self.input = []
        self.inputOffset = 0
        self.outputCount = 0
        self.outputOffset = 0
        self.hasLooked = false
        self.isDirect = false
        self.reachedEnd = false
        self.position = 0
        self.clearError()

        return true
    }

    /// Moves to an absolute uncompressed position.
    ///
    /// Forwards means decompressing and discarding, because there is no index into a DEFLATE
    /// stream to jump with — which is why the header calls this extremely slow for reading.
    /// Backwards means starting over, for the same reason.
    func seek(to target: Int64) -> Int64 {
        guard target >= 0 else {
            self.fail(Status.streamError, "cannot seek before the start")
            return -1
        }

        if self.mode == .write {
            // §gzseek: seeking forward while writing compresses a run of zeroes up to the new
            // position, and seeking backwards is not supported.
            guard target >= self.position else {
                self.fail(Status.streamError, "cannot seek backwards while writing")
                return -1
            }

            var remaining = target - self.position
            let zeroes = [UInt8](repeating: 0, count: min(Int(remaining), self.bufferSize))

            while remaining > 0 {
                let take = Int(min(remaining, Int64(zeroes.count)))
                let put = zeroes.withUnsafeBufferPointer {
                    self.write($0.baseAddress!, count: take)
                }

                guard put == take else { return -1 }
                remaining -= Int64(take)
            }

            return self.position
        }

        if target < self.position {
            guard self.rewind() else { return -1 }
        }

        var remaining = target - self.position
        var discard = [UInt8](repeating: 0, count: self.bufferSize)

        while remaining > 0 {
            let take = Int(min(remaining, Int64(discard.count)))
            let got = discard.withUnsafeMutableBufferPointer {
                self.read(into: $0.baseAddress!, count: take)
            }

            if got == 0 { break }
            remaining -= Int64(got)
        }

        return self.position
    }

    /// Puts a byte back, into the same buffer the caller reads through.
    ///
    /// Into the buffer rather than into a queue beside it, because the `gzgetc` macro reads
    /// straight from `next` and would walk past anything held anywhere else.
    func pushBack(_ byte: UInt8) -> Bool {
        guard self.mode == .read else { return false }

        self.ensureOutput()
        guard let storage = self.outputStorage else { return false }

        if self.outputOffset > 0 {
            // Room in front of the unread bytes, which is the usual case: a byte just read
            // leaves exactly the space it came from.
            self.outputOffset -= 1
            storage[self.outputOffset] = byte
        } else {
            guard self.outputCount < self.bufferSize else { return false }

            // Nothing read yet, so the unread bytes have to move up to make room. memmove
            // rather than a copy, the ranges being adjacent and overlapping.
            if self.outputCount > 0 {
                memmove(storage + 1, storage, self.outputCount)
            }

            storage[0] = byte
            self.outputCount += 1
        }

        self.position -= 1
        self.reachedEnd = false

        return true
    }

    func close() -> Int32 {
        var status = Status.ok

        if self.mode == .write {
            if !self.flush(.finish) { status = self.errorCode }
        }

        if self.ownsDescriptor, systemClose(self.descriptor) != 0 {
            status = Status.errno
        }

        return status
    }
}
