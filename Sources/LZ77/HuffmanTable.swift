// HuffmanTable.swift - canonical Huffman decoding
//
// DEFLATE never sends a Huffman tree; it sends one code length per symbol, and the codes
// themselves are reconstructed from those lengths by a fixed rule (RFC 1951 §3.2.2): among
// symbols of the same length, the numerically smallest code goes to the symbol that comes
// first, and the code for a symbol one bit longer is the previous code plus one, shifted left.
// That rule is what "canonical" means here, and it is why the length list is enough on its own.
//
// Decoding walks the input one bit at a time, building up a value the same way the codes were
// built — most significant bit first, which is DEFLATE's one field that is not read the way
// this module's `BitReader` reads everything else — and checks after each bit whether that
// value, at that length, names a symbol. It always terminates at or before the longest code in
// the table, and every value along the way is either a valid shorter code or an unused prefix,
// never both, which is what makes a prefix code decodable without a separator.
//
// Two decoders, over the same lengths. The arithmetic one below walks a bit at a time and needs
// one entry per symbol; the lookup one resolves a short code in a single indexing operation, at
// the cost of one entry per bit pattern up to its root length. Short codes are the common case
// by construction — that is what Huffman coding is — so the table answers most symbols, and the
// arithmetic path answers the long tail and every symbol near the end of the input, where there
// may not be enough bits buffered to index with.
//
// The lookup table is indexed by the bits in the order the stream delivers them, least
// significant first, which is the reverse of the order a code is defined in. Reversing once when
// the table is built is what saves reversing on every symbol decoded.
struct HuffmanTable {
    static let maxBits = 15

    /// The first canonical code at each length, 1...maxBits.
    private let firstCode: [UInt32]

    /// Where each length's symbols begin in `symbols`, which is sorted by (length, canonical
    /// order within that length).
    private let firstSymbolIndex: [Int]

    /// How many symbols have each length.
    private let count: [Int]

    private let symbols: [UInt16]

    /// How many bits the lookup table is indexed by. Nine covers the fixed alphabet's literals
    /// and, in practice, most of a fitted one — past that the table doubles in size for a
    /// shrinking share of the symbols.
    static let fastBits = 9

    /// One entry per bit pattern: the code's length in the top four bits and its symbol in the
    /// low nine, or zero where no code of `fastBits` or fewer begins with that pattern.
    ///
    /// Zero is unambiguous as "no entry" because a real entry always carries a length of at
    /// least one, and so is never zero whatever its symbol.
    private let fast: [UInt16]

