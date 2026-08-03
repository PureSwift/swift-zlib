import Testing

@testable import LZ77

/// Dynamic blocks fit a code table to the block and send it, so what is under test is the
/// table: that its lengths form a prefix code, that none exceeds what the format allows however
/// skewed the input, and that the block is only chosen when it actually pays for itself.
@Suite("Dynamic blocks")
struct DynamicBlockTests {
    /// The rule every set of code lengths has to satisfy to be decodable: the codes exactly fill
    /// the space available, or leave some of it unused, but never claim more than exists.
    ///
    /// A table that over-subscribes produces two symbols with the same code, which no decoder
    /// can tell apart — and which a round trip finds only if the ambiguous pair happens to occur.
    static func kraftSum(_ lengths: [UInt8], maxBits: Int) -> Double {
        lengths.filter { $0 > 0 }.reduce(0.0) { $0 + Self.pow2(-Int($1)) }
    }

    static func pow2(_ exponent: Int) -> Double {
        var value = 1.0
        for _ in 0 ..< (-exponent) { value /= 2 }
        return value
    }

    @Test("Lengths form a prefix code and stay inside the limit")
    func lengthsAreValid() throws {
        var generator = SplitMix(seed: 0x5EED)

        for trial in 0 ..< 200 {
            var frequencies = [Int](repeating: 0, count: 286)

            // A mix of shapes: a few symbols, many symbols, and steeply skewed weights, which is
            // what drives an unconstrained tree past fifteen levels.
            let used = 1 + Int(generator.next() % 286)

            for _ in 0 ..< used {
                let symbol = Int(generator.next() % 286)
                let weight = trial % 3 == 0
                    ? 1 << (generator.next() % 40) // steep, to force deep codes
                    : 1 + generator.next() % 1000

                frequencies[symbol] += Int(weight)
            }

            guard frequencies.contains(where: { $0 > 0 }) else { continue }

            let lengths = HuffmanBuilder.lengths(frequencies: frequencies, maxBits: 15)

            #expect(lengths.allSatisfy { $0 <= 15 })

            // Every symbol that occurs must have a code. The converse holds except in the
            // one-symbol case, where a second code is handed out on purpose to keep the table
            // complete — so what is asserted is that no *occurring* symbol is left out.
            for symbol in frequencies.indices where frequencies[symbol] > 0 {
                #expect(lengths[symbol] > 0)
            }

            // Exactly filling the code space, not merely staying inside it. A table that
            // leaves part of it unclaimed has bit patterns decoding to nothing, and a decoder
            // that refuses those — as this module's and the reference's both do — rejects any
            // stream carrying one.
            let sum = Self.kraftSum(lengths, maxBits: 15)
            #expect(abs(sum - 1.0) < 0.0000001, "table does not fill the code space: \(sum)")
        }
    }

    /// One symbol is a real case — a block of nothing but end-of-block — and it gets *two*
    /// one-bit codes rather than one.
    ///
    /// One would be legal for the distance alphabet and is not legal for the code-length
    /// alphabet, and a decoder that refuses incomplete tables rejects a stream carrying one.
    /// The spare code costs a bit that never appears in the output.
    @Test("A single symbol still yields a complete table")
    func singleSymbol() throws {
        var frequencies = [Int](repeating: 0, count: 286)
        frequencies[256] = 1

        let lengths = HuffmanBuilder.lengths(frequencies: frequencies, maxBits: 15)

        #expect(lengths[256] == 1)
        #expect(lengths.filter { $0 > 0 }.count == 2)
        #expect(abs(Self.kraftSum(lengths, maxBits: 15) - 1.0) < 0.0000001)
    }

    /// An empty block is the case that produces a one-symbol alphabet in practice, so it is
    /// worth checking end to end rather than only at the table.
    @Test("An empty block round-trips")
    func emptyBlock() throws {
        #expect(try DeflateTests.roundTrip([], level: 6) == [])
    }

    /// Canonical codes have to be distinct, and assigned shortest-first in symbol order, since
    /// that is the only thing the decoder reconstructs them from.
    @Test("Codes are distinct within a length")
    func codesAreDistinct() throws {
        var frequencies = [Int](repeating: 0, count: 286)
        for symbol in 0 ..< 286 { frequencies[symbol] = (symbol % 17) + 1 }

        let lengths = HuffmanBuilder.lengths(frequencies: frequencies, maxBits: 15)
        let codes = HuffmanBuilder.codes(lengths: lengths, maxBits: 15)

        var seen = Set<String>()

        for symbol in lengths.indices where lengths[symbol] > 0 {
            let key = "\(lengths[symbol]):\(codes[symbol])"
            #expect(!seen.contains(key), "duplicate code for symbol \(symbol)")
            seen.insert(key)
        }
    }

    /// A block with no matches still has to declare a distance code, because the format counts
    /// at least one whether or not it is used.
    @Test("A block of pure literals still declares a distance code")
    func literalsOnlyStillDeclaresDistance() throws {
        var literals = [Int](repeating: 0, count: 286)
        literals[65] = 100
        literals[66] = 50
        literals[256] = 1

        let block = DynamicBlock(
            literalFrequencies: literals,
            distanceFrequencies: [Int](repeating: 0, count: 30),
            extraBits: 0
        )

        #expect(block.distanceCount >= 1)
        #expect(block.distanceLengths.contains { $0 > 0 })
    }

    /// The encoder writes whichever block type is smallest, so a payload that a table pays for
    /// has to come out smaller than the same payload without one.
    @Test("Highly compressible input is smaller than a fixed block would be")
    func dynamicIsChosenWhenItPays() throws {
        let payload = Array(String(repeating: "the quick brown fox. ", count: 400).utf8)

        let compressed = try DeflateTests.compress(payload, level: 6)

        // A fixed block spends at least eight bits per literal and the matches here are long,
        // but the table is what takes this well under a tenth of the input.
        #expect(compressed.count < payload.count / 10)
        #expect(try DeflateTests.roundTrip(payload, level: 6) == payload)
    }

    /// A steeply skewed alphabet is what pushes an unconstrained tree past the format's limit,
    /// so the repaired table has to still round-trip.
    @Test("A skewed alphabet round-trips")
    func skewedAlphabet() throws {
        var payload: [UInt8] = []
        var generator = SplitMix(seed: 99)

        // Symbol i appears about 2^i times, which wants codes far deeper than fifteen bits.
        for symbol in 0 ..< 24 {
            for _ in 0 ..< (1 << symbol) where payload.count < 60000 {
                payload.append(UInt8(symbol))
            }
        }

        payload.shuffle(using: &generator)

        #expect(try DeflateTests.roundTrip(payload, level: 6) == payload)
    }
}

/// A small deterministic generator, so these tests do not depend on a seedable system one.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
