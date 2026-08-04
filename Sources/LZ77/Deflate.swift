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
// Every block is written as stored (§3.2.4), fixed-Huffman (§3.2.6) or dynamic-Huffman
// (§3.2.7) over LZ77 matches found with a hash chain — whichever of the three is smallest for
// the block at hand, decided by costing all three rather than by guessing from the input.
//
// The three exist because none dominates. Stored wins on data with no structure, where any
// coding costs more than it saves. Dynamic wins on almost everything else, because a table
// fitted to the block pays for itself many times over. Fixed wins in the narrow band between
// them, on blocks too small for a table to be worth sending — which is most of what a caller
// flushing frequently produces.
//
// Matching is the standard hash-chain arrangement: a rolling three-byte hash indexes the most
// recent position with that hash, each of which links to the previous one, so the search walks
// candidates newest-first and stops when it has looked far enough back to be worth it.
// Split the same way as the decoder and for the same measured reason: a mutating access to a
// struct stored in a class is dynamically checked for exclusivity, and the encoder makes one
// per symbol through `self.writer`. In a noncopyable struct the same mutation through
// `inout self` is checked at compile time instead. The class below is a box paying one dynamic
// access per public call.
struct DeflateCore: ~Copyable {
    /// How hard to look for matches, mapped from the level a caller asks for.
    private struct Effort {
        let maxChainLength: Int
        let goodMatch: Int
        let maxLazy: Int

        /// The reference's `good_length` column: while a match at least this long is already
        /// in hand, the search for a better one runs on a quarter of the chain budget —
        /// beating a good match is unlikely, so little is spent trying. Zero means never.
        let quarterAt: Int

        /// The reference's insertion cap for its greedy levels: a match longer than this has
        /// its covered positions left out of the hash table entirely. At levels that take
        /// every match as found, hashing the inside of a long run costs real time and buys
        /// almost nothing — the run's own head is already indexed. The lazy levels index
        /// everything, as the reference does.
        let maxInsert: Int

        /// `maxLazy` of zero means take every match as it is found, without looking a byte
        /// further — which is what the reference does for its fast levels, and what the levels
        /// below four ask for by asking to be fast. Deferring doubles the number of searches,
        /// and on data whose matches cluster around the threshold it can cost a little size as
        /// well: it is a heuristic, not a strict improvement.
        ///
        /// The columns are the reference's own configuration_table, in its terms:
        /// (max_chain, nice_length, max_lazy, good_length) — with `maxInsert` standing in for
        /// what its greedy levels do with max_insert_length.
        static func forLevel(_ level: Int32) -> Effort {
            switch level {
            case ..<1: return Effort(maxChainLength: 0, goodMatch: 0, maxLazy: 0, quarterAt: 0, maxInsert: 0)
            case 1: return Effort(maxChainLength: 4, goodMatch: 8, maxLazy: 0, quarterAt: 0, maxInsert: 4)
            case 2: return Effort(maxChainLength: 8, goodMatch: 16, maxLazy: 0, quarterAt: 0, maxInsert: 5)
            case 3: return Effort(maxChainLength: 32, goodMatch: 32, maxLazy: 0, quarterAt: 0, maxInsert: 6)
            case 4: return Effort(maxChainLength: 16, goodMatch: 16, maxLazy: 4, quarterAt: 4, maxInsert: .max)
            case 5: return Effort(maxChainLength: 32, goodMatch: 32, maxLazy: 16, quarterAt: 8, maxInsert: .max)
            case 6: return Effort(maxChainLength: 128, goodMatch: 128, maxLazy: 16, quarterAt: 8, maxInsert: .max)
            case 7: return Effort(maxChainLength: 256, goodMatch: 128, maxLazy: 32, quarterAt: 8, maxInsert: .max)
            case 8: return Effort(maxChainLength: 1024, goodMatch: 258, maxLazy: 128, quarterAt: 32, maxInsert: .max)
            default: return Effort(maxChainLength: 4096, goodMatch: 258, maxLazy: 258, quarterAt: 32, maxInsert: .max)
            }
        }
    }

    private var effort: Effort

    /// Everything handed in but not yet compressed, plus the window of already-compressed bytes
    /// a match may still reach back into. Trimmed from the front once the history behind the
    /// cursor grows past what a distance can address and past what the open block still needs.
    private var pending: [UInt8] = []
    private var cursor = 0

