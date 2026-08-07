import Testing

@testable import Zlib

/// The compressor is checked by decoding its output with this module's own decompressor, and
/// separately by asserting the framing directly — a round trip alone would pass just as
/// happily if both sides agreed on framing nobody else uses.
@Suite("Compressor")
struct CompressorTests {
    static func compress(
        _ payload: [UInt8],
        level: Int32 = 6,
        windowBits: Int32 = 15,
        feeding chunkSize: Int = Int.max,
        collecting bufferSize: Int = 4096
    ) throws -> [UInt8] {
        let compressor = Compressor(level: level, windowBits: windowBits)
        var compressed: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: bufferSize)
        var offset = 0
        var payload = payload

        try payload.withUnsafeMutableBufferPointer { buffer in
            while offset < buffer.count {
                let size = min(chunkSize, buffer.count - offset)
                compressor.setInput(
                    UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: size)
                )
                offset += size

                while !compressor.needsInput {
                    let made = try scratch.withUnsafeMutableBufferPointer { out in
                        try compressor.deflate(into: out.baseAddress!, count: out.count)
                    }

                    compressed.append(contentsOf: scratch[0 ..< made])

                    if made == 0 { break }
                }
            }

            compressor.setInput(UnsafeBufferPointer(start: nil, count: 0))

            while !compressor.isFinished {
                let made = try scratch.withUnsafeMutableBufferPointer { out in
                    try compressor.deflate(into: out.baseAddress!, count: out.count, ending: .finish)
                }

                compressed.append(contentsOf: scratch[0 ..< made])
            }
        }

        return compressed
    }

    static func roundTrip(_ payload: [UInt8], level: Int32 = 6) throws -> [UInt8] {
        try DecompressorTests.inflate(
            Self.compress(payload, level: level),
            into: max(payload.count, 1) * 2 + 64
        )
    }

    @Test("Empty input produces a valid empty stream")
    func empty() throws {
        #expect(try Self.roundTrip([]) == [])
    }

    @Test("A repetitive payload survives matching")
    func repetitive() throws {
        var payload: [UInt8] = []

        for index in 0 ..< 4096 {
            payload.append(UInt8(truncatingIfNeeded: index / 7))
            payload.append(contentsOf: Array("abcabcabc".utf8))
        }

        #expect(try Self.roundTrip(payload) == payload)
    }

    @Test("A payload larger than the window")
    func largerThanWindow() throws {
        var payload: [UInt8] = []

        for index in 0 ..< 98304 {
            payload.append(UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 11)))
        }

        #expect(try Self.roundTrip(payload) == payload)
    }

    /// The framing itself, asserted rather than merely round-tripped.
    @Test("The stream is framed as RFC 1950 requires")
    func framing() throws {
        let payload = Array("The quick brown fox jumps over the lazy dog".utf8)
        let compressed = try Self.compress(payload)

        // §2.2: deflate, 32 KiB window, and the two header bytes divisible by 31 as a
        // big-endian pair.
        #expect(compressed[0] & 0x0F == 8)
        #expect((UInt32(compressed[0]) * 256 + UInt32(compressed[1])) % 31 == 0)

        // No preset dictionary.
        #expect((compressed[1] >> 5) & 1 == 0)

        var checksum = Adler32()
        payload.withUnsafeBufferPointer { checksum.update($0) }
        let value = checksum.value

        #expect(Array(compressed.suffix(4)) == [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    /// An empty stream is header, empty final block, and checksum — nothing else, and no
    /// padding a decoder would have to tolerate.
    @Test("An empty stream is exactly its framing")
    func emptyStreamLength() throws {
        #expect(try Self.compress([]).count == 8)
    }

    /// The header and the trailer are both handed over through the same buffer the compressed
    /// data is, so a caller collecting one byte at a time has to get the identical stream —
    /// this is where framing that assumed it would fit in one go would come apart.
    @Test("Collecting one byte at a time gives the same stream")
    func bytewiseCollection() throws {
        let payload = Array(String(repeating: "repeat me, ", count: 300).utf8)

        #expect(try Self.compress(payload, collecting: 1) == Self.compress(payload))
    }

    @Test("Input fed in small chunks gives a stream that still decodes")
    func chunkedFeeding() throws {
        let payload = Array(String(repeating: "a longer phrase that repeats, ", count: 200).utf8)
        let compressed = try Self.compress(payload, feeding: 64)

        #expect(try DecompressorTests.inflate(compressed, into: payload.count * 2 + 64) == payload)
    }

    /// The vectorised checksum against the bytewise definition, across every boundary the
    /// vector path has: the sixteen-byte grouping, the 5552-byte reduction budget, both at
    /// once, and a split update whose state has to carry across the call.
    @Test("The block checksum is the bytewise checksum", arguments:
        [0, 1, 15, 16, 17, 31, 5551, 5552, 5553, 11104, 100_000] as [Int])
    func adlerAgreesWithDefinition(_ size: Int) {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

        var data = [UInt8](repeating: 0, count: size)
        for index in 0 ..< size {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            data[index] = index % 3 == 0 ? 255 : UInt8(truncatingIfNeeded: seed >> 41)
        }

        var bytewise = Adler32()
        for byte in data { bytewise.update(byte) }

        var block = Adler32()
        data.withUnsafeBufferPointer { block.update($0) }
        #expect(block.value == bytewise.value)

        if size > 40 {
            var split = Adler32()
            data[0 ..< 23].withUnsafeBufferPointer { split.update($0) }
            data[23...].withUnsafeBufferPointer { split.update($0) }
            #expect(split.value == bytewise.value)
        }
    }
}
