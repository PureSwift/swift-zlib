// DeflateTables.swift - the fixed numbers RFC 1951 assigns
//
// Every value here is the format's own, not a choice this implementation makes, and each is
// cited to the section that defines it so a mismatch can be checked against the source rather
// than against this file's memory of it.

enum DeflateTables {
    /// §3.2.6: the code lengths the fixed literal/length alphabet uses when a block declares
    /// itself BTYPE 01 rather than carrying its own table.
    static let fixedLiteralLengths: [UInt8] = {
        var lengths = [UInt8](repeating: 0, count: 288)

        for symbol in 0 ..< 288 {
            switch symbol {
            case 0 ... 143: lengths[symbol] = 8
            case 144 ... 255: lengths[symbol] = 9
            case 256 ... 279: lengths[symbol] = 7
            default: lengths[symbol] = 8
            }
        }

        return lengths
    }()

    /// §3.2.6: the fixed distance alphabet, five bits for every symbol including the two the
    /// format reserves and a compliant stream never uses.
    static let fixedDistanceLengths = [UInt8](repeating: 5, count: 32)

    /// §3.2.7: the order the code-length alphabet's own lengths arrive in, which is neither
    /// ascending nor the symbol order — the format sends the ones a real block is likeliest to
    /// need first, so a block that omits the rest can say so cheaply.
    static let codeLengthOrder: [Int] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    /// §3.2.5: how many extra bits follow a length symbol (257...285), and the smallest length
    /// that symbol's extra bits are added to.
    static let lengthExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]

    static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]

    /// §3.2.5: the same shape for the distance alphabet (0...29).
    static let distanceExtraBits: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    static let distanceBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577,
    ]

    /// The literal/length alphabet's end-of-block symbol, the same in every table it appears in.
    static let endOfBlock: UInt16 = 256

    /// How far back a match can point and how much of it this format ever asks a decoder to
    /// keep, both fixed by the 15-bit distance extra-bits table above topping out at 32768.
    static let windowSize = 32768
}
