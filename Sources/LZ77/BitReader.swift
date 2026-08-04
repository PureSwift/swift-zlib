// BitReader.swift - pulling DEFLATE's bit-level fields out of a byte stream
//
// DEFLATE packs fields LSB-first within each byte and across byte boundaries, which is
// backwards from how most formats are read: the first bit taken from a byte is its least
// significant, and a multi-bit field's low-order bit comes first.  This is RFC 1951 §3.1.1's
// packing order, and every other block header, Huffman code, and extra-bits field in the
// format follows it, so one reader over that order is what everything else here builds on.
//
// Shaped push-in, pull-out like the streams above it: bytes go in whenever the caller has
// some, and a read either succeeds from what is buffered or reports that it needs more without
// consuming anything, so the exact same call can be retried once more input has arrived. That
// atomicity is what lets a caller decode a value one field — or one bit — at a time and resume
// cleanly wherever an earlier call ran out of input, without this reader having to know what a
// "value" means to whoever is decoding.
struct BitReader {
    private var buffer: UInt64 = 0
    private var bitCount = 0

    private var input: UnsafeBufferPointer<UInt8> = UnsafeBufferPointer(start: nil, count: 0)
    private var inputOffset = 0

    /// Whether every byte handed in has been consumed into the bit buffer or beyond.
    ///
    /// Deliberately says nothing about the bits still buffered: this is the analogue of zlib's
    /// `avail_in == 0`, which is what callers poll to decide whether to supply more — and a
    /// decoder holding seventeen bits of a thirty-two bit field needs more input even though it
    /// is not empty-handed.
    var needsInput: Bool {
        self.inputOffset >= self.input.count
    }

    /// How many bytes have been taken out of the buffer handed to ``setInput(_:)``.
    ///
    /// After any read that succeeded, this is exactly how much of the input that read needed:
    /// ``refill(upTo:)`` stops the moment it has enough, so no more than seven bits — never a
    /// whole byte — are ever left over. That is what lets a caller say precisely where a stream
    /// ended, and so what makes the bytes after one findable.
    var pulledByteCount: Int {
        self.inputOffset
    }

    mutating func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.input = bytes
        self.inputOffset = 0
    }

    /// Pulls just enough bytes to satisfy a read of `count` bits, and not one more.
    ///
    /// The restraint is the point. Filling the buffer whenever there was room would be a little
    /// faster and would quietly absorb up to eight bytes past whatever is being read — so at
    /// the end of a stream, bytes belonging to whatever *follows* it would already be inside
    /// this reader, and a caller asking where the stream ended would be told the wrong place.
    ///
    /// Pulling only on demand bounds it exactly: this stops as soon as `count` bits are
    /// available, so at most seven bits are ever left over, which is less than a whole byte.
    /// Every byte this reader has taken is therefore a byte it has genuinely read from.
    private mutating func refill(upTo count: Int) {
        while self.bitCount < count, self.inputOffset < self.input.count {
            self.buffer |= UInt64(self.input[self.inputOffset]) << self.bitCount
            self.inputOffset += 1
            self.bitCount += 8
        }
    }

    /// Reads `count` bits (0...32) as an unsigned value, low bit first.
    ///
    /// Returns nil, consuming nothing, when the input does not yet hold enough bits — so the
    /// identical call can be retried once more has arrived.
    mutating func bits(_ count: Int) -> UInt32? {
        if self.bitCount < count {
            self.refill(upTo: count)

            if self.bitCount < count {
                return nil
            }
        }

        let mask: UInt64 = count == 0 ? 0 : (~UInt64(0) >> (64 - count))
        let value = self.buffer & mask

        self.buffer >>= count
        self.bitCount -= count

        return UInt32(truncatingIfNeeded: value)
    }

    /// Makes `count` bits available if the input can supply them, and says whether it could.
    ///
    /// For a decoder that wants to look at several bits at once rather than one at a time. The
    /// look-ahead is bounded by ``refill(upTo:)`` stopping the moment it has enough, so this
    /// reads at most seven bits further than asked — under a byte, which is what keeps the
    /// count of consumed input honest.
    mutating func ensure(_ count: Int) -> Bool {
        if self.bitCount < count {
            self.refill(upTo: count)
        }

        return self.bitCount >= count
    }

    /// The next `count` bits without consuming them. Only valid after ``ensure(_:)`` said so.
    func peek(_ count: Int) -> UInt32 {
        let mask: UInt64 = count == 0 ? 0 : (~UInt64(0) >> (64 - count))
        return UInt32(truncatingIfNeeded: self.buffer & mask)
    }

    /// Consumes bits already looked at.
    mutating func drop(_ count: Int) {
        self.buffer >>= count
        self.bitCount -= count
    }

    /// Puts `count` bits in front of whatever is read next.
    ///
    /// For a caller that has already consumed part of a stream by itself and wants this reader
    /// to carry on from the middle of a byte — which is what `inflatePrime` is for. Returns
    /// false when there is not room, the buffer holding sixty-four bits at most.
    mutating func prime(_ value: UInt32, bits count: Int) -> Bool {
        guard count >= 0, count <= 32, self.bitCount + count <= 64 else { return false }

        let mask: UInt64 = count == 0 ? 0 : (~UInt64(0) >> (64 - count))

        // Ahead of what is already buffered, so the primed bits are read first.
        self.buffer = (self.buffer << count) | (UInt64(value) & mask)
        self.bitCount += count

        return true
    }

    // -- the raw fields, for the fast path -----------------------------------
    //
    // The fast loop in `InflateCore` runs on local copies of these and writes them back once
    // per run, having first given back the whole bytes it over-read — so the at-most-seven-bit
    // invariant documented on ``pulledByteCount`` holds again by the time anything outside the
    // run can observe it.

    var rawBuffer: UInt64 { self.buffer }
    var rawBitCount: Int { self.bitCount }
    var rawInputOffset: Int { self.inputOffset }
    var rawInput: UnsafeBufferPointer<UInt8> { self.input }

    mutating func restoreRaw(buffer: UInt64, bitCount: Int, inputOffset: Int) {
        self.buffer = buffer
        self.bitCount = bitCount
        self.inputOffset = inputOffset
    }

    /// Whether the reader sits on a byte boundary with nothing part-read.
    var isByteAligned: Bool {
        self.bitCount % 8 == 0
    }

    /// Drops whatever is left of the current byte, so the next read starts on a byte boundary.
    ///
    /// A stored block is byte-aligned data with no bit packing, and this is what gets a reader
    /// that may be mid-byte back to a boundary before one is read. Safe to call at any bit
    /// position, including one this reader arrived at from bits already consumed.
    mutating func alignToByte() {
        let drop = self.bitCount % 8
        self.buffer >>= drop
        self.bitCount -= drop
    }
}