    /// Builds the table from one code length per symbol; a length of zero means the symbol is
    /// not in this alphabet at all.
    ///
    /// - Parameter allowingIncomplete: whether a set of lengths that does not fill the code
    ///   space may be accepted. Only §3.2.7's one case may: a distance alphabet of a single
    ///   one-bit code, which the format explicitly permits and which leaves one code unused.
    init(lengths: [UInt8], allowingIncomplete: Bool = false) throws(DeflateError) {
        var blCount = [Int](repeating: 0, count: Self.maxBits + 1)

        for length in lengths where length > 0 {
            guard Int(length) <= Self.maxBits else {
                throw DeflateError("Huffman code too long")
            }

            blCount[Int(length)] += 1
        }

        var code: UInt32 = 0
        var nextCode = [UInt32](repeating: 0, count: Self.maxBits + 1)
        var firstSymbolIndexByLength = [Int](repeating: 0, count: Self.maxBits + 1)
        var runningIndex = 0

        for bits in 1 ... Self.maxBits {
            code = (code &+ UInt32(blCount[bits - 1])) << 1

            // More codes claimed at this length than fit below the next length's first code:
            // the lengths cannot have come from a real canonical assignment.
            guard code &+ UInt32(blCount[bits]) <= (UInt32(1) << bits) else {
                throw DeflateError("over-subscribed Huffman table")
            }

            nextCode[bits] = code
            firstSymbolIndexByLength[bits] = runningIndex
            runningIndex += blCount[bits]
        }

        // A set of lengths that leaves part of the code space unclaimed is a set with bit
        // patterns that decode to nothing at all. Reading one is not merely wasteful — it means
        // a stream can be built whose codes are ambiguous about where they end, and a decoder
        // that only notices when such a pattern happens to turn up will accept corrupt input
        // that never happens to contain one. The reference refuses these at table-build time
        // and so does this.
        //
        // Counted the same way the space is spent: a code of `bits` claims 2^(maxBits - bits)
        // of a budget of 2^maxBits, so the arithmetic is exact.
        var claimed = 0

        for bits in 1 ... Self.maxBits {
            claimed += blCount[bits] << (Self.maxBits - bits)
        }

        let full = 1 << Self.maxBits
        let onlySingleOneBitCode = blCount[1] == 1 && (2 ... Self.maxBits).allSatisfy {
            blCount[$0] == 0
        }

        if claimed < full, !(allowingIncomplete && onlySingleOneBitCode) {
            // An alphabet with nothing in it at all is not incomplete, it is absent, and a
            // block may legitimately declare one — a distance table for a block with no matches.
            guard claimed == 0 else {
                throw DeflateError("incomplete Huffman table")
            }
        }

        var symbolsByPosition = [UInt16](repeating: 0, count: runningIndex)
        var nextIndexAtLength = firstSymbolIndexByLength

        for (symbol, length) in lengths.enumerated() where length > 0 {
            let position = nextIndexAtLength[Int(length)]
            symbolsByPosition[position] = UInt16(symbol)
            nextIndexAtLength[Int(length)] = position + 1
        }

        self.firstCode = nextCode
        self.firstSymbolIndex = firstSymbolIndexByLength
        self.count = blCount
        self.symbols = symbolsByPosition

        // Every pattern whose low `length` bits are this code maps to it, whatever the bits
        // above — those belong to whatever symbol comes next and are left in the reader.
        var fast = [UInt16](repeating: 0, count: 1 << Self.fastBits)
        var assigned = nextCode

        for (symbol, length) in lengths.enumerated() where length > 0 && length <= Self.fastBits {
            let code = assigned[Int(length)]
            assigned[Int(length)] += 1

            let reversed = Self.reversed(code, bits: Int(length))
            let entry = UInt16(length) << 12 | UInt16(symbol)
            let step = 1 << Int(length)

            var index = Int(reversed)
            while index < fast.count {
                fast[index] = entry
                index += step
            }
        }

        self.fast = fast
    }

    /// A code is defined most significant bit first and arrives least significant bit first, so
    /// the table is indexed by the code turned around.
    private static func reversed(_ code: UInt32, bits: Int) -> UInt32 {
        var reversed: UInt32 = 0

        for index in 0 ..< bits {
            reversed |= ((code >> (bits - 1 - index)) & 1) << index
        }

        return reversed
    }

    /// One symbol as it is decoded, a bit at a time, so a call that ran out of input can pick up
    /// exactly where it left off rather than restart the symbol from nothing.
    struct Partial {
        var code: UInt32 = 0
        var length = 0
    }

    enum DecodeResult {
        case symbol(UInt16)
        case needsInput
    }

    /// Decodes one symbol, resuming from `partial` and updating it in place.
    ///
    /// `partial` is reset to empty when a symbol completes; a caller starting a new symbol
    /// passes a fresh `Partial()`.
    func decode(_ reader: inout BitReader, partial: inout Partial) throws(DeflateError) -> DecodeResult {
        // The table only answers a symbol started from nothing, and only when there are enough
        // bits buffered to index with. Mid-symbol, or near the end of the input, the arithmetic
        // path below picks it up — which is also what keeps a resumed decode correct.
        if partial.length == 0, reader.ensure(Self.fastBits) {
            let entry = self.fast[Int(reader.peek(Self.fastBits))]

            if entry != 0 {
                reader.drop(Int(entry >> 12))
                return .symbol(entry & 0x1FF)
            }
        }

        while partial.length < Self.maxBits {
            guard let bit = reader.bits(1) else { return .needsInput }

            partial.code = (partial.code << 1) | bit
            partial.length += 1

            let length = partial.length

            guard self.count[length] > 0 else { continue }

            let offset = Int(partial.code) - Int(self.firstCode[length])

            guard offset >= 0, offset < self.count[length] else { continue }

            let symbol = self.symbols[self.firstSymbolIndex[length] + offset]
            partial = Partial()
            return .symbol(symbol)
        }

        throw DeflateError("invalid Huffman code")
    }
}
