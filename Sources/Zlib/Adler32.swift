// Adler32.swift - the checksum a zlib stream carries
//
// RFC 1950's own algorithm: two eight-bit sums carried mod 65521 (the largest prime under
// 2^16), one running total of the bytes and one running total of the first sum after each byte,
// packed into one 32-bit value as (second << 16) | first. Cheaper than a CRC and, for this
// library's purposes, someone else's format decision rather than a choice made here.
public struct Adler32 {
    private var first: UInt32 = 1
    private var second: UInt32 = 0

    private static let modulus: UInt32 = 65521

    /// A checksum over nothing yet, which RFC 1950 defines as 1 rather than 0.
    public init() {}

    /// Resumes from a checksum already computed over an earlier run of bytes.
    ///
    /// The two halves are recovered by splitting the packed value, which is exact: neither half
    /// ever exceeds the modulus, so nothing was lost in packing them together.
    public init(resuming value: UInt32) {
        self.first = value & 0xFFFF
        self.second = value >> 16
    }

    public var value: UInt32 {
        (self.second << 16) | self.first
    }

    public mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        // Reduced every so often rather than after every byte, which is what keeps this a
        // handful of adds per byte instead of a division: `second` cannot overflow a 32-bit
        // accumulator before enough bytes have passed for the reduction to be worth doing
        // again, so it is deferred until the block below is about to run out of headroom.
        var index = 0

        while index < bytes.count {
            let chunk = min(bytes.count - index, 5552)

            for offset in 0 ..< chunk {
                self.first += UInt32(bytes[index + offset])
                self.second += self.first
            }

            self.first %= Self.modulus
            self.second %= Self.modulus
            index += chunk
        }
    }

    public mutating func update(_ byte: UInt8) {
        self.first += UInt32(byte)
        self.second += self.first

        if self.first >= Self.modulus { self.first -= Self.modulus }
        if self.second >= Self.modulus { self.second -= Self.modulus }
    }
}