    /// head[hash] is the most recent position with that hash; chain[position & chainMask] is
    /// the previous one. Positions are indices into `pending`, rebased whenever it is trimmed.
    ///
    /// Raw memory rather than arrays for the same reason as the decoder's window: these are
    /// touched for every input byte, this struct allocates and owns them outright, and an
    /// array's uniqueness and bounds checking buy nothing here but a branch per access.
    ///
    /// `chain` is a fixed ring the size of the largest window rather than an array running
    /// the length of `pending`, and the difference is not memory but locality: a chain walk
    /// hops all over this buffer, and 32K entries stay in cache where a buffer the length of
    /// the input does not. The ring is sound because a slot is overwritten only by a position
    /// exactly `chainSize` later — and by then the position it held is out of any window's
    /// reach, which is the condition under which the walk already refuses to follow it.
    private var head: UnsafeMutablePointer<Int>
    private var chain: UnsafeMutablePointer<Int>

    private static let chainSize = 1 << 15 // the largest windowSize
    private static let chainMask = chainSize - 1

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

    /// A match found at the position before ``cursor`` and not yet committed to.
    ///
    /// This is what "lazy" means: a match is not taken the moment it is found. The byte after it
    /// is examined first, and if a longer match starts there, the byte this one started on is
    /// written as a literal instead. One byte of hindsight, and worth a few per cent — long
    /// matches are what cost the fewest bits per byte covered, and greedily taking a short one
    /// can hide a longer one that began just after it.
    private var deferred: (length: Int, distance: Int)?

    /// The position after the last symbol actually emitted.
    ///
    /// Not the same as ``cursor`` while a match is deferred: the byte it starts on has been read
    /// past but nothing has been written for it yet. Blocks are measured to here rather than to
    /// the cursor, since a stored block writes out exactly the bytes its symbols stand for.
    private var emittedEnd: Int {
        self.deferred == nil ? self.cursor : self.cursor - 1
    }

    /// How often each symbol occurs in the open block, which is what a dynamic block's tables
    /// are fitted to and what all three block types are costed from.
    private var literalFrequencies = [Int](repeating: 0, count: 286)
    private var distanceFrequencies = [Int](repeating: 0, count: 30)

    /// Bits spent on the extra-bits fields of the block's matches. The same for every block
    /// type, since extra bits are written raw whichever coding is chosen.
    private var extraBits = 0

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
    var isFinished: Bool {
        self.streamEnded && self.writer.pendingByteCount == 0
    }


    /// How far back a match may point.
    ///
    /// A caller limits this when whatever will decompress the result has less than 32 KiB to
    /// spare. Emitting a distance beyond what the stream declares produces something the
    /// intended decoder cannot read, so this is a limit on the encoder rather than a hint to it.
    private var windowSize: Int

    /// - Parameter windowBits: the base-two logarithm of the window, 9 through 15.
    init(level: Int32, windowBits: Int32 = 15) {
        self.effort = Effort.forLevel(level)
        self.head = .allocate(capacity: Self.hashSize)
        self.head.initialize(repeating: -1, count: Self.hashSize)
        self.chain = .allocate(capacity: Self.chainSize)
        self.chain.initialize(repeating: -1, count: Self.chainSize)
        self.windowSize = 1 << max(9, min(15, Int(windowBits)))
        self.symbols.reserveCapacity(Self.maxBlockSymbols)
    }

    deinit {
        self.head.deallocate()
        self.chain.deallocate()
    }

    // -- what a caller can change or carry over ------------------------------------

    /// Changes how hard the match search works, from here on.
    ///
    /// Safe mid-stream because a level is not recorded anywhere in the format: it changes what
    /// this encoder chooses, never how a decoder reads the result. Blocks compressed at
    /// different levels sit side by side in one stream quite happily.
    mutating func setLevel(_ level: Int32) {
        self.effort = Effort.forLevel(level)
    }

    /// Sets the match search's knobs directly, which is what `deflateTune` exists for.
    mutating func tune(goodMatch: Int, maxLazy: Int, maxChainLength: Int) {
        self.effort = Effort(
            maxChainLength: max(0, maxChainLength),
            goodMatch: max(0, goodMatch),
            maxLazy: max(0, maxLazy),
            quarterAt: max(0, goodMatch),
            maxInsert: .max
        )
    }

