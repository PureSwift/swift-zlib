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

    mutating func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.input = bytes
        self.inputOffset = 0
    }

    /// Pulls whatever is left of the current input block into the bit buffer.
    ///
    /// The buffer holds up to 64 bits and is topped up a byte at a time, so bits already read
    /// but not yet consumed are never disturbed by a refill.
    private mutating func refill() {
        while self.bitCount <= 56, self.inputOffset < self.input.count {
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
            self.refill()

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
