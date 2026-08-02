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
// Blocks are either stored (§3.2.4) or fixed-Huffman (§3.2.6) over LZ77 matches found with a
// hash chain, whichever is smaller for the block at hand. Dynamic blocks are the deliberate
// omission: they need a table built and sent, which is most of the code and nearly all of the
// memory a full encoder wants, and on the targets this module exists to serve — a WASM sandbox,
// a microcontroller — that trade is the right way round. The output is a valid DEFLATE stream
// that any decoder reads; it is simply a few per cent larger than what a dynamic-block encoder
// would emit. Adding them later changes only what this file writes, not what anything else
// here assumes.
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
    /// cursor grows past what a distance can address and past what the open block still needs.
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

    // -- the block being built --------------------------------------------------
    //
    // Symbols are collected rather than written as they are found, because which kind of block
    // to write cannot be known until the block is complete: a stored block costs its bytes plus
    // five, and fixed-Huffman costs whatever its symbols add up to, and for incompressible input
    // the first is smaller. Encoding straight out would commit to that answer before there was
    // anything to base it on — and the wrong answer is not merely larger but *larger than the
    // input*, which no caller sizing a buffer from `compressBound` is expecting.

    /// One entry per symbol: bit 31 clear for a literal in the low byte, bit 31 set for a match
    /// with its length in bits 0...8 and its distance in bits 9...24.
    ///
    /// Packed into a word rather than an enum because there is one of these per literal byte,
    /// and the array is the encoder's largest allocation.
    private var symbols: [UInt32] = []

    /// Where in `pending` the open block's uncompressed bytes start, which is what a stored
    /// block writes out and therefore what cannot be trimmed away while the block is open.
    private var blockStart = 0

    /// What the open block's symbols would cost as fixed Huffman, in bits, accumulated as they
    /// are appended so that closing the block is a comparison rather than a second pass.
    private var blockCostBits = 0

    /// A stored block's length is a sixteen-bit field, so a block that might become one cannot
    /// cover more input than that.
    private static let maxBlockBytes = 65535

    /// A cap on the symbol buffer, so a block of highly compressible input closes on a bound
    /// this module chose rather than on whatever `maxBlockBytes` happens to allow.
    private static let maxBlockSymbols = 16384

    /// Whether the stream's final block has been written into the pending output.
    ///
    /// Not yet the caller-visible "finished": that waits until the pending output has actually
    /// been handed over, because a caller told "finished" stops asking for bytes.
    private var streamEnded = false

    /// Whether the stream has ended *and* every byte of it has been taken. The analogue of
    /// zlib's `Z_STREAM_END`, which likewise never arrives while output is still waiting.
    public var isFinished: Bool {
        self.streamEnded && self.writer.pendingByteCount == 0
    }


    /// How far back a match may point.
    ///
    /// A caller limits this when whatever will decompress the result has less than 32 KiB to
    /// spare. Emitting a distance beyond what the stream declares produces something the
    /// intended decoder cannot read, so this is a limit on the encoder rather than a hint to it.
    private let windowSize: Int

    /// - Parameter windowBits: the base-two logarithm of the window, 9 through 15.
    public init(level: Int32, windowBits: Int32 = 15) {
        self.effort = Effort.forLevel(level)
        self.head = [Int](repeating: -1, count: Self.hashSize)
        self.chain = []
        self.windowSize = 1 << max(9, min(15, Int(windowBits)))
    }

    /// Whether this encoder is ready to be given more input.
    ///
    /// Always true, because ``setInput(_:)`` copies: there is never a buffer part-way through
    /// being taken.
    public var needsInput: Bool {
        true
    }

    /// Hands the encoder its next input, which it copies.
    ///
    /// Copied here rather than remembered and read later, which is what this did once. The
    /// difference matters because a caller has no way to know whether a call that produced no
    /// output also happened to skip taking the input — and a caller that hands over a second
    /// buffer believing the first was taken loses it. Owning the bytes on receipt makes the
    /// question unaskable.
    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }

        self.pending.append(contentsOf: bytes)
        self.chain.append(contentsOf: [Int](repeating: -1, count: bytes.count))
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

        // Everything but the tail is safe to compress now: a match needs `maxMatch` bytes of
        // lookahead to be sure it has found the longest one, so the last stretch waits until
        // either more arrives or the caller says there is no more coming.
        let keepBack = ending == .none ? Self.maxMatch : 0
        self.compressAvailable(keepingBack: keepBack)

        if self.cursor >= self.pending.count {
            switch ending {
            case .none:
                break

            case .flush:
                self.flushBlock(final: false)
                self.writeSyncMarker()

            case .finish:
                if !self.streamEnded {
                    self.flushBlock(final: true)
                    self.streamEnded = true
                }
            }
        }

        return self.drain(into: destination, count: count)
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

        let earliest = max(0, position - self.windowSize)

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
        let limit = self.pending.count

        while self.cursor + keepBack < limit {
            if self.effort.maxChainLength > 0,
               let match = self.longestMatch(at: self.cursor, limit: limit) {
                self.appendMatch(length: match.length, distance: match.distance)

                for offset in 0 ..< match.length {
                    self.insert(at: self.cursor + offset)
                }

                self.cursor += match.length
            } else {
                self.appendLiteral(self.pending[self.cursor])

                if self.effort.maxChainLength > 0 {
                    self.insert(at: self.cursor)
                }

                self.cursor += 1
            }

            if self.blockIsFull {
                self.flushBlock(final: false)
            }
        }

        self.trimWindow()
    }

    private var blockIsFull: Bool {
        self.cursor - self.blockStart >= Self.maxBlockBytes
            || self.symbols.count >= Self.maxBlockSymbols
    }

    /// Drops history no match can reach any more, so `pending` does not grow with the stream.
    private func trimWindow() {
        let keep = self.windowSize
        guard self.cursor > keep * 2 else { return }

        // Never drop what the open block has not been written out of: if it closes as a stored
        // block, those bytes are what it writes.
        let drop = min(self.cursor - keep, self.blockStart)
        guard drop > 0 else { return }

        self.pending.removeFirst(drop)
        self.chain.removeFirst(drop)
        self.cursor -= drop
        self.blockStart -= drop

        for index in 0 ..< self.head.count {
            self.head[index] = self.head[index] >= drop ? self.head[index] - drop : -1
        }

        for index in 0 ..< self.chain.count {
            self.chain[index] = self.chain[index] >= drop ? self.chain[index] - drop : -1
        }
    }

    // -- collecting a block's symbols --------------------------------------------

    private func appendLiteral(_ byte: UInt8) {
        self.symbols.append(UInt32(byte))
        self.blockCostBits += Self.literalOrLengthBits(UInt16(byte))
    }

    private func appendMatch(length: Int, distance: Int) {
        self.symbols.append(
            0x8000_0000 | UInt32(length) | (UInt32(distance) << 9)
        )

        let lengthSymbol = Int(DeflateTables.lengthSymbol[length - Self.minMatch])
        let distanceSymbol = Self.distanceSymbol(for: distance)

        self.blockCostBits +=
            Self.literalOrLengthBits(UInt16(257 + lengthSymbol))
            + DeflateTables.lengthExtraBits[lengthSymbol]
            + 5
            + DeflateTables.distanceExtraBits[distanceSymbol]
    }

    private static func distanceSymbol(for distance: Int) -> Int {
        var symbol = DeflateTables.distanceBase.count - 1

        while DeflateTables.distanceBase[symbol] > distance {
            symbol -= 1
        }

        return symbol
    }

    /// §3.2.6: how many bits the fixed alphabet spends on one literal/length symbol.
    private static func literalOrLengthBits(_ symbol: UInt16) -> Int {
        switch symbol {
        case 0 ... 143: return 8
        case 144 ... 255: return 9
        case 256 ... 279: return 7
        default: return 8
        }
    }

    // -- closing a block ---------------------------------------------------------

    /// Writes the open block out in whichever form is smaller, and starts a new one.
    ///
    /// A block is always written, even with nothing in it: that is how a stream with no input
    /// at all still ends with a final block, and how `.flush` produces something a reader can
    /// act on rather than nothing at all.
    private func flushBlock(final: Bool) {
        let storedLength = self.cursor - self.blockStart

        // Fixed costs three bits of header and seven for end-of-block on top of its symbols.
        // Stored costs three of header, up to seven of padding to reach a byte boundary, and
        // then four bytes of length and complement before the data itself.
        let fixedBits = 3 + self.blockCostBits + 7
        let storedBits = 3 + 7 + 32 + storedLength * 8

        if storedLength <= Self.maxBlockBytes, storedBits < fixedBits {
            self.writeStoredBlock(final: final, length: storedLength)
        } else {
            self.writeFixedBlock(final: final)
        }

        if final {
            // The stream's bits end wherever the last code did, but everything that carries a
            // DEFLATE stream puts a byte-aligned field after it, and a partial byte left in the
            // writer would never reach the output at all.
            self.writer.alignToByte()
        }

        self.symbols.removeAll(keepingCapacity: true)
        self.blockCostBits = 0
        self.blockStart = self.cursor
    }

    /// An empty stored block, which is how a stream reaches a byte boundary mid-flight.
    ///
    /// Padding to a boundary directly would not do: the next block's header has to begin at the
    /// very next bit, so there is nowhere legal to put the padding. An empty stored block has
    /// the alignment built into its own format, and its five bytes — `00 00 00 FF FF` — are
    /// what every other implementation emits for a sync flush, so a reader expecting one finds
    /// exactly that.
    private func writeSyncMarker() {
        self.writer.write(0, bits: 1)
        self.writer.write(0, bits: 2)
        self.writer.alignToByte()
        self.writer.write(0, bits: 16)
        self.writer.write(0xFFFF, bits: 16)
    }

    private func writeStoredBlock(final: Bool, length: Int) {
        // §3.2.4: BTYPE 00, then the rest of the byte discarded, then LEN and its one's
        // complement, then the bytes themselves verbatim.
        self.writer.write(final ? 1 : 0, bits: 1)
        self.writer.write(0, bits: 2)
        self.writer.alignToByte()

        self.writer.write(UInt32(length), bits: 16)
        self.writer.write(UInt32(length ^ 0xFFFF), bits: 16)

        self.pending.withUnsafeBufferPointer { buffer in
            self.writer.append(
                UnsafeBufferPointer(start: buffer.baseAddress! + self.blockStart, count: length)
            )
        }
    }

    private func writeFixedBlock(final: Bool) {
        self.writer.write(final ? 1 : 0, bits: 1)
        self.writer.write(1, bits: 2)

        for symbol in self.symbols {
            guard symbol & 0x8000_0000 != 0 else {
                self.writeLiteralOrLength(UInt16(truncatingIfNeeded: symbol))
                continue
            }

            self.writeMatch(
                length: Int(symbol & 0x1FF),
                distance: Int((symbol >> 9) & 0xFFFF)
            )
        }

        self.writeLiteralOrLength(DeflateTables.endOfBlock)
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
        let lengthSymbol = Int(DeflateTables.lengthSymbol[length - Self.minMatch])

        self.writeLiteralOrLength(UInt16(257 + lengthSymbol))

        let lengthExtra = DeflateTables.lengthExtraBits[lengthSymbol]
        if lengthExtra > 0 {
            self.writer.write(
                UInt32(length - DeflateTables.lengthBase[lengthSymbol]),
                bits: lengthExtra
            )
        }

        let distanceSymbol = Self.distanceSymbol(for: distance)

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
