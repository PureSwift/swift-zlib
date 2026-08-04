// DecodeTable.swift - packed Huffman tables for the fast decode path
//
// `HuffmanTable` answers one symbol at a time and can pause mid-code, which is exactly what
// the resumable path needs and exactly what a hot loop does not: per symbol it pays a partial
// check, a table probe that can decline, and an arithmetic walk for the long tail. The tables
// built here answer differently — every possible bit pattern is an entry, and the entry says
// everything the loop needs in one load: how many bits the code took, what kind of symbol it
// was, and either the symbol itself or the match base with its extra-bit count baked in.
//
// The shape is the reference's own (inftrees.c), kept deliberately: a root table indexed by
// the low `rootBits` bits, and for codes longer than that, a second table indexed by the bits
// beyond the root, reached through a link entry. Two loads bound the worst case; one answers
// the common one. The entries bake in the length and distance *bases*, so the fast loop never
// consults the side tables the careful path uses.
//
// Each entry packs into a UInt32:
//
//     bits  [0..7]    how many input bits this entry consumes (for a link entry: the root
//                     width, with the link's own index width in `op`)
//     op    [8..15]   0 = literal, `val` is the byte
//                     16 | n = length or distance, `val` is the base and n its extra bits
//                     32 | .. = end of block
//                     64 = invalid code
//                     1...15 (neither 16, 32 nor 64 set) = link, `val` is the subtable's
//                     offset and `op` the bits it is indexed by
//
// The ordering of those tests in the loop is the reference's, and matters: 16 first (the
// common case after literals), then link, then end-of-block, then invalid.
//
// Tables are written into a caller-owned arena rather than allocated here, because the two
// tables a block needs live inside the decoder's own state and are rebuilt per block; the
// arena bounds are the reference's ENOUGH constants, proven sufficient for every legal set of
// lengths.
enum DecodeTable {
    /// The most entries a literal/length table can need (zlib's ENOUGH_LENS), and the same
    /// for a distance table. A build that would exceed its bound reports failure rather than
    /// writing past it — which cannot happen for lengths that passed `HuffmanTable`'s
    /// validation, but the bound is checked, not assumed.
    static let enoughLengths = 852
    static let enoughDistances = 592

    /// Root index widths, as the reference chooses them.
    static let literalRootBits = 9
    static let distanceRootBits = 6

    enum Kind {
        case codeLengths
        case literals
        case distances
    }

    @inline(__always)
    static func entry(bits: Int, op: Int, val: Int) -> UInt32 {
        UInt32(bits) | UInt32(op) << 8 | UInt32(val) << 16
    }