    /// Fills the window with bytes that are not part of the output.
    ///
    /// A preset dictionary: text the decoder is assumed to have already, so matches may point
    /// into it from the very first byte. Nothing here is emitted — the cursor and the block both
    /// start past it — which is exactly what makes it a dictionary rather than a prefix.
    ///
    /// Only the last window's worth can be reached by a distance, so anything before that is
    /// dropped rather than kept and never used.
    mutating func primeWindow(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty, self.pending.isEmpty else { return }

        let start = max(0, bytes.count - self.windowSize)
        let slice = UnsafeBufferPointer(
            start: bytes.baseAddress! + start,
            count: bytes.count - start
        )

        self.pending.append(contentsOf: slice)

        // Hashed so matches can find it, then stepped over: these bytes are context, not input.
        let snapshot = self.pending
        snapshot.withUnsafeBufferPointer { buffer in
            guard let bytes = buffer.baseAddress else { return }

            for position in 0 ..< buffer.count {
                self.insert(bytes, at: position, limit: buffer.count)
            }
        }

        self.cursor = self.pending.count
        self.blockStart = self.cursor
    }

    /// The most recent window's worth of bytes seen, which is what a decoder would need to
    /// continue from here and what `deflateGetDictionary` reports.
    var dictionary: [UInt8] {
        let end = self.emittedEnd
        let start = max(0, end - self.windowSize)

        return Array(self.pending[start ..< end])
    }

    /// Puts `count` bits into the output ahead of the stream.
    ///
    /// Only before anything has been written, because there is nowhere else they could go: the
    /// point is to let a caller prepend framing of its own to a stream this produces.
    mutating func prime(_ value: UInt32, bits count: Int) -> Bool {
        guard self.writer.isEmpty, count >= 0, count <= 32 else { return false }

        self.writer.write(value, bits: count)
        return true
    }

    /// An explicit duplicate, sharing nothing.
    ///
    /// Every field is a value type, so this is a memberwise copy and not a traversal: the point
    /// of saying so is that adding a reference-typed field later would silently make the two
    /// copies share it.
    borrowing func copied() -> DeflateCore {
        var clone = DeflateCore(level: 6, windowBits: 15)

        clone.effort = self.effort
        clone.windowSize = self.windowSize
        clone.pending = self.pending
        clone.cursor = self.cursor

        // The two raw buffers are the fields a memberwise copy would silently share; copying
        // them is most of what this method exists to do.
        clone.head.update(from: self.head, count: Self.hashSize)
        clone.chain.update(from: self.chain, count: Self.chainSize)

        clone.writer = self.writer
        clone.symbols = self.symbols
        clone.blockStart = self.blockStart
        clone.deferred = self.deferred
        clone.literalFrequencies = self.literalFrequencies
        clone.distanceFrequencies = self.distanceFrequencies
        clone.extraBits = self.extraBits
        clone.streamEnded = self.streamEnded

        return clone
    }

    /// Whether this encoder is ready to be given more input.
    ///
    /// Always true, because ``setInput(_:)`` copies: there is never a buffer part-way through
    /// being taken.
    var needsInput: Bool {
        true
    }

