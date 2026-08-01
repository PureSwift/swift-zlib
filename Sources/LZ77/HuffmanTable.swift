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
// This is table lookup by arithmetic rather than by array, which keeps memory to one entry per
// symbol rather than one per possible bit pattern — the entries an embedded target can spare are
// few enough that the difference matters, and decoding one bit at a time rather than several is
// the trade made for it. A faster table-driven decode is possible later without changing what
// this reports.
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

    /// Builds the table from one code length per symbol; a length of zero means the symbol is
    /// not in this alphabet at all.
    init(lengths: [UInt8]) throws(DeflateError) {
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