    // Length symbol 257 + i -> base and extra bits, with the extra count pre-ORed with 16 the
    // way the fast loop reads it. The last three literal entries mark symbols 286/287 (legal
    // to *declare* but not to use) and the sentinel the reference uses for them.
    private static let lengthBase: [UInt16] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0, 0,
    ]
    private static let lengthOp: [UInt8] = [
        16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 18, 18, 18, 18,
        19, 19, 19, 19, 20, 20, 20, 20, 21, 21, 21, 21, 16, 64, 64,
    ]
    private static let distanceBase: [UInt16] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577, 0, 0,
    ]
    private static let distanceOp: [UInt8] = [
        16, 16, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
        23, 23, 24, 24, 25, 25, 26, 26, 27, 27, 28, 28, 29, 29, 64, 64,
    ]

    /// Builds a packed table from one code length per symbol, writing entries at `table`.
    ///
    /// Returns the number of entries used and the root's index width, or nil when the lengths
    /// are over-subscribed, unacceptably incomplete, or would overflow `capacity` — all cases
    /// the careful path has already rejected for any stream that reaches a fast loop, so nil
    /// here only ever means "leave the fast path off".
    static func build(
        _ kind: Kind,
        lengths: [UInt8],
        into table: UnsafeMutablePointer<UInt32>,
        capacity: Int
    ) -> (used: Int, rootBits: Int)? {
        let maxBits = 15
        var count = [Int](repeating: 0, count: maxBits + 1)

        for length in lengths {
            guard Int(length) <= maxBits else { return nil }
            count[Int(length)] += 1
        }

        var root: Int
        switch kind {
        case .codeLengths: root = 7
        case .literals: root = Self.literalRootBits
        case .distances: root = Self.distanceRootBits
        }

        var max = maxBits
        while max >= 1, count[max] == 0 { max -= 1 }
        if root > max { root = max }

        if max == 0 {
            // No symbols at all: a pair of entries that decode to "invalid", so a table always
            // exists to index into. The reference does the same.
            guard capacity >= 2 else { return nil }
            table[0] = Self.entry(bits: 1, op: 64, val: 0)
            table[1] = Self.entry(bits: 1, op: 64, val: 0)
            return (used: 2, rootBits: 1)
        }

        var min = 1
        while min < max, count[min] == 0 { min += 1 }
        if root < min { root = min }

        var left = 1
        for len in 1 ... maxBits {
            left <<= 1
            left -= count[len]
            if left < 0 { return nil }
        }
        if left > 0, kind == .codeLengths || max != 1 { return nil }

        // Symbols sorted by (length, canonical order within the length).
        var offsets = [Int](repeating: 0, count: maxBits + 1)
        for len in 1 ..< maxBits { offsets[len + 1] = offsets[len] + count[len] }

        var work = [UInt16](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            work[offsets[Int(length)]] = UInt16(symbol)
            offsets[Int(length)] += 1
        }

        // What `val` and `op` mean, per alphabet. `match` is where in-symbol space the
        // base/extra arrays begin: below it a symbol is itself the value.
        let base: [UInt16]
        let op: [UInt8]
        let match: Int

        switch kind {
        case .codeLengths:
            base = []; op = []; match = 20 // every symbol (0...18) is a literal value
        case .literals:
            base = Self.lengthBase; op = Self.lengthOp; match = 257
        case .distances:
            base = Self.distanceBase; op = Self.distanceOp; match = 0
        }

        var huff = 0            // the code being assigned, built in reversed order
        var sym = 0             // index into work
        var len = min           // current code length
        var next = 0            // offset of the current (sub)table in the arena
        var curr = root         // index width of the current table
        var drop = 0            // bits dropped before indexing the current table
        var low = -1            // low root bits of the current subtable's prefix
        var used = 1 << root
        let mask = used - 1

        guard used <= capacity else { return nil }

        while true {
            // The entry for the current symbol.
            let here: UInt32
            let symbol = Int(work[sym])

            if symbol + 1 < match {
                here = Self.entry(bits: len - drop, op: 0, val: symbol)
            } else if symbol >= match {
                here = Self.entry(
                    bits: len - drop,
                    op: Int(op[symbol - match]),
                    val: Int(base[symbol - match])
                )
            } else {
                here = Self.entry(bits: len - drop, op: 32 | 64, val: 0) // end of block
            }

            // Replicate it across every index whose low bits match the code.
            var fill = 1 << curr
            let incr = 1 << (len - drop)
            repeat {
                fill -= incr
                table[next + (huff >> drop) + fill] = here
            } while fill != 0

            // Increment the code, in the bit-reversed order the table is indexed by.
            var step = 1 << (len - 1)
            while huff & step != 0 { step >>= 1 }
            if step != 0 {
                huff &= step - 1
                huff += step
            } else {
                huff = 0
            }

            // `count` is consumed as codes are assigned, which is what lets the subtable
            // sizing below see how many codes are *left* at each length.
            sym += 1
            count[len] -= 1
            if count[len] == 0 {
                if len == max { break }
                len = Int(lengths[Int(work[sym])])
            }

            // A code longer than the root that starts a new prefix needs a new subtable.
            if len > root, huff & mask != low {
                if drop == 0 { drop = root }

                next += 1 << curr

                // The subtable is as wide as the longest code sharing this prefix needs.
                curr = len - drop
                var space = 1 << curr
                while curr + drop < max {
                    space -= count[curr + drop]
                    if space <= 0 { break }
                    curr += 1
                    space <<= 1
                }

                used += 1 << curr
                guard used <= capacity else { return nil }

                low = huff & mask
                table[low] = Self.entry(bits: root, op: curr, val: next)
            }
        }

        // An incomplete table (the permitted single-code case) leaves one index undecodable.
        if huff != 0 {
            table[next + (huff >> drop)] = Self.entry(bits: len - drop, op: 64, val: 0)
        }

        return (used: used, rootBits: root)
    }
}
