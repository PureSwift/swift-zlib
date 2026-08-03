import Testing

@testable import Zlib

/// Checked against whole zlib streams from a known-good compressor, and against framing errors
/// written out by hand. What is under test here is the framing and the checksum — the DEFLATE
/// data inside is `LZ77`'s, and has its own suite.
@Suite("Decompressor")
struct DecompressorTests {
    static func inflate(
        _ compressed: [UInt8],
        into capacity: Int = 65536,
        feeding chunkSize: Int = Int.max
    ) throws -> [UInt8] {
        let stream = Decompressor()
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
                if made == 0, offset >= buffer.count { break }
            }
        }

        return Array(output[0 ..< produced])
    }

    /// A stored block under a real zlib header and trailer, written out by hand: the simplest
    /// whole stream the two specifications between them define.
    @Test("A stored block round-trips")
    func storedBlock() throws {
        let payload: [UInt8] = Array("hello, world".utf8)

        var stream: [UInt8] = [0x78, 0x01]
        stream.append(0x01) // BFINAL 1, BTYPE 00
        stream.append(UInt8(payload.count & 0xFF))
        stream.append(UInt8((payload.count >> 8) & 0xFF))
        stream.append(UInt8(~payload.count & 0xFF))
        stream.append(UInt8((~payload.count >> 8) & 0xFF))
        stream.append(contentsOf: payload)

        var checksum = Adler32()
        payload.withUnsafeBufferPointer { checksum.update($0) }
        let value = checksum.value
        stream.append(UInt8(truncatingIfNeeded: value >> 24))
        stream.append(UInt8(truncatingIfNeeded: value >> 16))
        stream.append(UInt8(truncatingIfNeeded: value >> 8))
        stream.append(UInt8(truncatingIfNeeded: value))

        #expect(try Self.inflate(stream) == payload)
    }

    /// Produced by zlib at level 6: twenty a's.
    @Test("A fixed-Huffman stream")
    func fixedHuffman() throws {
        let compressed: [UInt8] = [
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ]

        #expect(try Self.inflate(compressed) == [UInt8](repeating: UInt8(ascii: "a"), count: 20))
    }

    /// Fed one byte at a time. The header, the DEFLATE data, and the trailer each have to
    /// survive running out of input partway through, and the trailer is the one that only this
    /// module can get wrong.
    @Test("Feeding one byte at a time gives the same answer")
    func bytewiseFeeding() throws {
        let compressed: [UInt8] = [
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ]

        #expect(try Self.inflate(compressed, feeding: 1) == Self.inflate(compressed))
    }

    /// Produced by zlib at level 9.
    @Test("A dynamic-Huffman stream")
    func dynamicHuffman() throws {
        let text = "the quick brown fox jumps over the lazy dog, the quick brown fox"
        let compressed: [UInt8] = [
            0x78, 0xda, 0x2b, 0xc9, 0x48, 0x55, 0x28, 0x2c, 0xcd, 0x4c, 0xce, 0x56, 0x48,
            0x2a, 0xca, 0x2f, 0xcf, 0x53, 0x48, 0xcb, 0xaf, 0x50, 0xc8, 0x2a, 0xcd, 0x2d,
            0x28, 0x56, 0xc8, 0x2f, 0x4b, 0x2d, 0x52, 0x28, 0x01, 0x4a, 0xe7, 0x24, 0x56,
            0x55, 0x2a, 0xa4, 0xe4, 0xa7, 0xeb, 0x80, 0x79, 0x68, 0x8a, 0x01, 0xfe, 0x64,
            0x17, 0x79,
        ]

        #expect(try Self.inflate(compressed) == Array(text.utf8))
    }

    /// A checksum that does not match has to be reported rather than passed off as a good
    /// decode: the bytes may be right, but nothing downstream can tell that from here.
    @Test("A bad checksum is refused")
    func badChecksum() throws {
        var compressed: [UInt8] = [
            0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6, 0x07, 0x95,
        ]
        compressed[compressed.count - 1] ^= 0xFF

        #expect(throws: DeflateError.self) {
            _ = try Self.inflate(compressed)
        }
    }

    /// A stream whose data decodes but whose trailer never arrives is not finished, and saying
    /// so is the whole reason ``Decompressor/isFinished`` waits for the checksum.
    @Test("A truncated trailer leaves the stream unfinished")
    func truncatedTrailer() throws {
        let compressed: [UInt8] = [0x78, 0x9c, 0x4b, 0x4c, 0xc4, 0x04, 0x00, 0x4f, 0xa6]

        let stream = Decompressor()
        var output = [UInt8](repeating: 0, count: 256)
        var input = compressed

        input.withUnsafeMutableBufferPointer { buffer in
            stream.setInput(UnsafeBufferPointer(rebasing: buffer[...]))
        }

        _ = try output.withUnsafeMutableBufferPointer { out in
            try stream.inflate(into: out.baseAddress!, count: out.count)
        }

        #expect(!stream.isFinished)
    }

    /// §2.2's window field is a promise about how far back the stream reaches, and a decoder
    /// sized for less cannot keep it. Accepting one anyway decodes into a window too small and
    /// yields rubbish rather than a failure, which is the worse of the two outcomes.
    @Test("A stream declaring more window than was asked for is refused")
    func windowLargerThanRequested() throws {
        let payload = Array(String(repeating: "the quick brown fox. ", count: 40).utf8)

        // Declares a 32 KiB window, as the default encoder does.
        let compressed = try CompressorTests.compress(payload, windowBits: 15)
        #expect((compressed[0] >> 4) + 8 == 15)

        // A decoder prepared for 32 KiB reads it; one prepared for 512 bytes does not.
        let generous = Decompressor(maximumWindowBits: 15)
        let strict = Decompressor(maximumWindowBits: 9)

        for (stream, shouldRead) in [(generous, true), (strict, false)] {
            var input = compressed
            var output = [UInt8](repeating: 0, count: payload.count + 64)

            let decoded: Bool

            do {
                _ = try input.withUnsafeMutableBufferPointer { buffer -> Int in
                    stream.setInput(UnsafeBufferPointer(buffer))

                    return try output.withUnsafeMutableBufferPointer {
                        try stream.inflate(into: $0.baseAddress!, count: $0.count)
                    }
                }
                decoded = true
            } catch {
                decoded = false
            }

            #expect(decoded == shouldRead)
        }
    }

    /// A window beyond fifteen is outside the format however much the caller allocated.
    @Test("A window size outside the format is refused")
    func windowOutOfRange() throws {
        // CINFO of 8 declares a 64 KiB window; the check bits are fixed up so the header is
        // otherwise well formed and only the window is wrong.
        let cmf: UInt32 = 0x88
        var flg: UInt32 = 0

        while (cmf * 256 + flg) % 31 != 0 { flg += 1 }

        #expect(throws: DeflateError.self) {
            _ = try Self.inflate([UInt8(cmf), UInt8(flg), 0x03, 0x00])
        }
    }

    @Test("A bad zlib header is refused")
    func badHeader() throws {
        #expect(throws: DeflateError.self) {
            _ = try Self.inflate([0x00, 0x00, 0x03, 0x00])
        }
    }

    /// A preset-dictionary stream stops and asks rather than failing or guessing: it is well
    /// formed, and simply refers to text that was never in it.
    @Test("A preset-dictionary stream asks for the dictionary")
    func presetDictionary() throws {
        let dictionary = Array("the quick brown fox jumps over the lazy dog. ".utf8)
        let payload = Array("the quick brown fox is quicker than the lazy dog".utf8)

        let compressor = Compressor(level: 6)
        var mutableDictionary = dictionary

        mutableDictionary.withUnsafeMutableBufferPointer {
            #expect(compressor.setDictionary(UnsafeBufferPointer($0)))
        }

        var compressed: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 512)
        var mutablePayload = payload

        try mutablePayload.withUnsafeMutableBufferPointer { buffer in
            compressor.setInput(UnsafeBufferPointer(buffer))

            while !compressor.isFinished {
                let made = try scratch.withUnsafeMutableBufferPointer {
                    try compressor.deflate(into: $0.baseAddress!, count: $0.count, ending: .finish)
                }
                compressed.append(contentsOf: scratch[0 ..< made])
            }
        }

        // §2.2: the flag is set, and the dictionary's checksum follows the header.
        #expect((compressed[1] >> 5) & 1 == 1)

        var expectedId = Adler32()
        dictionary.withUnsafeBufferPointer { expectedId.update($0) }

        let stream = Decompressor()
        var output = [UInt8](repeating: 0, count: 512)
        var produced = 0
        var input = compressed

        try input.withUnsafeMutableBufferPointer { buffer in
            stream.setInput(UnsafeBufferPointer(buffer))

            produced = try output.withUnsafeMutableBufferPointer {
                try stream.inflate(into: $0.baseAddress!, count: $0.count)
            }
        }

        #expect(stream.needsDictionary)
        #expect(stream.dictionaryId == expectedId.value)
        #expect(produced == 0)
        #expect(!stream.isFinished)

        mutableDictionary.withUnsafeMutableBufferPointer {
            #expect(stream.setDictionary(UnsafeBufferPointer($0)))
        }

        produced += try output.withUnsafeMutableBufferPointer {
            try stream.inflate(into: $0.baseAddress! + produced, count: $0.count - produced)
        }

        #expect(stream.isFinished)
        #expect(Array(output[0 ..< produced]) == payload)
    }

    /// Matching against a dictionary is the point of having one, so a payload that shares its
    /// text has to come out smaller with one than without.
    @Test("A dictionary makes a small stream smaller")
    func dictionaryHelps() throws {
        let dictionary = Array(String(repeating: "abcdefghij", count: 40).utf8)
        let payload = Array(String(repeating: "abcdefghij", count: 6).utf8)

        let plain = try CompressorTests.compress(payload)

        let compressor = Compressor(level: 6)
        var mutableDictionary = dictionary
        mutableDictionary.withUnsafeMutableBufferPointer {
            _ = compressor.setDictionary(UnsafeBufferPointer($0))
        }

        var withDictionary: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 512)
        var mutablePayload = payload

        try mutablePayload.withUnsafeMutableBufferPointer { buffer in
            compressor.setInput(UnsafeBufferPointer(buffer))

            while !compressor.isFinished {
                let made = try scratch.withUnsafeMutableBufferPointer {
                    try compressor.deflate(into: $0.baseAddress!, count: $0.count, ending: .finish)
                }
                withDictionary.append(contentsOf: scratch[0 ..< made])
            }
        }

        // Four bytes of dictionary id are the price; the match that reaches back into it more
        // than pays for them.
        #expect(withDictionary.count < plain.count)
    }
}
