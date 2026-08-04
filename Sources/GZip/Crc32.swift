// Crc32.swift - the checksum a gzip member carries
//
// Here rather than beside Adler-32 in the `Zlib` module because this is the format that
// actually uses it: a zlib stream carries an Adler-32 and never a CRC-32. zlib the library
// publishes `crc32()` for the sake of the formats layered on top of it — gzip over the whole
// member, PNG over each chunk — which is a reason to export it, not a reason for it to live
// with RFC 1950.
//
// Computed incrementally, because the data it covers is not necessarily held in one piece:
// a caller feeds it in whatever sized bites it has, and the checksum accumulates across them.

/// The CRC-32 of ITU-T V.42, which is the one gzip and PNG both specify.
public struct Crc32 {
    /// The reversed polynomial those formats specify.
    private static let polynomial: UInt32 = 0xEDB8_8320

    /// One entry per possible byte, so the checksum advances a byte at a time
    /// instead of a bit at a time.
    ///
    /// Published because zlib publishes it: `get_crc_table` hands this very array to callers
    /// that want to compute the same checksum themselves.
    public static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)

        for index in 0 ..< 256 {
            var value = UInt32(index)

            for _ in 0 ..< 8 {
                value = value & 1 != 0
                    ? Self.polynomial ^ (value >> 1)
                    : value >> 1
            }

            table[index] = value
        }

        return table
    }()

    /// Eight tables in one flat array, `slicing[t * 256 + i]`: table `t` advances a byte
    /// through `t + 1` further bytes of zeros, which is what lets eight input bytes fold into
    /// the state with eight independent lookups instead of eight dependent ones. Table zero is
    /// exactly ``table``; the published one keeps its own identity because `get_crc_table`
    /// hands it out and its shape is API.
    private static let slicing: [UInt32] = {
        var slicing = [UInt32](repeating: 0, count: 8 * 256)

        for index in 0 ..< 256 {
            slicing[index] = Self.table[index]
        }
        for t in 1 ..< 8 {
            for index in 0 ..< 256 {
                let previous = slicing[(t - 1) * 256 + index]
                slicing[t * 256 + index] = (previous >> 8) ^ Self.table[Int(previous & 0xFF)]
            }
        }

        return slicing
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    /// Resumes from a checksum already computed over an earlier run of bytes.
    public init(resuming checksum: UInt32) {
        self.state = checksum ^ 0xFFFF_FFFF
    }

    public mutating func reset() {
        self.state = 0xFFFF_FFFF
    }

    public mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        var state = self.state

        guard var cursor = bytes.baseAddress else { return }
        var remaining = bytes.count

        // Eight bytes per iteration: four folded through the state, four through zeros, all
        // eight resolved by independent table reads the processor can overlap. The tail that
        // does not fill a group goes the byte-at-a-time way below.
        if remaining >= 8 {
            Self.slicing.withUnsafeBufferPointer { slicing in
                while remaining >= 8 {
                    let low = state ^ UInt32(
                        littleEndian: UnsafeRawPointer(cursor).loadUnaligned(as: UInt32.self)
                    )
                    let high = UInt32(
                        littleEndian: UnsafeRawPointer(cursor + 4).loadUnaligned(as: UInt32.self)
                    )

                    state = slicing[Int(7 * 256 + (low & 0xFF))]
                        ^ slicing[Int(6 * 256 + ((low >> 8) & 0xFF))]
                        ^ slicing[Int(5 * 256 + ((low >> 16) & 0xFF))]
                        ^ slicing[Int(4 * 256 + (low >> 24))]
                        ^ slicing[Int(3 * 256 + (high & 0xFF))]
                        ^ slicing[Int(2 * 256 + ((high >> 8) & 0xFF))]
                        ^ slicing[Int(1 * 256 + ((high >> 16) & 0xFF))]
                        ^ slicing[Int(high >> 24)]

                    cursor += 8
                    remaining -= 8
                }
            }
        }

        for index in 0 ..< remaining {
            state = Crc32.table[Int((state ^ UInt32(cursor[index])) & 0xFF)] ^ (state >> 8)
        }

        self.state = state
    }

    public mutating func update(_ byte: UInt8) {
        self.state = Crc32.table[Int((self.state ^ UInt32(byte)) & 0xFF)]
            ^ (self.state >> 8)
    }

    /// The checksum as it appears in the file.
    public var checksum: UInt32 {
        self.state ^ 0xFFFF_FFFF
    }
}
