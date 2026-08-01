import Testing

@testable import LZ77

/// The decompressor is checked against streams whose compressed form is written out here by
/// hand or produced by a known-good compressor, rather than by this module's own compressor:
/// a codec compared only against itself agrees with itself and with nothing else, which is the
/// one failure a round-trip test cannot see.
///
/// The known-good streams are zlib streams, because that is what a reference compressor emits;
/// the DEFLATE data this module reads is those with their framing sliced off, which is a fair
/// source precisely because this module is not the thing that decides where the framing ends.
@Suite("Inflate")
struct InflateTests {
    /// Strips RFC 1950's two-byte header and four-byte Adler-32, leaving RFC 1951 data.
    static func raw(_ zlibStream: [UInt8]) -> [UInt8] {
        Array(zlibStream[2 ..< zlibStream.count - 4])
    }

    /// Runs a whole stream through in one go, with a generous output buffer.
    static func inflate(
        _ compressed: [UInt8],
        into capacity: Int = 65536,
        feeding chunkSize: Int = Int.max
    ) throws -> [UInt8] {
        let stream = Inflate()
        var output = [UInt8](repeating: 0, count: capacity)
        var produced = 0
        var offset = 0

        var input = compressed

        try input.withUnsafeMutableBufferPointer { buffer in
            while true {
                if stream.needsInput, offset < buffer.count {
                    let size = min(chunkSize, buffer.count - offset)
                    stream.setInput(
                        UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: size)
                    )
                    offset += size
                }

                let made = try output.withUnsafeMutableBufferPointer { out in
                    try stream.inflate(
                        into: out.baseAddress! + produced,
                        count: out.count - produced
                    )
                }

                produced += made

                if stream.isFinished { break }

                // No progress and nothing left to give it: the stream is truncated rather than
                // merely hungry, and looping again would spin.
                if made == 0, offset >= buffer.count { break }
            }
        }

        return Array(output[0 ..< produced])
    }

    /// A stored (uncompressed) block: the simplest stream the format defines, so a failure here
    /// is in the framing of a block rather than in any coding.
    @Test("A stored block round-trips")
    func storedBlock() throws {
        let payload: [UInt8] = Array("hello, world".utf8)

        var stream: [UInt8] = []
        stream.append(0x01) // BFINAL 1, BTYPE 00
        stream.append(UInt8(payload.count & 0xFF))
        stream.append(UInt8((payload.count >> 8) & 0xFF))
        stream.append(UInt8(~payload.count & 0xFF))
        stream.append(UInt8((~payload.count >> 8) & 0xFF))
        stream.append(contentsOf: payload)

        #expect(try Self.inflate(stream) == payload)
    }

    /// Produced by zlib at level 6: "aaaaaaaaaaaaaaaaaaaa" (twenty a's), which exercises a
    /// fixed-Huffman block with one literal and one long match back into it.
    @Test("A fixed-Huffman block with a match")
    func fixedHuffmanMatch() throws {
        let compressed = Self.raw([
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ])

        #expect(try Self.inflate(compressed) == [UInt8](repeating: UInt8(ascii: "a"), count: 20))
    }

    /// The same stream fed one byte at a time. Every resumption point in the decoder is on the
    /// path here — mid-symbol, mid-extra-bits, mid-match — and the result has to be identical
    /// to feeding it whole.
    @Test("Feeding one byte at a time gives the same answer")
    func bytewiseFeeding() throws {
        let compressed = Self.raw([
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ])

        let whole = try Self.inflate(compressed)
        let piecemeal = try Self.inflate(compressed, feeding: 1)

        #expect(whole == piecemeal)
        #expect(piecemeal == [UInt8](repeating: UInt8(ascii: "a"), count: 20))
    }

    /// A dynamic-Huffman block, which is what zlib emits for anything with structure worth a
    /// custom table. Produced by zlib at level 9 for the text below.
    @Test("A dynamic-Huffman block")
    func dynamicHuffman() throws {
        let text = "the quick brown fox jumps over the lazy dog, the quick brown fox"
        let compressed = Self.raw([
            0x78, 0xda, 0x2b, 0xc9, 0x48, 0x55, 0x28, 0x2c, 0xcd, 0x4c, 0xce, 0x56, 0x48,
            0x2a, 0xca, 0x2f, 0xcf, 0x53, 0x48, 0xcb, 0xaf, 0x50, 0xc8, 0x2a, 0xcd, 0x2d,
            0x28, 0x56, 0xc8, 0x2f, 0x4b, 0x2d, 0x52, 0x28, 0x01, 0x4a, 0xe7, 0x24, 0x56,
            0x55, 0x2a, 0xa4, 0xe4, 0xa7, 0xeb, 0x80, 0x79, 0x68, 0x8a, 0x01, 0xfe, 0x64,
            0x17, 0x79,
        ])

        #expect(try Self.inflate(compressed) == Array(text.utf8))
    }

    /// Nothing after the final block is this module's to read: a wrapper's trailer, another
    /// member, or trailing junk all look the same from here, and consuming any of it would take
    /// bytes the wrapper needs.
    @Test("Bytes after the final block are left alone")
    func stopsAtEndOfStream() throws {
        var compressed = Self.raw([
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ])
        compressed.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        #expect(try Self.inflate(compressed) == [UInt8](repeating: UInt8(ascii: "a"), count: 20))
    }

    @Test("A reserved block type is refused")
    func reservedBlockType() throws {
        // BFINAL 0, BTYPE 11 — the one encoding the format sets aside and never assigns.
        #expect(throws: DeflateError.self) {
            _ = try Self.inflate([0x06, 0x00, 0x00, 0x00])
        }
    }

    /// A distance pointing further back than anything produced would read window bytes that
    /// were never written, which is the shape of every out-of-bounds read this format invites.
    @Test("A match reaching before the start of the stream is refused")
    func matchBeforeStart() throws {
        // A fixed-Huffman block whose very first symbol is a length code, so the match has
        // nothing behind it to copy from. Bit by bit, in the order they are written:
        //
        //   1        BFINAL
        //   01       BTYPE, fixed Huffman
        //   0000001  symbol 257, length 3, no extra bits
        //   00000    distance symbol 0, distance 1, no extra bits
        //
        // which packs, low bit of each byte first, into the two bytes below.
        #expect(throws: DeflateError.self) {
            _ = try Self.inflate([0x03, 0x02, 0x00])
        }
    }
}
