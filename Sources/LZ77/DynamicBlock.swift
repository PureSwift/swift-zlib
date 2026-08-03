// DynamicBlock.swift - a block that carries its own code tables
//
// §3.2.7's block type, and the one that makes DEFLATE worth using. A fixed block spends the
// same number of bits on a byte whatever the data looks like; a dynamic block first says what
// its data looks like, and then spends bits in proportion. On text that is worth several times
// the size of the table it has to send.
//
// The table is itself compressed, which is the fiddly part: the code lengths are run-length
// encoded with a nineteen-symbol alphabet, and *that* alphabet's lengths are sent raw in an
// order chosen so the ones a real block is unlikely to need come last and can be dropped.
//
// Nothing here decides to use a dynamic block. It builds one and says what it would cost, and
// the caller compares that against the alternatives — which is the only way to be sure the
// table pays for itself, and the reason a small block still comes out as a fixed or stored one.

struct DynamicBlock {
    let literalLengths: [UInt8]
    let literalCodes: [UInt32]
    let distanceLengths: [UInt8]
    let distanceCodes: [UInt32]

    let codeLengthLengths: [UInt8]
    let codeLengthCodes: [UInt32]

    /// The run-length encoding of the two code-length arrays, as symbols of the code-length
    /// alphabet with their extra bits.
    let packed: [(symbol: Int, extra: UInt32, extraBits: Int)]

    let literalCount: Int
    let distanceCount: Int
    let codeLengthCount: Int

    /// What the whole block costs in bits, table and data together, so it can be weighed
    /// against a fixed or stored block over the same symbols.
    let totalBits: Int

    static let maxBits = 15
    static let codeLengthMaxBits = 7

    init(literalFrequencies: [Int], distanceFrequencies: [Int], extraBits: Int) {
        var literalLengths = HuffmanBuilder.lengths(
            frequencies: literalFrequencies,
            maxBits: Self.maxBits
        )

        var distanceLengths = HuffmanBuilder.lengths(
            frequencies: distanceFrequencies,
            maxBits: Self.maxBits
        )

        // §3.2.7: HDIST counts at least one distance code even when the block has no matches at
        // all, so a block of pure literals still declares one, unused.
        if !distanceLengths.contains(where: { $0 > 0 }) {
            distanceLengths[0] = 1
        }

        self.literalLengths = literalLengths
        self.distanceLengths = distanceLengths

        self.literalCodes = HuffmanBuilder.codes(lengths: literalLengths, maxBits: Self.maxBits)
        self.distanceCodes = HuffmanBuilder.codes(lengths: distanceLengths, maxBits: Self.maxBits)

        // Only as many codes as are actually needed; the tail of unused ones is not sent. The
        // literal alphabet never drops below 257, because that is where the length codes start.
        let literalCount = max(257, (literalLengths.lastIndex { $0 > 0 } ?? 0) + 1)
        let distanceCount = max(1, (distanceLengths.lastIndex { $0 > 0 } ?? 0) + 1)

        self.literalCount = literalCount
        self.distanceCount = distanceCount

        literalLengths = Array(literalLengths[0 ..< literalCount])
        distanceLengths = Array(distanceLengths[0 ..< distanceCount])

        // The two arrays are encoded as one run, because a run of equal lengths may cross the
        // boundary between them and the format lets it.
        let packed = Self.runLengthEncode(literalLengths + distanceLengths)
        self.packed = packed

        var codeLengthFrequencies = [Int](repeating: 0, count: 19)
        for item in packed {
            codeLengthFrequencies[item.symbol] += 1
        }

        let codeLengthLengths = HuffmanBuilder.lengths(
            frequencies: codeLengthFrequencies,
            maxBits: Self.codeLengthMaxBits
        )

        self.codeLengthLengths = codeLengthLengths
        self.codeLengthCodes = HuffmanBuilder.codes(
            lengths: codeLengthLengths,
            maxBits: Self.codeLengthMaxBits
        )

        // §3.2.7: the code-length alphabet's own lengths go out in a fixed order chosen so that
        // the entries a real block is least likely to use come last, and the unused tail is
        // dropped. Four is the fewest the format allows.
        var codeLengthCount = 19
        while codeLengthCount > 4,
              codeLengthLengths[DeflateTables.codeLengthOrder[codeLengthCount - 1]] == 0 {
            codeLengthCount -= 1
        }

        self.codeLengthCount = codeLengthCount

        // 3 bits of block header, then 5 + 5 + 4 of counts, then the code-length alphabet raw.
        var bits = 3 + 5 + 5 + 4 + 3 * codeLengthCount

        for item in packed {
            bits += Int(codeLengthLengths[item.symbol]) + item.extraBits
        }

        for symbol in literalFrequencies.indices where literalFrequencies[symbol] > 0 {
            bits += literalFrequencies[symbol] * Int(self.literalLengths[symbol])
        }

        for symbol in distanceFrequencies.indices where distanceFrequencies[symbol] > 0 {
            bits += distanceFrequencies[symbol] * Int(self.distanceLengths[symbol])
        }

        self.totalBits = bits + extraBits
    }

    /// §3.2.7's run-length encoding of the code lengths: 16 repeats the previous length, 17 and
    /// 18 are runs of zero, and everything else is a length written as itself.
    private static func runLengthEncode(
        _ lengths: [UInt8]
    ) -> [(symbol: Int, extra: UInt32, extraBits: Int)] {
        var packed: [(symbol: Int, extra: UInt32, extraBits: Int)] = []
        var index = 0

        while index < lengths.count {
            let length = lengths[index]
            var run = 1

            while index + run < lengths.count, lengths[index + run] == length {
                run += 1
            }

            index += run

            if length == 0 {
                // Two ranges rather than one, because a long run of unused symbols is the
                // commonest thing in a real table and seven extra bits covers it in one go.
                while run >= 11 {
                    let take = min(run, 138)
                    packed.append((18, UInt32(take - 11), 7))
                    run -= take
                }

                while run >= 3 {
                    let take = min(run, 10)
                    packed.append((17, UInt32(take - 3), 3))
                    run -= take
                }

                for _ in 0 ..< run {
                    packed.append((0, 0, 0))
                }
            } else {
                // The first one is written as itself; only what follows can be a repeat, since
                // 16 copies "the previous length" and there must be one.
                packed.append((Int(length), 0, 0))
                run -= 1

                while run >= 3 {
                    let take = min(run, 6)
                    packed.append((16, UInt32(take - 3), 2))
                    run -= take
                }

                for _ in 0 ..< run {
                    packed.append((Int(length), 0, 0))
                }
            }
        }

        return packed
    }

    /// Writes the table: the counts, the code-length alphabet, and the packed lengths.
    func writeTable(to writer: inout BitWriter) {
        writer.write(UInt32(self.literalCount - 257), bits: 5)
        writer.write(UInt32(self.distanceCount - 1), bits: 5)
        writer.write(UInt32(self.codeLengthCount - 4), bits: 4)

        for index in 0 ..< self.codeLengthCount {
            writer.write(
                UInt32(self.codeLengthLengths[DeflateTables.codeLengthOrder[index]]),
                bits: 3
            )
        }

        for item in self.packed {
            writer.writeCode(
                self.codeLengthCodes[item.symbol],
                bits: Int(self.codeLengthLengths[item.symbol])
            )

            if item.extraBits > 0 {
                writer.write(item.extra, bits: item.extraBits)
            }
        }
    }
}
