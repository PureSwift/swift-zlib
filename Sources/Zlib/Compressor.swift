// Compressor.swift - RFC 1950 framing around a DEFLATE stream
//
// A zlib stream is a two-byte header, DEFLATE data, and a four-byte Adler-32 of the
// *uncompressed* input. The DEFLATE data is the `LZ77` module's entire concern and none of
// this file's; what is here is the framing, the checksum, and the ordering between them.
//
// Framing on the way out needs nothing from the compressor below beyond its bytes, so this is
// concatenation: the header ahead of whatever LZ77 produces, the trailer once LZ77 says it has
// produced everything. The only care needed is that a caller's buffer may run out partway
// through either piece, so both are drained through the same pending queue rather than assumed
// to fit.

import LZ77

public final class Compressor {
    public typealias Ending = Deflate.Ending

    private let stream: Deflate
    private var checksumState = Adler32()

    /// Framing bytes waiting for room in a caller's buffer — the header before anything else has
    /// been written, the trailer after everything else has.
    private var pending: [UInt8] = []
    private var pendingOffset = 0

    private var wroteHeader = false
    private var wroteTrailer = false

    /// Whether the stream has been finished *and* every byte of it handed over, trailer included.
    ///
    /// The analogue of zlib's `Z_STREAM_END`, which likewise never arrives while output is still
    /// waiting to be collected.
    public var isFinished: Bool {
        self.wroteTrailer && self.pendingOffset >= self.pending.count
    }

    /// The window this stream declares in its header, which is also the limit the encoder
    /// under it works to. Kept so the header can be built from it.
    private let windowBits: Int32

    /// - Parameter windowBits: the base-two logarithm of the window, 9 through 15.
    public init(level: Int32 = 6, windowBits: Int32 = 15) {
        self.windowBits = max(9, min(15, windowBits))
        self.stream = Deflate(level: level, windowBits: self.windowBits)
    }

    /// The Adler-32 of everything handed in so far.
    public var checksum: UInt32 {
        self.checksumState.value
    }

    public var needsInput: Bool {
        self.stream.needsInput
    }

    /// Hands the compressor its next input, and folds it into the checksum.
    ///
    /// Checksummed here rather than as it is consumed because the trailer covers the input in
    /// full: every byte handed over will be compressed before the stream can finish, so counting
    /// it now and counting it later differ only in when, never in what.
    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.checksumState.update(bytes)
        self.stream.setInput(bytes)
    }

    /// Compresses into `destination`, returning how many bytes of zlib stream were produced.
    public func deflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int,
        ending: Ending = .none
    ) throws(DeflateError) -> Int {
        guard count > 0 else { return 0 }

        if !self.wroteHeader {
            self.pending = Self.header(windowBits: self.windowBits)
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

        // The trailer goes in only once the DEFLATE data is complete *and* collected — `LZ77`'s
        // own `isFinished` already means both, so there is no risk of framing overtaking data.
        if self.stream.isFinished, !self.wroteTrailer {
            self.pending = Self.trailer(for: self.checksumState.value)
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

    /// §2.2: CMF is the compression method in the low nibble and the window in the high one;
    /// FLG carries no preset dictionary and a check value chosen so that the two bytes read as
    /// a big-endian number divide by 31.
    ///
    /// The window recorded here is the one the encoder was actually held to, not a fixed 32 KiB:
    /// a decoder sizes its own window from this byte, and telling it more than the encoder used
    /// only wastes its memory while telling it less would be a lie it cannot survive.
    private static func header(windowBits: Int32) -> [UInt8] {
        let cmf = UInt32((windowBits - 8) << 4) | 8
        var flg: UInt32 = 0

        while (cmf * 256 + flg) % 31 != 0 {
            flg += 1
        }

        return [UInt8(cmf), UInt8(flg)]
    }

    /// §2.2: the Adler-32 of the uncompressed data, most significant byte first — the one field
    /// in either format that is big-endian, everything in DEFLATE below being the other way.
    private static func trailer(for checksum: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: checksum >> 24),
            UInt8(truncatingIfNeeded: checksum >> 16),
            UInt8(truncatingIfNeeded: checksum >> 8),
            UInt8(truncatingIfNeeded: checksum),
        ]
    }
}
