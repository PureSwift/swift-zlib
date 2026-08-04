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
        // Two deferrals at once. The modulo is deferred the classic way: neither sum can
        // overflow 32 bits within 5552 bytes (zlib's NMAX), so the reduction runs once per
        // block rather than once per byte. And within each sixteen-byte group the serial
        // dependence of `second` on every intermediate `first` is unrolled algebraically —
        //
        //     second += 16*first + 16*b0 + 15*b1 + ... + 1*b15
        //     first  += b0 + ... + b15
        //
        // — which turns a chain of dependent adds into two independent reductions the
        // compiler is free to vectorize. Same arithmetic, in a shape hardware can run wide.
        guard var cursor = bytes.baseAddress else { return }
        var remaining = bytes.count

        var first = self.first
        var second = self.second

        while remaining >= 16 {
            var groups = min(remaining / 16, 347) // 347 * 16 = 5552, the reduction budget

            remaining -= groups * 16

            while groups > 0 {
                second &+= first &* 16

                var plain: UInt32 = 0
                var weighted: UInt32 = 0

                for offset in 0 ..< 16 {
                    let byte = UInt32(cursor[offset])
                    plain &+= byte
                    weighted &+= byte &* UInt32(16 - offset)
                }

                first &+= plain
                second &+= weighted

                cursor += 16
                groups -= 1
            }

            first %= Self.modulus
            second %= Self.modulus
        }

        for offset in 0 ..< remaining {
            first &+= UInt32(cursor[offset])
            second &+= first
        }

        self.first = first % Self.modulus
        self.second = second % Self.modulus
    }

    public mutating func update(_ byte: UInt8) {
        self.first += UInt32(byte)
        self.second += self.first

        if self.first >= Self.modulus { self.first -= Self.modulus }
        if self.second >= Self.modulus { self.second -= Self.modulus }
    }
}
