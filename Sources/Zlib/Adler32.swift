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
        // Two deferrals, and one piece of algebra that makes the whole run vectorise.
        //
        // The modulo is deferred the classic way: neither sum can overflow within 5552 bytes
        // (zlib's NMAX), so the reduction runs once per block.  The serial dependence — 
        // absorbs  after every byte — is removed for the whole block at once rather than
        // per group of sixteen: over a run of n bytes,
        //
        //     first'  = first + P                       where P = b1 + ... + bn
        //     second' = second + n*first + sum (n-k+1) * bk
        //
        // and with the run walked sixteen lanes at a time, byte k sits at chunk c, lane l, so
        // its weight n - 16c - l splits into three pieces: n times the plain sum, sixteen times
        // the chunk-weighted sum, and the lane-weighted sum.  The first two are one vector
        // accumulator each — two multiply-accumulates per sixteen bytes, no horizontal step
        // anywhere in the loop — and the lane weighting falls out of the plain accumulator at
        // the end, since lane l of it holds exactly the bytes that want weight l.
        guard var cursor = bytes.baseAddress else { return }
        var remaining = bytes.count

        var first = self.first
        var second = self.second

        while remaining >= 16 {
            let groups = min(remaining / 16, 347) // 347 * 16 = 5552, the reduction budget

            remaining -= groups * 16

            var plainLanes = SIMD16<UInt32>()
            var chunkWeighted = SIMD16<UInt32>()

            for chunk in 0 ..< UInt32(groups) {
                let wide = SIMD16<UInt32>(
                    truncatingIfNeeded: UnsafeRawPointer(cursor)
                        .loadUnaligned(as: SIMD16<UInt8>.self)
                )

                plainLanes &+= wide
                chunkWeighted &+= wide &* SIMD16<UInt32>(repeating: chunk)
                cursor += 16
            }

            // The reduction, in sixty-four bits: n*P alone can reach eight billion.
            let n = UInt64(groups * 16)
            let plain = UInt64(plainLanes.wrappedSum())

            var laneWeighted: UInt64 = 0
            for lane in 1 ..< 16 {
                laneWeighted += UInt64(lane) * UInt64(plainLanes[lane])
            }

            let absorbed = n * UInt64(first) + n * plain
                - 16 * UInt64(chunkWeighted.wrappedSum()) - laneWeighted

            first = UInt32((UInt64(first) + plain) % UInt64(Self.modulus))
            second = UInt32((UInt64(second) + absorbed) % UInt64(Self.modulus))
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
