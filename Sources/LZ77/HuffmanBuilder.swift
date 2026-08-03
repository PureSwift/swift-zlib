// HuffmanBuilder.swift - choosing code lengths for an alphabet
//
// The decoder's side of Huffman is in HuffmanTable: given lengths, reconstruct the codes. This
// is the encoder's side, and it is the harder half — the lengths have to be *chosen*, from how
// often each symbol occurs, and no longer than the format allows.
//
// That limit is what makes this more than textbook Huffman. A plain Huffman tree over a skewed
// alphabet can put a rare symbol thirty levels down, and RFC 1951 §3.2.7 allows fifteen. So the
// tree is built, its depths are capped, and the resulting shape is repaired into something that
// is still a prefix code — costing a fraction of a per cent against the unconstrained optimum,
// which is the trade every DEFLATE encoder makes.

enum HuffmanBuilder {
    /// A code length for every symbol, zero for the ones that never occur, none exceeding
    /// `maxBits`.
    static func lengths(frequencies: [Int], maxBits: Int) -> [UInt8] {
        var lengths = [UInt8](repeating: 0, count: frequencies.count)

        let used = frequencies.indices.filter { frequencies[$0] > 0 }

        guard !used.isEmpty else { return lengths }

        // §3.2.7 allows an alphabet of one, and requires it to be written with one bit rather
        // than none — a code of zero bits would be indistinguishable from the absence of one.
        guard used.count > 1 else {
            lengths[used[0]] = 1
            return lengths
        }

        var depths = self.treeDepths(frequencies: frequencies, used: used)

        // Anything deeper than the format allows is pulled up to the limit, which leaves the
        // shape claiming more codes than exist. `repair` puts that right.
        var counts = [Int](repeating: 0, count: maxBits + 1)

        for symbol in used {
            counts[min(depths[symbol], maxBits)] += 1
        }

        self.repair(&counts, maxBits: maxBits)

        // The lengths are now a valid multiset; which symbol gets which is a separate question,
        // and the answer is that the rarest takes the longest. Pairing them off in opposite
        // orders is what makes the assignment optimal for the shape chosen.
        let byRarity = used.sorted { left, right in
            frequencies[left] == frequencies[right]
                ? left > right
                : frequencies[left] < frequencies[right]
        }

        var index = 0

        for bits in stride(from: maxBits, through: 1, by: -1) {
            for _ in 0 ..< counts[bits] {
                lengths[byRarity[index]] = UInt8(bits)
                index += 1
            }
        }

        return lengths
    }

    /// The depth of every used symbol in an unconstrained Huffman tree.
    private static func treeDepths(frequencies: [Int], used: [Int]) -> [Int] {
        struct Node {
            var weight: Int
            var left: Int
            var right: Int
            var symbol: Int
        }

        // Leaves in weight order, so the two cheapest are always at the front of one queue or
        // the other and merging needs no repeated sorting: every node this makes is at least as
        // heavy as the last, which keeps the second queue ordered for free.
        let ordered = used.sorted { left, right in
            frequencies[left] == frequencies[right]
                ? left < right
                : frequencies[left] < frequencies[right]
        }

        var nodes: [Node] = ordered.map {
            Node(weight: frequencies[$0], left: -1, right: -1, symbol: $0)
        }

        var leaves = Array(nodes.indices)
        var merged: [Int] = []
        var nextLeaf = 0
        var nextMerged = 0

        func takeCheapest() -> Int {
            let haveLeaf = nextLeaf < leaves.count
            let haveMerged = nextMerged < merged.count

            if haveLeaf, !haveMerged || nodes[leaves[nextLeaf]].weight <= nodes[merged[nextMerged]].weight {
                defer { nextLeaf += 1 }
                return leaves[nextLeaf]
            }

            defer { nextMerged += 1 }
            return merged[nextMerged]
        }

        while (leaves.count - nextLeaf) + (merged.count - nextMerged) > 1 {
            let first = takeCheapest()
            let second = takeCheapest()

            nodes.append(
                Node(
                    weight: nodes[first].weight + nodes[second].weight,
                    left: first,
                    right: second,
                    symbol: -1
                )
            )

            merged.append(nodes.count - 1)
        }

        var depths = [Int](repeating: 0, count: frequencies.count)
        var stack: [(node: Int, depth: Int)] = [(nodes.count - 1, 0)]

        while let (node, depth) = stack.popLast() {
            if nodes[node].symbol >= 0 {
                depths[nodes[node].symbol] = depth
                continue
            }

            stack.append((nodes[node].left, depth + 1))
            stack.append((nodes[node].right, depth + 1))
        }

        return depths
    }

    /// Repairs a length distribution that had to be truncated, into one a prefix code can have.
    ///
    /// Capping deep codes leaves the shape over-subscribed: more codes are claimed at the limit
    /// than exist there, and two symbols end up sharing one — which no decoder can tell apart,
    /// and which a round trip only catches if the colliding pair happens to occur.
    ///
    /// The test for that is Kraft's: the codes must fill the space available or leave some of it
    /// spare, never claim more. Counted in units of the shortest possible code, a length of
    /// `bits` takes `2^(maxBits - bits)` of a total budget of `2^maxBits`, so the condition is
    /// exact in integers and needs no tolerance.
    ///
    /// Each turn takes a leaf from the shallowest length that has one — the one whose symbol is
    /// commonest, so the bit costs least — and splits it in two, one of which houses a code from
    /// the crowded limit. That is the same move the reference makes, but repeated until the sum
    /// is actually within budget rather than a fixed number of times: a leaf capped from more
    /// than one level too deep needs more than one turn to pay for, and stopping early leaves a
    /// table that is subtly wrong.
    private static func repair(_ counts: inout [Int], maxBits: Int) {
        let budget = 1 << maxBits
        var claimed = 0

        for bits in 1 ... maxBits {
            claimed += counts[bits] << (maxBits - bits)
        }

        while claimed > budget {
            var bits = maxBits - 1
            while bits > 0, counts[bits] == 0 { bits -= 1 }

            // Unreachable while over budget: codes only at the limit could not exceed it, there
            // being far fewer symbols than codes of that length.
            guard bits > 0 else { return }

            counts[bits] -= 1 // one leaf moves down a level
            counts[bits + 1] += 2 // and becomes a pair, one of which takes a crowded code
            counts[maxBits] -= 1

            // Splitting a leaf is budget-neutral; retiring one at the limit frees exactly one
            // unit, so this always terminates.
            claimed -= 1
        }
    }

    /// The canonical codes for a set of lengths: §3.2.2's rule, the same one the decoder
    /// reconstructs from.
    static func codes(lengths: [UInt8], maxBits: Int) -> [UInt32] {
        var counts = [Int](repeating: 0, count: maxBits + 1)

        for length in lengths where length > 0 {
            counts[Int(length)] += 1
        }

        var next = [UInt32](repeating: 0, count: maxBits + 1)
        var code: UInt32 = 0

        for bits in 1 ... maxBits {
            code = (code &+ UInt32(counts[bits - 1])) << 1
            next[bits] = code
        }

        var codes = [UInt32](repeating: 0, count: lengths.count)

        for symbol in lengths.indices where lengths[symbol] > 0 {
            codes[symbol] = next[Int(lengths[symbol])]
            next[Int(lengths[symbol])] += 1
        }

        return codes
    }
}
