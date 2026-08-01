// Crc32.swift - the other checksum zlib publishes
//
// Not part of a zlib stream, which carries an Adler-32 instead; this is here because
// `crc32()` is one of the functions zlib exports, and the formats layered on top of it —
// gzip over the whole stream, PNG over each chunk — are what ask for it.
//
// Computed incrementally, because the data it covers is not necessarily held in one piece:
// a caller feeds it in whatever sized bites it has, and the checksum accumulates across them.

/// The CRC-32 of ITU-T V.42, which is the one gzip and PNG both specify.
public struct Crc32 {
    /// The reversed polynomial those formats specify.
    private static let polynomial: UInt32 = 0xEDB8_8320

    /// One entry per possible byte, so the checksum advances a byte at a time
    /// instead of a bit at a time.
    private static let table: [UInt32] = {
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

        for byte in bytes {
            state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
        }

        self.state = state
    }

    public mutating func update(_ byte: UInt8) {
        self.state = Self.table[Int((self.state ^ UInt32(byte)) & 0xFF)]
            ^ (self.state >> 8)
    }

    /// The checksum as it appears in the file.
    public var checksum: UInt32 {
        self.state ^ 0xFFFF_FFFF
    }
}
