// Deflate.swift - compressing to a raw DEFLATE stream without a C library underneath
//
// The counterpart to Inflate, and the same push-in/pull-out shape: bytes go in as the caller
// produces them, compressed bytes come out whenever there is room, and neither side dictates
// the other's block size.
//
// What this writes is RFC 1951 and nothing else — no zlib header, no Adler-32, no gzip
// member. A stream needing one of those wrappers is this stream with framing around it, and
// framing is the wrapping module's business; see the `Zlib` module for the RFC 1950 case.
//
// What this produces is fixed-Huffman blocks (RFC 1951 §3.2.6) over LZ77 matches found with a
// hash chain. That is a deliberate stopping point rather than a stub: fixed blocks need no
// table sent and no tree built, which is most of the code and nearly all of the memory a
// dynamic-block encoder wants, and on the targets this module exists to serve — a WASM sandbox
// or a microcontroller with tens of kilobytes to spare — that trade is the right way round. The
// output is a valid zlib stream that any decoder reads; it is simply a few per cent larger than
// what zlib's dynamic blocks would emit at the same effort setting. Adding dynamic blocks later
// changes only what this file emits, not what anything else here assumes.
//
// Matching is the standard hash-chain arrangement: a rolling three-byte hash indexes the most
// recent position with that hash, each of which links to the previous one, so the search walks
// candidates newest-first and stops when it has looked far enough back to be worth it.
public final class Deflate {
    /// How hard to look for matches, mapped from the level a caller asks for.
    private struct Effort {
        let maxChainLength: Int
        let goodMatch: Int
        let maxLazy: Int

        static func forLevel(_ level: Int32) -> Effort {
            switch level {
            case ..<1: return Effort(maxChainLength: 0, goodMatch: 0, maxLazy: 0)
            case 1: return Effort(maxChainLength: 4, goodMatch: 8, maxLazy: 4)
            case 2: return Effort(maxChainLength: 8, goodMatch: 16, maxLazy: 5)
            case 3: return Effort(maxChainLength: 32, goodMatch: 32, maxLazy: 6)
            case 4: return Effort(maxChainLength: 16, goodMatch: 16, maxLazy: 4)
            case 5: return Effort(maxChainLength: 32, goodMatch: 32, maxLazy: 8)
            case 6: return Effort(maxChainLength: 128, goodMatch: 128, maxLazy: 16)
            case 7: return Effort(maxChainLength: 256, goodMatch: 128, maxLazy: 32)
            case 8: return Effort(maxChainLength: 1024, goodMatch: 258, maxLazy: 128)
            default: return Effort(maxChainLength: 4096, goodMatch: 258, maxLazy: 258)
            }
        }
    }

    private let effort: Effort

    /// Everything handed in but not yet compressed, plus the window of already-compressed bytes
    /// a match may still reach back into. Trimmed from the front once the history behind the
    /// cursor grows past what a distance can address.
    private var pending: [UInt8] = []
    private var cursor = 0

    /// head[hash] is the most recent position with that hash; chain[position] is the previous
    /// one. Positions are indices into `pending`, rebased whenever it is trimmed.
    private var head: [Int]
    private var chain: [Int]

    private static let hashBits = 15
    private static let hashSize = 1 << hashBits
    private static let minMatch = 3
    private static let maxMatch = 258

    private var writer = BitWriter()

    private var startedBlock = false

    /// Whether the stream's last block and checksum have been written into the pending output.
    ///
    /// Not yet the caller-visible "finished": that waits until the pending output has actually
    /// been handed over, because a caller told "finished" stops asking for bytes.
    private var streamEnded = false

    /// Whether the stream has ended *and* every byte of it has been taken. The analogue of
    /// zlib's `Z_STREAM_END`, which likewise never arrives while output is still waiting.
    public var isFinished: Bool {
        self.streamEnded && self.writer.pendingByteCount == 0
    }

    private var input: UnsafeBufferPointer<UInt8> = UnsafeBufferPointer(start: nil, count: 0)
    private var inputOffset = 0

    public init(level: Int32) {
        self.effort = Effort.forLevel(level)
        self.head = [Int](repeating: -1, count: Self.hashSize)
        self.chain = []
    }

