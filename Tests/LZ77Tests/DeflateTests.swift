import Testing

@testable import LZ77

/// The compressor is checked by decoding its output with this module's own decoder — which the
/// suite above has already checked against streams from a known-good compressor, so the pair is
/// not merely agreeing with itself. What this cannot show on its own is that the output is
/// DEFLATE data *zlib* accepts; that wants a differential test against the reference, which
/// belongs to whichever module wraps this one into a stream zlib can be handed.
@Suite("Deflate")
struct DeflateTests {
    static func roundTrip(
        _ payload: [UInt8],
        level: Int32,
        feeding chunkSize: Int = Int.max
    ) throws -> [UInt8] {
        let compressor = Deflate(level: level)
        var compressed: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 4096)
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

        return try InflateTests.inflate(compressed, into: max(payload.count, 1) * 2 + 64)
    }

    @Test("Empty input produces a valid empty stream")
    func empty() throws {
        #expect(try Self.roundTrip([], level: 6) == [])
    }

    @Test("Literals only, at the level that never matches")
    func literalsOnly() throws {
        let payload = Array("The quick brown fox jumps over the lazy dog".utf8)
        #expect(try Self.roundTrip(payload, level: 0) == payload)
    }

    @Test("A repetitive payload survives matching")
    func repetitive() throws {
        var payload: [UInt8] = []

        for index in 0 ..< 4096 {
            payload.append(UInt8(truncatingIfNeeded: index / 7))
            payload.append(contentsOf: Array("abcabcabc".utf8))
        }

        #expect(try Self.roundTrip(payload, level: 6) == payload)
    }

    @Test("Pseudo-random bytes survive, at every level band")
    func incompressible() throws {
        var payload: [UInt8] = []
        var state: UInt32 = 0x2545_F491

        for _ in 0 ..< 20000 {
            // xorshift, so the data is deterministic without a seed API.
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            payload.append(UInt8(truncatingIfNeeded: state))
        }

        for level: Int32 in [0, 1, 6, 9] {
            #expect(try Self.roundTrip(payload, level: level) == payload)
        }
    }

    @Test("Matches that reach across fed-in block boundaries")
    func matchAcrossBlocks() throws {
        let payload = Array(
            String(repeating: "a longer phrase that will surely repeat, ", count: 200).utf8
        )

        #expect(try Self.roundTrip(payload, level: 6, feeding: 64) == payload)
    }

    @Test("A payload larger than the window")
    func largerThanWindow() throws {
        var payload: [UInt8] = []

        for index in 0 ..< (DeflateTables.windowSize * 3) {
            payload.append(UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 11)))
        }

        #expect(try Self.roundTrip(payload, level: 6) == payload)
    }

    /// Nothing this module writes may be RFC 1950 framing: a caller asking for raw DEFLATE and
    /// getting a zlib header would have it silently decoded as a block header by anything else
    /// that reads the result.
    @Test("The output carries no zlib framing")
    func noFraming() throws {
        let compressor = Deflate(level: 6)
        var compressed: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 4096)

        compressor.setInput(UnsafeBufferPointer(start: nil, count: 0))

        while !compressor.isFinished {
            let made = try scratch.withUnsafeMutableBufferPointer { out in
                try compressor.deflate(into: out.baseAddress!, count: out.count, ending: .finish)
            }
            compressed.append(contentsOf: scratch[0 ..< made])
        }

        // An empty zlib stream would be eight bytes: two of header, two of block, four of
        // checksum. Raw DEFLATE for the same input is the block alone.
        #expect(compressed.count == 2)
        #expect(compressed[0] != 0x78)
    }
}
