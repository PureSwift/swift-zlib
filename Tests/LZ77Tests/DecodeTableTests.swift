import Testing

@testable import LZ77

/// The packed tables answer with one load what the arithmetic decoder answers with a walk, so
/// the test is agreement: every symbol's canonical code, fed to the packed table as the bits
/// would arrive off the wire, must come back as that symbol with its length — and for the
/// match alphabets, with the base and extra-bit count the entry bakes in.
@Suite("Packed decode tables")
struct DecodeTableTests {
    /// The canonical code for each symbol, from the lengths, by RFC 1951 §3.2.2's rule.
    static func canonicalCodes(_ lengths: [UInt8]) -> [(symbol: Int, code: UInt32, length: Int)] {
        var blCount = [Int](repeating: 0, count: 16)
        for length in lengths where length > 0 { blCount[Int(length)] += 1 }

        var code: UInt32 = 0
        var nextCode = [UInt32](repeating: 0, count: 16)
        for bits in 1 ... 15 {
            code = (code + UInt32(blCount[bits - 1])) << 1
            nextCode[bits] = code
        }

        var out: [(Int, UInt32, Int)] = []
        for (symbol, length) in lengths.enumerated() where length > 0 {
            out.append((symbol, nextCode[Int(length)], Int(length)))
            nextCode[Int(length)] += 1
        }
        return out
    }

    static func reversed(_ code: UInt32, bits: Int) -> UInt64 {
        var out: UInt64 = 0
        for index in 0 ..< bits {
            out |= UInt64((code >> (bits - 1 - index)) & 1) << index
        }
        return out
    }

    /// Decodes one symbol from `hold` the way the fast loop does: root entry, then at most one
    /// link to a subtable.
    static func decode(
        _ table: [UInt32], rootBits: Int, hold: UInt64
    ) -> (op: Int, val: Int, consumed: Int) {
        var entry = table[Int(hold & ((1 << UInt64(rootBits)) - 1))]
        var consumed = Int(entry & 0xFF)
        var op = Int((entry >> 8) & 0xFF)

        if op != 0, op & (16 | 32 | 64) == 0 {
            let index = Int((hold >> UInt64(consumed)) & ((1 << UInt64(op)) - 1))
            entry = table[Int(entry >> 16) + index]
            consumed += Int(entry & 0xFF)
            op = Int((entry >> 8) & 0xFF)
        }

        return (op, Int(entry >> 16), consumed)
    }

    static func build(_ kind: DecodeTable.Kind, _ lengths: [UInt8]) -> ([UInt32], Int)? {
        let capacity = DecodeTable.enoughLengths
        var arena = [UInt32](repeating: 0, count: capacity)
        let result = arena.withUnsafeMutableBufferPointer { buffer in
            DecodeTable.build(kind, lengths: lengths, into: buffer.baseAddress!, capacity: capacity)
        }
        guard let result else { return nil }
        return (arena, result.rootBits)
    }

    @Test("Every fixed literal/length code decodes to its own symbol")
    func fixedLiterals() throws {
        let lengths = DeflateTables.fixedLiteralLengths
        let (table, rootBits) = try #require(Self.build(.literals, lengths))

        for (symbol, code, length) in Self.canonicalCodes(lengths) {
            // Bits beyond the code filled with ones, so a table that read too far would read
            // garbage rather than zeroes that happen to be harmless.
            let hold = Self.reversed(code, bits: length) | (~UInt64(0) << UInt64(length))
            let (op, val, consumed) = Self.decode(table, rootBits: rootBits, hold: hold)

            #expect(consumed == length)

            switch symbol {
            case ..<256:
                #expect(op == 0)
                #expect(val == symbol)
            case 256:
                #expect(op & 32 != 0)
            case 286...:
                #expect(op == 64) // declarable but never usable
            default:
                #expect(op & 16 != 0)
                #expect(val == DeflateTables.lengthBase[symbol - 257])
                #expect(op & 15 == DeflateTables.lengthExtraBits[symbol - 257])
            }
        }
    }

    @Test("Every fixed distance code decodes to its base and extra count")
    func fixedDistances() throws {
        let lengths = DeflateTables.fixedDistanceLengths
        let (table, rootBits) = try #require(Self.build(.distances, lengths))

        for (symbol, code, length) in Self.canonicalCodes(lengths) {
            let hold = Self.reversed(code, bits: length) | (~UInt64(0) << UInt64(length))
            let (op, val, consumed) = Self.decode(table, rootBits: rootBits, hold: hold)

            #expect(consumed == length)

            if symbol <= 29 {
                #expect(op & 16 != 0)
                #expect(val == DeflateTables.distanceBase[symbol])
                #expect(op & 15 == DeflateTables.distanceExtraBits[symbol])
            } else {
                #expect(op == 64) // 30 and 31 are declarable, never usable
            }
        }
    }

    @Test("Codes longer than the root resolve through subtables")
    func subtables() throws {
        // A complete canonical set with one code at every length up to 15: lengths past the
        // 9-bit root land in subtables, which is the half of the layout the fixed alphabets
        // never exercise.
        var lengths = [UInt8](1 ... 14)
        lengths.append(15)
        lengths.append(15)

        let (table, rootBits) = try #require(Self.build(.literals, lengths))
        #expect(rootBits == 9)

        for (symbol, code, length) in Self.canonicalCodes(lengths) {
            let hold = Self.reversed(code, bits: length) | (~UInt64(0) << UInt64(length))
            let (op, val, consumed) = Self.decode(table, rootBits: rootBits, hold: hold)

            #expect(consumed == length)
            #expect(op == 0)
            #expect(val == symbol)
        }
    }

    @Test("The permitted incomplete distance table decodes its one code and rejects the other")
    func incompleteSingleCode() throws {
        var lengths = [UInt8](repeating: 0, count: 30)
        lengths[3] = 1

        let (table, rootBits) = try #require(Self.build(.distances, lengths))

        let (op, val, _) = Self.decode(table, rootBits: rootBits, hold: 0)
        #expect(op & 16 != 0)
        #expect(val == DeflateTables.distanceBase[3])

        let (badOp, _, _) = Self.decode(table, rootBits: rootBits, hold: 1)
        #expect(badOp == 64)
    }

    @Test("An empty alphabet builds a table that decodes to invalid")
    func emptyAlphabet() throws {
        let (table, rootBits) = try #require(Self.build(.distances, [UInt8](repeating: 0, count: 30)))

        let (op, _, _) = Self.decode(table, rootBits: rootBits, hold: 0)
        #expect(op == 64)
    }

    @Test("Over-subscribed and incomplete literal alphabets are refused")
    func refusals() {
        #expect(Self.build(.literals, [2, 2, 2, 2, 2]) == nil) // over-subscribed
        #expect(Self.build(.literals, [2, 2, 2]) == nil) // incomplete, not the permitted case
    }
}
