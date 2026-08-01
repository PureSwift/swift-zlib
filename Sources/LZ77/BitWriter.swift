// BitWriter.swift - packing bits back out in DEFLATE's order
//
// The mirror of BitReader: fields go out low bit first within a byte and run across byte
// boundaries, so a writer accumulates into a wide register and drops whole bytes off the bottom
// as they complete.
//
// Huffman codes are the one exception, exactly as they are when reading — a code is defined
// most significant bit first, so it is reversed on the way out. That reversal is done here
// rather than at each call site so that no caller has to remember which of the two orders it is
// holding.
struct BitWriter {
    private var buffer: UInt64 = 0
    private var bitCount = 0

    /// Bytes completed since the last time they were taken.
    private(set) var output: [UInt8] = []

    mutating func write(_ value: UInt32, bits: Int) {
        guard bits > 0 else { return }

        let mask: UInt64 = ~UInt64(0) >> (64 - bits)
        self.buffer |= (UInt64(value) & mask) << self.bitCount
        self.bitCount += bits

        while self.bitCount >= 8 {
            self.output.append(UInt8(truncatingIfNeeded: self.buffer))
            self.buffer >>= 8
            self.bitCount -= 8
        }
    }

    /// Writes a Huffman code, reversing it so the most significant bit goes out first.
    mutating func writeCode(_ code: UInt32, bits: Int) {
        var reversed: UInt32 = 0

        for index in 0 ..< bits {
            reversed |= ((code >> (bits - 1 - index)) & 1) << index
        }

        self.write(reversed, bits: bits)
    }

    /// Pads to the next byte boundary with zeroes, which is what a stored block's header needs
    /// and what ends a stream.
    mutating func alignToByte() {
        if self.bitCount > 0 {
            self.write(0, bits: 8 - self.bitCount)
        }
    }

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.output.append(contentsOf: bytes)
    }

    mutating func append(_ byte: UInt8) {
        self.output.append(byte)
    }

    /// Hands over what has completed so far, leaving any partial byte behind for the next write.
    mutating func takeOutput() -> [UInt8] {
        let taken = self.output
        self.output = []
        return taken
    }

    /// Returns bytes a caller took but could not place, ahead of anything written since.
    ///
    /// Only ever called with a tail of what ``takeOutput()`` just returned, and nothing can have
    /// been written in between, so this restores the original order rather than interleaving.
    mutating func putBack(_ bytes: [UInt8]) {
        self.output.insert(contentsOf: bytes, at: 0)
    }

    var pendingByteCount: Int {
        self.output.count
    }
}