    /// Hands the encoder its next input, which it copies.
    ///
    /// Copied here rather than remembered and read later, which is what this did once. The
    /// difference matters because a caller has no way to know whether a call that produced no
    /// output also happened to skip taking the input — and a caller that hands over a second
    /// buffer believing the first was taken loses it. Owning the bytes on receipt makes the
    /// question unaskable.
    mutating func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }

        self.pending.append(contentsOf: bytes)
    }

    typealias Ending = Deflate.Ending

    /// Compresses into `destination`, returning how many bytes were produced.
    ///
    /// A result smaller than `count` with no ending asked for means the compressor is holding
    /// what it has been given, which is what a compressor does until it has enough context to
    /// find repetitions worth naming.
    mutating func deflate(
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
                self.resolveDeferred()
                self.flushBlock(final: false)
                self.writeSyncMarker()

            case .fullFlush:
                self.resolveDeferred()
                self.flushBlock(final: false)
                self.writeSyncMarker()
                self.resetWindow()

            case .finish:
                if !self.streamEnded {
                    // Whatever is still being held has to be written before the stream can end,
                    // or the bytes it stands for are simply lost.
                    self.resolveDeferred()
                    self.flushBlock(final: true)
                    self.streamEnded = true
                }
            }
        }

        return self.drain(into: destination, count: count)
    }

    private mutating func drain(into destination: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
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

    private func hash(_ bytes: UnsafePointer<UInt8>, at position: Int) -> Int {
        let a = Int(bytes[position])
        let b = Int(bytes[position + 1])
        let c = Int(bytes[position + 2])

        // A multiplicative hash over three bytes, masked to the table size. The constant is odd
        // and spread across its bits, which is all this needs to scatter well.
        return ((a &<< 10) ^ (b &<< 5) ^ c) &* 0x9E37 & (Self.hashSize - 1)
    }

    private mutating func insert(_ bytes: UnsafePointer<UInt8>, at position: Int, limit: Int) {
        guard position + Self.minMatch <= limit else { return }

        let key = self.hash(bytes, at: position)
        self.chain[position & Self.chainMask] = self.head[key]
        self.head[key] = position
    }

    /// The longest match at `position`, or nil when nothing reaches the minimum length.
    ///
    /// The chain walk runs over an unsafe view of `pending` and compares eight bytes per step,
    /// finding the first difference with a XOR and a trailing-zero count. Everything about
    /// *which* match wins is unchanged — same walk order, same tie-breaking, same caps — so
    /// the emitted stream is byte-for-byte what the byte-at-a-time loop produced.
    private func longestMatch(
        _ bytes: UnsafePointer<UInt8>,
        at position: Int,
        limit: Int,
        holding: Int = 0
    ) -> (length: Int, distance: Int)? {
        guard position + Self.minMatch <= limit else { return nil }

        let maxLength = min(Self.maxMatch, limit - position)
        guard maxLength >= Self.minMatch else { return nil }

        let here = bytes + position

        var candidate = self.head[self.hash(bytes, at: position)]
        var chainLeft = self.effort.maxChainLength

        // A quarter of the budget while a good match is already held: beating it is unlikely,
        // so little is spent trying. The reference's `good_length`, doing exactly this.
        if self.effort.quarterAt > 0, holding >= self.effort.quarterAt {
            chainLeft >>= 2
        }
        var best = 0
        var bestDistance = 0

        let earliest = max(0, position - self.windowSize)

        while candidate >= earliest, chainLeft > 0 {
            chainLeft -= 1

            let match = bytes + candidate

            // A candidate that cannot *beat* the current best differs from it at or
            // before the byte where the best ends, and checking that one byte first
            // skips the losers without measuring them. Only candidates that survive
            // get the full comparison, so the winner is the same one as ever.
            if best > 0, match[best] != here[best] {
                let next = self.chain[candidate & Self.chainMask]
                if next >= candidate { break }
                candidate = next
                continue
            }

            var length = 0
            var found = false

            while length + 8 <= maxLength {
                let a = UnsafeRawPointer(here + length).loadUnaligned(as: UInt64.self)
                let b = UnsafeRawPointer(match + length).loadUnaligned(as: UInt64.self)
                let difference = UInt64(littleEndian: a) ^ UInt64(littleEndian: b)

                if difference != 0 {
                    length += difference.trailingZeroBitCount >> 3
                    found = true
                    break
                }

                length += 8
            }

            if !found {
                while length < maxLength, match[length] == here[length] {
                    length += 1
                }
            }

            if length > best {
                best = length
                bestDistance = position - candidate

                if best >= self.effort.goodMatch { break }
                if best >= maxLength { break } // nothing left to beat
            }

            let next = self.chain[candidate & Self.chainMask]
            if next >= candidate { break }
            candidate = next
        }

        guard best >= Self.minMatch else { return nil }

        return (best, bestDistance)
    }

    private mutating func compressAvailable(keepingBack keepBack: Int) {
        let limit = self.pending.count
        guard self.cursor + keepBack < limit else {
            self.trimWindow()
            return
        }

        // The loops run over an unsafe view of a *local* handle on `pending`, which is what
        // makes the interleaved mutation legal: the borrow is of the local, and nothing in
        // here grows or shrinks the shared storage while the pointer is live.
        let snapshot = self.pending

        snapshot.withUnsafeBufferPointer { buffer in
            guard let bytes = buffer.baseAddress else { return }

            // Level zero asks for no match search at all, so there is nothing to be lazy about.
            guard self.effort.maxChainLength > 0 else {
                while self.cursor + keepBack < limit {
                    self.appendLiteral(bytes[self.cursor])
                    self.cursor += 1

                    if self.blockIsFull { self.flushBlock(final: false) }
                }
                return
            }

            while self.cursor + keepBack < limit {
                let heldLength = self.deferred?.length ?? 0

                // The reference's economy, adopted whole: while a match at least `maxLazy`
                // long is already in hand, no better one is even looked for — the search
                // would usually lose, and it is the single most expensive thing here.
                let current: (length: Int, distance: Int)? =
                    heldLength > 0 && heldLength >= self.effort.maxLazy
                    ? nil
                    : self.longestMatch(bytes, at: self.cursor, limit: limit, holding: heldLength)

                self.insert(bytes, at: self.cursor, limit: limit)

                if let held = self.deferred {
                    if let current, current.length > held.length {
                        // Starting a byte later pays better, so the byte the held match began
                        // on becomes a literal and the new match is held in its place.
                        self.appendLiteral(bytes[self.cursor - 1])
                        self.deferred = current
                        self.cursor += 1
                    } else {
                        self.take(held, startingAt: self.cursor - 1, bytes: bytes, limit: limit)
                    }
                } else if let current {
                    // A match already long enough is taken without looking further: past the
                    // level's threshold the search costs more than the byte it might save.
                    if current.length < self.effort.maxLazy {
                        self.deferred = current
                        self.cursor += 1
                    } else {
                        self.take(current, startingAt: self.cursor, bytes: bytes, limit: limit)
                    }
                } else {
                    self.appendLiteral(bytes[self.cursor])
                    self.cursor += 1
                }

                if self.blockIsFull { self.flushBlock(final: false) }
            }
        }

        self.trimWindow()
    }

    /// Commits to a match, and puts the positions it covers into the hash chain.
    private mutating func take(
        _ match: (length: Int, distance: Int),
        startingAt start: Int,
        bytes: UnsafePointer<UInt8>,
        limit: Int
    ) {
        self.appendMatch(length: match.length, distance: match.distance)

        // `start` and `cursor` are already in the chain — every position passes through the top
        // of the loop above — so only what the match covers beyond them is left to insert. At
        // the greedy levels a long match's insides are not indexed at all, as the reference
        // has it: the run's head already is, and hashing the rest costs more than it finds.
        let end = start + match.length

        if end > self.cursor + 1, match.length <= self.effort.maxInsert {
            for position in (self.cursor + 1) ..< end {
                self.insert(bytes, at: position, limit: limit)
            }
        }

        self.cursor = end
        self.deferred = nil
    }

    /// Commits to whatever is being held, so that a block can close on a whole number of
    /// symbols. Nothing may be written out while a match is still undecided.
    private mutating func resolveDeferred() {
        guard let held = self.deferred else { return }

        let snapshot = self.pending
        snapshot.withUnsafeBufferPointer { buffer in
            guard let bytes = buffer.baseAddress else { return }
            self.take(held, startingAt: self.cursor - 1, bytes: bytes, limit: buffer.count)
        }
    }

    private var blockIsFull: Bool {
        self.emittedEnd - self.blockStart >= Self.maxBlockBytes
            || self.symbols.count >= Self.maxBlockSymbols
    }

    /// Drops history no match can reach any more, so `pending` does not grow with the stream.
    private mutating func trimWindow() {
        let keep = self.windowSize
        guard self.cursor > keep * 2 else { return }

        // Never drop what the open block has not been written out of: if it closes as a stored
        // block, those bytes are what it writes. And only whole multiples of the chain ring:
        // a position's slot is `position & chainMask`, so a rebase by anything else would move
        // every entry to a slot nothing will ever read it from. The reference slides its
        // window in the same fixed steps for the same reason.
        let drop = min(self.cursor - keep, self.blockStart) & ~Self.chainMask
        guard drop > 0 else { return }

        self.pending.removeFirst(drop)
        self.cursor -= drop
        self.blockStart -= drop

        for index in 0 ..< Self.hashSize {
            self.head[index] = self.head[index] >= drop ? self.head[index] - drop : -1
        }

        // The ring's slots stay where they are — `(position - drop) & chainMask` is not
        // `position & chainMask`, but the slot for a position is only ever *read* through the
        // same masked arithmetic it was written through, so only the values need rebasing.
        for index in 0 ..< Self.chainSize {
            self.chain[index] = self.chain[index] >= drop ? self.chain[index] - drop : -1
        }
    }

    // -- collecting a block's symbols --------------------------------------------

    private mutating func appendLiteral(_ byte: UInt8) {
        self.symbols.append(UInt32(byte))
        self.literalFrequencies[Int(byte)] += 1
    }

    private mutating func appendMatch(length: Int, distance: Int) {
        self.symbols.append(
            0x8000_0000 | UInt32(length) | (UInt32(distance) << 9)
        )

        let lengthSymbol = Int(DeflateTables.lengthSymbol[length - Self.minMatch])
        let distanceSymbol = Self.distanceSymbol(for: distance)

        self.literalFrequencies[257 + lengthSymbol] += 1
        self.distanceFrequencies[distanceSymbol] += 1

        self.extraBits +=
            DeflateTables.lengthExtraBits[lengthSymbol]
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
    private mutating func flushBlock(final: Bool) {
        let blockEnd = self.emittedEnd
        let storedLength = blockEnd - self.blockStart

        // Every block ends with one, and it has to be counted before the tables are fitted or
        // the symbol that always occurs would be the one left out of them.
        self.literalFrequencies[Int(DeflateTables.endOfBlock)] += 1

        // Three bits of header, then what each coding spends. Stored also pays up to seven bits
        // of padding to reach a byte boundary and four bytes of length and complement.
        let fixedBits = 3 + self.fixedCostBits()
        let storedBits = 3 + 7 + 32 + storedLength * 8

        let dynamic = DynamicBlock(
            literalFrequencies: self.literalFrequencies,
            distanceFrequencies: self.distanceFrequencies,
            extraBits: self.extraBits
        )

        if storedLength <= Self.maxBlockBytes, storedBits <= min(fixedBits, dynamic.totalBits) {
            self.writeStoredBlock(final: final, length: storedLength)
        } else if dynamic.totalBits < fixedBits {
            self.writeDynamicBlock(final: final, table: dynamic)
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
        self.extraBits = 0
        self.blockStart = blockEnd

        for index in self.literalFrequencies.indices { self.literalFrequencies[index] = 0 }
        for index in self.distanceFrequencies.indices { self.distanceFrequencies[index] = 0 }
    }

    /// What this block's symbols would cost under §3.2.6's fixed alphabet.
    private func fixedCostBits() -> Int {
        var bits = self.extraBits

        for symbol in self.literalFrequencies.indices where self.literalFrequencies[symbol] > 0 {
            bits += self.literalFrequencies[symbol] * Self.literalOrLengthBits(UInt16(symbol))
        }

        for symbol in self.distanceFrequencies.indices {
            // Every distance code is five bits in the fixed alphabet.
            bits += self.distanceFrequencies[symbol] * 5
        }

        return bits
    }

    /// Empties the window, so no later match reaches anything earlier.
    ///
    /// At the point this is called everything pending has been consumed and every block
    /// flushed, so what is dropped is pure history.
    private mutating func resetWindow() {
        self.pending.removeAll(keepingCapacity: true)
        self.cursor = 0
        self.blockStart = 0

        // `chain` needs no clearing: its meaningful length is `pending.count`, now zero.
        for index in 0 ..< Self.hashSize {
            self.head[index] = -1
        }
    }

    /// An empty stored block, which is how a stream reaches a byte boundary mid-flight.
    ///
    /// Padding to a boundary directly would not do: the next block's header has to begin at the
    /// very next bit, so there is nowhere legal to put the padding. An empty stored block has
    /// the alignment built into its own format, and its five bytes — `00 00 00 FF FF` — are
    /// what every other implementation emits for a sync flush, so a reader expecting one finds
    /// exactly that.
    private mutating func writeSyncMarker() {
        self.writer.write(0, bits: 1)
        self.writer.write(0, bits: 2)
        self.writer.alignToByte()
        self.writer.write(0, bits: 16)
        self.writer.write(0xFFFF, bits: 16)
    }

    private mutating func writeStoredBlock(final: Bool, length: Int) {
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

    private mutating func writeFixedBlock(final: Bool) {
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

    private mutating func writeDynamicBlock(final: Bool, table: DynamicBlock) {
        self.writer.write(final ? 1 : 0, bits: 1)
        self.writer.write(2, bits: 2)

        table.writeTable(to: &self.writer)

        for symbol in self.symbols {
            guard symbol & 0x8000_0000 != 0 else {
                let literal = Int(symbol & 0xFF)
                self.writer.writeCode(
                    table.literalCodes[literal],
                    bits: Int(table.literalLengths[literal])
                )
                continue
            }

            let length = Int(symbol & 0x1FF)
            let distance = Int((symbol >> 9) & 0xFFFF)

            let lengthSymbol = Int(DeflateTables.lengthSymbol[length - Self.minMatch])
            self.writer.writeCode(
                table.literalCodes[257 + lengthSymbol],
                bits: Int(table.literalLengths[257 + lengthSymbol])
            )

            let lengthExtra = DeflateTables.lengthExtraBits[lengthSymbol]
            if lengthExtra > 0 {
                self.writer.write(
                    UInt32(length - DeflateTables.lengthBase[lengthSymbol]),
                    bits: lengthExtra
                )
            }

            let distanceSymbol = Self.distanceSymbol(for: distance)
            self.writer.writeCode(
                table.distanceCodes[distanceSymbol],
                bits: Int(table.distanceLengths[distanceSymbol])
            )

            let distanceExtra = DeflateTables.distanceExtraBits[distanceSymbol]
            if distanceExtra > 0 {
                self.writer.write(
                    UInt32(distance - DeflateTables.distanceBase[distanceSymbol]),
                    bits: distanceExtra
                )
            }
        }

        let endOfBlock = Int(DeflateTables.endOfBlock)
        self.writer.writeCode(
            table.literalCodes[endOfBlock],
            bits: Int(table.literalLengths[endOfBlock])
        )
    }

    // -- fixed-Huffman symbol emission ------------------------------------------

    /// §3.2.6's fixed literal/length code: four ranges, each a contiguous run of codes at one of
    /// three lengths.
    private mutating func writeLiteralOrLength(_ symbol: UInt16) {
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

    private mutating func writeMatch(length: Int, distance: Int) {
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


/// The public face: a reference type over ``DeflateCore``, for the same reasons and at the
/// same cost as ``Inflate``'s box.
public final class Deflate {
    public enum Ending {
        case none
        case flush
        /// A flush that also empties the window, so nothing after it refers to anything before
        /// it. That independence is the point: a reader that lost its place — or never had it,
        /// having joined mid-stream — can start at the marker and decode everything after.
        case fullFlush
        case finish
    }

    var core: DeflateCore

    public init(level: Int32, windowBits: Int32 = 15) {
        self.core = DeflateCore(level: level, windowBits: windowBits)
    }

    public var needsInput: Bool { self.core.needsInput }
    public var isFinished: Bool { self.core.isFinished }
    public var dictionary: [UInt8] { self.core.dictionary }

    public func setLevel(_ level: Int32) { self.core.setLevel(level) }

    public func tune(goodMatch: Int, maxLazy: Int, maxChainLength: Int) {
        self.core.tune(goodMatch: goodMatch, maxLazy: maxLazy, maxChainLength: maxChainLength)
    }

    public func primeWindow(_ bytes: UnsafeBufferPointer<UInt8>) { self.core.primeWindow(bytes) }
    public func prime(_ value: UInt32, bits count: Int) -> Bool { self.core.prime(value, bits: count) }
    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) { self.core.setInput(bytes) }

    public func deflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int,
        ending: Ending = .none
    ) throws(DeflateError) -> Int {
        try self.core.deflate(into: destination, count: count, ending: ending)
    }

    /// An independent copy, sharing nothing.
    public func copy() -> Deflate {
        let clone = Deflate(level: 6, windowBits: 15)
        clone.core = self.core.copied()
        return clone
    }
}
