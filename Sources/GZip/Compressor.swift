// Compressor.swift - RFC 1952 framing around a DEFLATE stream
//
// gzip is the same DEFLATE data as a zlib stream under different framing: a longer header with
// optional fields, and a trailer carrying a CRC-32 rather than an Adler-32 plus the original
// length. That is the whole difference, and it is why this is a module beside `Zlib` rather
// than a mode inside it — neither one is a special case of the other, and both are a wrapper
// over the same `LZ77`.
//
// Writing it is concatenation, as it is for zlib: the header ahead of whatever the encoder
// produces, the trailer once it has produced everything, both drained through the same pending
// queue because a caller's buffer may run out partway through either.

import LZ77

public final class Compressor {
    public typealias Ending = Deflate.Ending

    private let stream: Deflate
    private var checksumState = Crc32()

    /// The original input length, which the trailer carries modulo 2³² so that a decompressor
    /// can check it against what it produced.
    private var inputLength: UInt32 = 0

    private var pending: [UInt8] = []
    private var pendingOffset = 0

    private var wroteHeader = false
    private var wroteTrailer = false

    private let level: Int32

    /// The metadata to write, which a caller may replace up to the point the header goes out.
    ///
    /// After that it is too late — the bytes are gone — so setting it later is refused rather
    /// than silently ignored.
    public var header = Header()

    /// Whether the header has been built, and so whether ``header`` can still be changed.
    public var canSetHeader: Bool {
        !self.wroteHeader
    }

    public var isFinished: Bool {
        self.wroteTrailer && self.pendingOffset >= self.pending.count
    }

    /// - Parameter windowBits: the base-two logarithm of the window, 9 through 15. Unlike zlib's
    ///   header, gzip's does not record it, so this only limits the encoder.
    public init(level: Int32 = 6, windowBits: Int32 = 15) {
        self.level = level
        self.stream = Deflate(level: level, windowBits: max(9, min(15, windowBits)))
    }

    public var needsInput: Bool {
        self.stream.needsInput
    }

    /// The CRC-32 of everything handed in so far.
    public var checksum: UInt32 {
        self.checksumState.checksum
    }

    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.checksumState.update(bytes)
        self.inputLength &+= UInt32(truncatingIfNeeded: bytes.count)
        self.stream.setInput(bytes)
    }

    public func deflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int,
        ending: Ending = .none
    ) throws(DeflateError) -> Int {
        guard count > 0 else { return 0 }

        if !self.wroteHeader {
            self.pending = self.header.encoded(extraFlags: Self.extraFlags(level: self.level))
            self.pendingOffset = 0
            self.wroteHeader = true
        }

        var produced = self.drainPending(into: destination, count: count)
        guard produced < count else { return produced }

        produced += try self.stream.deflate(
            into: destination + produced,
            count: count - produced,
            ending: ending
        )

        if self.stream.isFinished, !self.wroteTrailer {
            self.pending = Self.trailer(
                checksum: self.checksumState.checksum,
                length: self.inputLength
            )
            self.pendingOffset = 0
            self.wroteTrailer = true
        }

        if produced < count {
            produced += self.drainPending(into: destination + produced, count: count - produced)
        }

        return produced
    }

    private func drainPending(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Int {
        let available = min(count, self.pending.count - self.pendingOffset)
        guard available > 0 else { return 0 }

        self.pending.withUnsafeBufferPointer { buffer in
            destination.update(from: buffer.baseAddress! + self.pendingOffset, count: available)
        }

        self.pendingOffset += available

        if self.pendingOffset >= self.pending.count {
            self.pending = []
            self.pendingOffset = 0
        }

        return available
    }

    // -- the framing itself ------------------------------------------------------

    /// §2.3.1: a hint about how hard the encoder worked, which nothing acts on but which the
    /// reference sets, so it is set the same way here.
    private static func extraFlags(level: Int32) -> UInt8 {
        if level == 9 { return 2 }
        if level < 2 { return 4 }
        return 0
    }

    /// §2.3.1: the CRC-32 of the uncompressed data and its length modulo 2³², both least
    /// significant byte first — the opposite order to zlib's trailer, which is big-endian.
    private static func trailer(checksum: UInt32, length: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: checksum),
            UInt8(truncatingIfNeeded: checksum >> 8),
            UInt8(truncatingIfNeeded: checksum >> 16),
            UInt8(truncatingIfNeeded: checksum >> 24),
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24),
        ]
    }
}