    public var needsInput: Bool {
        self.inputOffset >= self.input.count
    }

    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.input = bytes
        self.inputOffset = 0
    }

    public enum Ending {
        case none
        case flush
        case finish
    }

    /// Compresses into `destination`, returning how many bytes were produced.
    ///
    /// A result smaller than `count` with no ending asked for means the compressor is holding
    /// what it has been given, which is what a compressor does until it has enough context to
    /// find repetitions worth naming.
    public func deflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int,
        ending: Ending = .none
    ) throws(DeflateError) -> Int {
        guard count > 0 else { return 0 }

        self.takeInput()

        // Everything but the tail is safe to compress now: a match needs `maxMatch` bytes of
        // lookahead to be sure it has found the longest one, so the last stretch waits until
        // either more arrives or the caller says there is no more coming.
        let keepBack = ending == .none ? Self.maxMatch : 0
        self.compressAvailable(keepingBack: keepBack)

        if ending == .finish, !self.streamEnded, self.cursor >= self.pending.count {
            self.finishStream()
        }

        return self.drain(into: destination, count: count)
    }

    private func takeInput() {
        guard self.inputOffset < self.input.count else { return }

        let slice = UnsafeBufferPointer(
            start: self.input.baseAddress! + self.inputOffset,
            count: self.input.count - self.inputOffset
        )

        self.pending.append(contentsOf: slice)
        self.chain.append(contentsOf: [Int](repeating: -1, count: slice.count))
        self.inputOffset = self.input.count
    }

    private func startBlockIfNeeded() {
        guard !self.startedBlock else { return }

        // BFINAL 0, BTYPE 01: not the last block, fixed Huffman codes. The stream is ended by
        // an empty final block instead, so that finishing never depends on knowing in advance
        // which block will turn out to be last.
        self.writer.write(0, bits: 1)
        self.writer.write(1, bits: 2)
        self.startedBlock = true
    }

    private func endBlockIfStarted() {
        guard self.startedBlock else { return }

        self.writeLiteralOrLength(DeflateTables.endOfBlock)
        self.startedBlock = false
    }

    private func finishStream() {
        self.endBlockIfStarted()

        // An empty final fixed block: BFINAL 1, BTYPE 01, then end-of-block immediately.
        self.writer.write(1, bits: 1)
        self.writer.write(1, bits: 2)
        self.writeLiteralOrLength(DeflateTables.endOfBlock)

        // Pad to a byte boundary. RFC 1951 does not require it of DEFLATE data on its own, but
        // every wrapper that carries this stream puts a byte-aligned field after it, and a
        // decoder aligning to find that field expects the padding to already be here.
        self.writer.alignToByte()

        self.streamEnded = true
    }

    private func drain(into destination: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        let available = min(count, self.writer.pendingByteCount)

        guard available > 0 else { return 0 }

        let taken = self.writer.takeOutput()

        taken.withUnsafeBufferPointer { buffer in
            destination.update(from: buffer.baseAddress!, count: available)
        }

        if taken.count > available {
            // More was ready than fit: hand back what did not, ahead of anything written next.
            self.writer.putBack(Array(taken[available...]))
        }

        return available
    }

    // -- matching --------------------------------------------------------------

    private func hash(at position: Int) -> Int {
        let a = Int(self.pending[position])
        let b = Int(self.pending[position + 1])
        let c = Int(self.pending[position + 2])

        // A multiplicative hash over three bytes, masked to the table size. The constant is odd
        // and spread across its bits, which is all this needs to scatter well.
        return ((a &<< 10) ^ (b &<< 5) ^ c) &* 0x9E37 & (Self.hashSize - 1)
    }

    private func insert(at position: Int) {
        guard position + Self.minMatch <= self.pending.count else { return }

        let key = self.hash(at: position)
        self.chain[position] = self.head[key]
        self.head[key] = position
    }

    /// The longest match at `position`, or nil when nothing reaches the minimum length.
    private func longestMatch(at position: Int, limit: Int) -> (length: Int, distance: Int)? {
        guard position + Self.minMatch <= limit else { return nil }

        let maxLength = min(Self.maxMatch, limit - position)
        guard maxLength >= Self.minMatch else { return nil }

        var candidate = self.head[self.hash(at: position)]
        var chainLeft = self.effort.maxChainLength
        var best = 0
        var bestDistance = 0

        let earliest = max(0, position - DeflateTables.windowSize)

        while candidate >= earliest, chainLeft > 0 {
            chainLeft -= 1

            var length = 0

            while length < maxLength,
                  self.pending[candidate + length] == self.pending[position + length] {
                length += 1
            }

            if length > best {
                best = length
                bestDistance = position - candidate

                if best >= self.effort.goodMatch { break }
            }

            let next = self.chain[candidate]
            if next >= candidate { break }
            candidate = next
        }

        guard best >= Self.minMatch else { return nil }

        return (best, bestDistance)
    }

    private func compressAvailable(keepingBack keepBack: Int) {
        guard self.effort.maxChainLength > 0 else {
            self.emitLiteralsOnly(keepingBack: keepBack)
            return
        }

        let limit = self.pending.count

        while self.cursor + keepBack < limit {
            self.startBlockIfNeeded()

            if let match = self.longestMatch(at: self.cursor, limit: limit),
               match.length >= Self.minMatch {
                self.writeMatch(length: match.length, distance: match.distance)

                for offset in 0 ..< match.length {
                    self.insert(at: self.cursor + offset)
                }

                self.cursor += match.length
            } else {
                self.writeLiteralOrLength(UInt16(self.pending[self.cursor]))
                self.insert(at: self.cursor)
                self.cursor += 1
            }
        }

        self.trimWindow()
    }

    private func emitLiteralsOnly(keepingBack keepBack: Int) {
        let limit = self.pending.count

        while self.cursor + keepBack < limit {
            self.startBlockIfNeeded()
            self.writeLiteralOrLength(UInt16(self.pending[self.cursor]))
            self.cursor += 1
        }

        self.trimWindow()
    }

    /// Drops history no match can reach any more, so `pending` does not grow with the stream.
    private func trimWindow() {
        let keep = DeflateTables.windowSize
        guard self.cursor > keep * 2 else { return }

        let drop = self.cursor - keep
        self.pending.removeFirst(drop)
        self.chain.removeFirst(drop)
        self.cursor -= drop

        for index in 0 ..< self.head.count {
            self.head[index] = self.head[index] >= drop ? self.head[index] - drop : -1
        }

        for index in 0 ..< self.chain.count {
            self.chain[index] = self.chain[index] >= drop ? self.chain[index] - drop : -1
        }
    }

    // -- fixed-Huffman symbol emission ------------------------------------------

    /// §3.2.6's fixed literal/length code: four ranges, each a contiguous run of codes at one of
    /// three lengths.
    private func writeLiteralOrLength(_ symbol: UInt16) {
        switch symbol {
        case 0 ... 143:
            self.writer.writeCode(UInt32(symbol) + 0b0011_0000, bits: 8)
        case 144 ... 255:
            self.writer.writeCode(UInt32(symbol) - 144 + 0b1_1001_0000, bits: 9)
        case 256 ... 279:
            self.writer.writeCode(UInt32(symbol) - 256, bits: 7)
        default:
            self.writer.writeCode(UInt32(symbol) - 280 + 0b1100_0000, bits: 8)
        }
    }

    private func writeMatch(length: Int, distance: Int) {
        var lengthSymbol = 0

        for index in stride(from: DeflateTables.lengthBase.count - 1, through: 0, by: -1)
        where DeflateTables.lengthBase[index] <= length {
            lengthSymbol = index
            break
        }

        self.writeLiteralOrLength(UInt16(257 + lengthSymbol))

        let lengthExtra = DeflateTables.lengthExtraBits[lengthSymbol]
        if lengthExtra > 0 {
            self.writer.write(
                UInt32(length - DeflateTables.lengthBase[lengthSymbol]),
                bits: lengthExtra
            )
        }

        var distanceSymbol = 0

        for index in stride(from: DeflateTables.distanceBase.count - 1, through: 0, by: -1)
        where DeflateTables.distanceBase[index] <= distance {
            distanceSymbol = index
            break
        }

        // Distance codes are five bits each in the fixed alphabet, written most significant bit
        // first like any other code.
        self.writer.writeCode(UInt32(distanceSymbol), bits: 5)

        let distanceExtra = DeflateTables.distanceExtraBits[distanceSymbol]
        if distanceExtra > 0 {
            self.writer.write(
                UInt32(distance - DeflateTables.distanceBase[distanceSymbol]),
                bits: distanceExtra
            )
        }
    }
}
