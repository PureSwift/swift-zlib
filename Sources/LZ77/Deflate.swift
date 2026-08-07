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
    /// Half-width entries on purpose: positions stay far below 2^31 (the window is trimmed in
    /// step with the cursor), and the two tables together are what a chain walk actually
    /// touches — at half the width, twice as much of them stays in cache.
    private var head: UnsafeMutablePointer<Int32>
    private var chain: UnsafeMutablePointer<Int32>

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
    /// with its length in bits 0...8, its distance in bits 9...24, and the distance's alphabet
    /// symbol in bits 25...29 — carried along so the write loop reads it instead of rederiving.
    ///
    /// Packed into a word rather than an enum because there is one of these per literal byte,
    /// and raw fixed-capacity memory rather than an array because one is appended per literal
    /// byte too: the capacity is `maxBlockSymbols` by construction — `blockIsFull` closes the
    /// block before another append — so the append is a store and an increment, nothing else.
    private var symbols: UnsafeMutablePointer<UInt32>
    private var symbolCount = 0

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
    ///
    /// Raw memory like `symbols` and for the same reason: one of these counters moves per
    /// symbol collected, and an array would re-prove its storage unshared on every bump.
    private var literalFrequencies: UnsafeMutablePointer<Int>
    private var distanceFrequencies: UnsafeMutablePointer<Int>

    private static let literalSymbolCount = 286
    private static let distanceSymbolCount = 30

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

    /// How hard the stream has been flushed since input last arrived: nothing, a sync flush,
    /// or a full flush.  What makes a repeated flush a no-op rather than a stutter of empty
    /// blocks — see the deflate loop.
    private var flushRankSinceInput = 0

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
        self.symbols = .allocate(capacity: Self.maxBlockSymbols + 8)
        self.literalFrequencies = .allocate(capacity: Self.literalSymbolCount)
        self.literalFrequencies.initialize(repeating: 0, count: Self.literalSymbolCount)
        self.distanceFrequencies = .allocate(capacity: Self.distanceSymbolCount)
        self.distanceFrequencies.initialize(repeating: 0, count: Self.distanceSymbolCount)
        self.windowSize = 1 << max(9, min(15, Int(windowBits)))
    }

    deinit {
        self.head.deallocate()
        self.chain.deallocate()
        self.symbols.deallocate()
        self.literalFrequencies.deallocate()
        self.distanceFrequencies.deallocate()
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

        clone.writer = self.writer.copied()
        clone.symbols.update(from: self.symbols, count: self.symbolCount)
        clone.symbolCount = self.symbolCount
        clone.blockStart = self.blockStart
        clone.deferred = self.deferred
        clone.literalFrequencies.update(from: self.literalFrequencies, count: Self.literalSymbolCount)
        clone.distanceFrequencies.update(from: self.distanceFrequencies, count: Self.distanceSymbolCount)
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
        self.flushRankSinceInput = 0
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
                // Once for what has arrived, not once per call: a flush with nothing new since
                // the last one is a no-op, which is the contract's own answer — zlib produces
                // no bytes for it, and callers are written against that.  Each marker says
                // "everything so far is delivered", and saying it twice would write empty
                // blocks a decoder has to skip for as long as the caller keeps asking.
                guard self.flushRankSinceInput < 1 else { break }

                self.resolveDeferred()
                self.flushBlock(final: false)
                self.writeSyncMarker()
                self.flushRankSinceInput = 1

            case .fullFlush:
                // A full flush outranks a plain one — it also forgets the window — so it still
                // runs after one, the same ordering zlib's own progress rule encodes.
                guard self.flushRankSinceInput < 2 else { break }

                self.resolveDeferred()
                self.flushBlock(final: false)
                self.writeSyncMarker()
                self.resetWindow()
                self.flushRankSinceInput = 2

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
        self.writer.drain(into: destination, limit: count)
    }

    // -- matching --------------------------------------------------------------

    private static func hash(_ bytes: UnsafePointer<UInt8>, at position: Int) -> Int {
        let a = Int(bytes[position])
        let b = Int(bytes[position + 1])
        let c = Int(bytes[position + 2])

        // The reference's own hash, unrolled: `h = (h << 5) ^ byte` three times over, masked
        // to the table size. It once carried a multiplicative mix on top, but the mix bought
        // nothing the mask did not already keep — measured on text, records and random alike —
        // and cost a multiply on every byte of input.
        return ((a &<< 10) ^ (b &<< 5) ^ c) & (Self.hashSize - 1)
    }

    private mutating func insert(_ bytes: UnsafePointer<UInt8>, at position: Int, limit: Int) {
        guard position + Self.minMatch <= limit else { return }

        let key = Self.hash(bytes, at: position)
        self.chain[position & Self.chainMask] = self.head[key]
        self.head[key] = Int32(truncatingIfNeeded: position)
    }

    /// The longest match at `position`, or nil when nothing reaches the minimum length.
    ///
    /// The chain walk runs over an unsafe view of `pending` and compares eight bytes per step,
    /// finding the first difference with a XOR and a trailing-zero count. Everything about
    /// *which* match wins is unchanged — same walk order, same tie-breaking, same caps — so
    /// the emitted stream is byte-for-byte what the byte-at-a-time loop produced.
    private static func longestMatch(
        _ bytes: UnsafePointer<UInt8>,
        at position: Int,
        limit: Int,
        holding: Int,
        from first: Int,
        chain: UnsafePointer<Int32>,
        effort: Effort,
        windowSize: Int
    ) -> (length: Int, distance: Int)? {
        guard position + Self.minMatch <= limit else { return nil }

        let maxLength = min(Self.maxMatch, limit - position)
        guard maxLength >= Self.minMatch else { return nil }

        let here = bytes + position

        var candidate = first
        var chainLeft = effort.maxChainLength

        // A quarter of the budget while a good match is already held: beating it is unlikely,
        // so little is spent trying. The reference's `good_length`, doing exactly this.
        if effort.quarterAt > 0, holding >= effort.quarterAt {
            chainLeft >>= 2
        }
        var best = 0
        var bestDistance = 0

        // The two bytes over the current best's last byte, reloaded only when the best
        // improves: a candidate that cannot *beat* the best must differ from it at or before
        // the byte where the best ends, so comparing this pair first skips the losers
        // without measuring them — one sixteen-bit load against the reference's `scan_end`,
        // doing exactly what it does. Only candidates that survive get the full comparison,
        // so the winner is the same one as ever.
        var bestEndPair: UInt16 = 0

        let earliest = max(0, position - windowSize)

        while candidate >= earliest, chainLeft > 0 {
            chainLeft -= 1

            let match = bytes + candidate

            if best > 0,
               UnsafeRawPointer(match + best - 1).loadUnaligned(as: UInt16.self) != bestEndPair {
                let next = Int(chain[candidate & Self.chainMask])
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

                if best >= effort.goodMatch { break }
                if best >= maxLength { break } // nothing left to beat

                bestEndPair = UnsafeRawPointer(here + best - 1).loadUnaligned(as: UInt16.self)
            }

            let next = Int(chain[candidate & Self.chainMask])
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

            // The loop-carried state lives in locals, written back at each block flush and
            // at exit. The reference's inner loop has exactly this shape for exactly this
            // reason: a loop mutating fields of `self` re-proves and re-reads them through
            // memory at every touch, and this loop touches them for every input byte.
            let head = self.head
            let chain = self.chain
            let symbols = self.symbols
            let literalFrequencies = self.literalFrequencies
            let distanceFrequencies = self.distanceFrequencies
            let effort = self.effort
            let windowSize = self.windowSize

            var cursor = self.cursor
            var symbolCount = self.symbolCount
            var deferredMatch = self.deferred
            var blockStart = self.blockStart

            // Committing to a match: the symbol goes into the block, and the positions the
            // match covers go into the hash chain — except inside long matches at the greedy
            // levels, which the reference leaves unindexed too: the run's head already is,
            // and hashing the rest costs more than it finds.
            func takeMatch(
                _ match: (length: Int, distance: Int),
                startingAt start: Int,
                cursor: inout Int,
                symbolCount: inout Int
            ) {
                let lengthSymbol = Int(DeflateTables.lengthSymbol[match.length - Self.minMatch])
                let distanceSymbol = Self.distanceSymbol(for: match.distance)

                symbols[symbolCount] = 0x8000_0000
                    | UInt32(match.length)
                    | UInt32(match.distance) << 9
                    | UInt32(distanceSymbol) << 25
                symbolCount += 1
                literalFrequencies[257 + lengthSymbol] += 1
                distanceFrequencies[distanceSymbol] += 1

                let end = start + match.length

                if end > cursor + 1, match.length <= effort.maxInsert {
                    for position in (cursor + 1) ..< end {
                        guard position + Self.minMatch <= limit else { break }
                        let key = Self.hash(bytes, at: position)
                        chain[position & Self.chainMask] = head[key]
                        head[key] = Int32(truncatingIfNeeded: position)
                    }
                }

                cursor = end
            }

            // The greedy levels take every match the moment it is found — nothing is ever
            // deferred — so they get a loop with no deferral bookkeeping in it at all, which
            // is the same split the reference makes into `deflate_fast` and `deflate_slow`.
            // Every decision in here is the lazy loop's own with `deferredMatch` pinned to
            // nil, so the two loops produce the same stream. A match can arrive here already
            // deferred — a mid-stream level change is allowed to interrupt anything — and
            // that one call falls through to the lazy loop, which knows how to let it go.
            if effort.maxLazy == 0, deferredMatch == nil {
                while cursor + keepBack < limit {
                    let key = cursor + Self.minMatch <= limit
                        ? Self.hash(bytes, at: cursor)
                        : -1
                    let candidate = key >= 0 ? Int(head[key]) : -1

                    let current: (length: Int, distance: Int)? =
                        candidate < max(0, cursor - windowSize)
                        ? nil
                        : Self.longestMatch(
                            bytes, at: cursor, limit: limit, holding: 0,
                            from: candidate, chain: chain, effort: effort,
                            windowSize: windowSize
                        )

                    if key >= 0 {
                        chain[cursor & Self.chainMask] = Int32(truncatingIfNeeded: candidate)
                        head[key] = Int32(truncatingIfNeeded: cursor)
                    }

                    if let current {
                        takeMatch(
                            current, startingAt: cursor,
                            cursor: &cursor, symbolCount: &symbolCount
                        )
                    } else {
                        let byte = bytes[cursor]
                        symbols[symbolCount] = UInt32(byte)
                        symbolCount += 1
                        literalFrequencies[Int(byte)] += 1
                        cursor += 1
                    }

                    if cursor - blockStart >= Self.maxBlockBytes
                        || symbolCount >= Self.maxBlockSymbols {
                        self.cursor = cursor
                        self.symbolCount = symbolCount
                        self.flushBlock(final: false)
                        symbolCount = self.symbolCount
                        blockStart = self.blockStart
                    }
                }

                self.cursor = cursor
                self.symbolCount = symbolCount
                return
            }

            while cursor + keepBack < limit {
                let heldLength = deferredMatch?.length ?? 0

                // One hash and one head read serve both the search and the insertion below
                // it, since all three are asking about the same three bytes. The key is
                // negative when those bytes run off the end, which is also exactly when
                // none of them has anything to do.
                let key = cursor + Self.minMatch <= limit
                    ? Self.hash(bytes, at: cursor)
                    : -1
                let candidate = key >= 0 ? Int(head[key]) : -1

                // The reference's economy, adopted whole: while a match at least `maxLazy`
                // long is already in hand, no better one is even looked for — the search
                // would usually lose, and it is the single most expensive thing here. A
                // head entry already out of the window skips the search the same way: the
                // walk's first test would refuse it, so there is no call worth making.
                let current: (length: Int, distance: Int)? =
                    candidate < max(0, cursor - windowSize)
                        || (heldLength > 0 && heldLength >= effort.maxLazy)
                    ? nil
                    : Self.longestMatch(
                        bytes, at: cursor, limit: limit, holding: heldLength,
                        from: candidate, chain: chain, effort: effort, windowSize: windowSize
                    )

                if key >= 0 {
                    chain[cursor & Self.chainMask] = Int32(truncatingIfNeeded: candidate)
                    head[key] = Int32(truncatingIfNeeded: cursor)
                }

                if let held = deferredMatch {
                    if let current, current.length > held.length {
                        // Starting a byte later pays better, so the byte the held match began
                        // on becomes a literal and the new match is held in its place.
                        let byte = bytes[cursor - 1]
                        symbols[symbolCount] = UInt32(byte)
                        symbolCount += 1
                        literalFrequencies[Int(byte)] += 1
                        deferredMatch = current
                        cursor += 1
                    } else {
                        takeMatch(
                            held, startingAt: cursor - 1,
                            cursor: &cursor, symbolCount: &symbolCount
                        )
                        deferredMatch = nil
                    }
                } else if let current {
                    // A match already long enough is taken without looking further: past the
                    // level's threshold the search costs more than the byte it might save.
                    if current.length < effort.maxLazy {
                        deferredMatch = current
                        cursor += 1
                    } else {
                        takeMatch(
                            current, startingAt: cursor,
                            cursor: &cursor, symbolCount: &symbolCount
                        )
                    }
                } else {
                    let byte = bytes[cursor]
                    symbols[symbolCount] = UInt32(byte)
                    symbolCount += 1
                    literalFrequencies[Int(byte)] += 1
                    cursor += 1
                }

                let emittedEnd = deferredMatch == nil ? cursor : cursor - 1
                if emittedEnd - blockStart >= Self.maxBlockBytes
                    || symbolCount >= Self.maxBlockSymbols {
                    self.cursor = cursor
                    self.symbolCount = symbolCount
                    self.deferred = deferredMatch
                    self.flushBlock(final: false)
                    symbolCount = self.symbolCount
                    blockStart = self.blockStart
                }
            }

            self.cursor = cursor
            self.symbolCount = symbolCount
            self.deferred = deferredMatch
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
            || self.symbolCount >= Self.maxBlockSymbols
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

        let drop32 = Int32(truncatingIfNeeded: drop)
        for index in 0 ..< Self.hashSize {
            self.head[index] = self.head[index] >= drop32 ? self.head[index] - drop32 : -1
        }

        // The ring's slots stay where they are — `(position - drop) & chainMask` is not
        // `position & chainMask`, but the slot for a position is only ever *read* through the
        // same masked arithmetic it was written through, so only the values need rebasing.
        for index in 0 ..< Self.chainSize {
            self.chain[index] = self.chain[index] >= drop32 ? self.chain[index] - drop32 : -1
        }
    }

    // -- collecting a block's symbols --------------------------------------------

    private mutating func appendLiteral(_ byte: UInt8) {
        self.symbols[self.symbolCount] = UInt32(byte)
        self.symbolCount += 1
        self.literalFrequencies[Int(byte)] += 1
    }

    private mutating func appendMatch(length: Int, distance: Int) {
        let lengthSymbol = Int(DeflateTables.lengthSymbol[length - Self.minMatch])
        let distanceSymbol = Self.distanceSymbol(for: distance)

        self.symbols[self.symbolCount] = 0x8000_0000
            | UInt32(length)
            | UInt32(distance) << 9
            | UInt32(distanceSymbol) << 25
        self.symbolCount += 1

        self.literalFrequencies[257 + lengthSymbol] += 1
        self.distanceFrequencies[distanceSymbol] += 1
    }

    /// Bits the block's matches will spend on raw extra-bits fields — the same under every
    /// block type, since extra bits are written raw whichever coding is chosen. Recovered
    /// from the frequency counts at closing time rather than accumulated per match: each
    /// symbol's extra width is fixed, so the sum is fifty-nine multiplies once per block
    /// instead of two table reads per match.
    private func pendingExtraBits() -> Int {
        var bits = 0

        for symbol in 0 ..< DeflateTables.lengthExtraBits.count {
            bits += self.literalFrequencies[257 + symbol] * DeflateTables.lengthExtraBits[symbol]
        }
        for symbol in 0 ..< Self.distanceSymbolCount {
            bits += self.distanceFrequencies[symbol] * DeflateTables.distanceExtraBits[symbol]
        }

        return bits
    }

    private static func distanceSymbol(for distance: Int) -> Int {
        distance <= 256
            ? Int(DeflateTables.distanceSymbol[distance - 1])
            : Int(DeflateTables.distanceSymbol[256 + ((distance - 1) >> 7)])
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
        let extraBits = self.pendingExtraBits()
        let fixedBits = 3 + self.fixedCostBits(extraBits: extraBits)
        let storedBits = 3 + 7 + 32 + storedLength * 8

        let dynamic = DynamicBlock(
            literalFrequencies: Array(UnsafeBufferPointer(
                start: self.literalFrequencies, count: Self.literalSymbolCount
            )),
            distanceFrequencies: Array(UnsafeBufferPointer(
                start: self.distanceFrequencies, count: Self.distanceSymbolCount
            )),
            extraBits: extraBits
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

        self.symbolCount = 0
        self.blockStart = blockEnd

        self.literalFrequencies.update(repeating: 0, count: Self.literalSymbolCount)
        self.distanceFrequencies.update(repeating: 0, count: Self.distanceSymbolCount)
    }

    /// What this block's symbols would cost under §3.2.6's fixed alphabet.
    private func fixedCostBits(extraBits: Int) -> Int {
        var bits = extraBits

        for symbol in 0 ..< Self.literalSymbolCount where self.literalFrequencies[symbol] > 0 {
            bits += self.literalFrequencies[symbol] * Self.literalOrLengthBits(UInt16(symbol))
        }

        for symbol in 0 ..< Self.distanceSymbolCount {
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

        for index in 0 ..< self.symbolCount {
            let symbol = self.symbols[index]
            guard symbol & 0x8000_0000 != 0 else {
                self.writeLiteralOrLength(UInt16(truncatingIfNeeded: symbol))
                continue
            }

            self.writeMatch(
                length: Int(symbol & 0x1FF),
                distance: Int((symbol >> 9) & 0xFFFF),
                distanceSymbol: Int((symbol >> 25) & 0x1F)
            )
        }

        self.writeLiteralOrLength(DeflateTables.endOfBlock)
    }

    private mutating func writeDynamicBlock(final: Bool, table: DynamicBlock) {
        self.writer.write(final ? 1 : 0, bits: 1)
        self.writer.write(2, bits: 2)

        table.writeTable(to: &self.writer)

        // The tables the loop reads, hoisted out of it: the statics so their once-token is
        // checked here and not per symbol, the block's own so each code is a load with no
        // bounds proof left to run.
        let lengthSymbol = DeflateTables.lengthSymbol
        let lengthExtraBits = DeflateTables.lengthExtraBits
        let lengthBase = DeflateTables.lengthBase
        let distanceExtraBits = DeflateTables.distanceExtraBits
        let distanceBase = DeflateTables.distanceBase

        table.literalEmit.withUnsafeBufferPointer { literalEmit in
            table.distanceEmit.withUnsafeBufferPointer { distanceEmit in
                for index in 0 ..< self.symbolCount {
                    let symbol = self.symbols[index]
                    guard symbol & 0x8000_0000 != 0 else {
                        let emit = literalEmit[Int(symbol & 0xFF)]
                        self.writer.write(emit & 0xFFFF, bits: Int(emit >> 16))
                        continue
                    }

                    let length = Int(symbol & 0x1FF)
                    let distance = Int((symbol >> 9) & 0xFFFF)
                    let distanceSymbol = Int((symbol >> 25) & 0x1F)

                    let lengthIndex = Int(lengthSymbol[length - Self.minMatch])
                    let lengthEmit = literalEmit[257 + lengthIndex]
                    self.writer.write(lengthEmit & 0xFFFF, bits: Int(lengthEmit >> 16))

                    let lengthExtra = lengthExtraBits[lengthIndex]
                    if lengthExtra > 0 {
                        self.writer.write(
                            UInt32(length - lengthBase[lengthIndex]),
                            bits: lengthExtra
                        )
                    }

                    let emit = distanceEmit[distanceSymbol]
                    self.writer.write(emit & 0xFFFF, bits: Int(emit >> 16))

                    let distanceExtra = distanceExtraBits[distanceSymbol]
                    if distanceExtra > 0 {
                        self.writer.write(
                            UInt32(distance - distanceBase[distanceSymbol]),
                            bits: distanceExtra
                        )
                    }
                }
            }
        }

        let endEmit = table.literalEmit[Int(DeflateTables.endOfBlock)]
        self.writer.write(endEmit & 0xFFFF, bits: Int(endEmit >> 16))
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

    private mutating func writeMatch(length: Int, distance: Int, distanceSymbol: Int) {
        let lengthSymbol = Int(DeflateTables.lengthSymbol[length - Self.minMatch])

        self.writeLiteralOrLength(UInt16(257 + lengthSymbol))

        let lengthExtra = DeflateTables.lengthExtraBits[lengthSymbol]
        if lengthExtra > 0 {
            self.writer.write(
                UInt32(length - DeflateTables.lengthBase[lengthSymbol]),
                bits: lengthExtra
            )
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
