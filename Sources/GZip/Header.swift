// Header.swift - what a gzip member says about itself
//
// §2.3 gives a member ten fixed bytes and four optional fields. Nothing in the fixed part
// affects decoding, and none of the optional fields do either — they are metadata about the
// file the member was made from, which is why a decompressor can skip all of them and still be
// correct, and why a compressor that writes none of them still produces a valid member.
//
// They are here because callers want them: the name is how `gunzip` knows what to call the
// file it writes, and the modification time is what it stamps on it.

/// The metadata a gzip member carries.
public struct Header: Sendable {
    /// §2.3.1: the FTEXT flag, a compressor's guess that the content is text rather than binary.
    /// Advisory, and nothing is obliged to act on it.
    public var isText = false

    /// The modification time of the original file, in seconds since the Unix epoch, or zero
    /// for "not recorded" — which is what this library writes unless told otherwise, since a
    /// clock reading would make compressing the same bytes twice produce different output.
    public var modificationTime: UInt32 = 0

    /// §2.3.1: the filesystem the member was made on. 3 is Unix, 255 is unknown.
    public var operatingSystem: UInt8 = 3

    /// §2.3.1: the XFL byte, a hint about how hard the compressor worked.
    ///
    /// Read from a member but not written from here: a compressor derives it from the level it
    /// was given, which is what the reference does even when a caller supplies a header.
    public var extraFlags: UInt8 = 0

    /// §2.3.1.1: subfields whose meaning the format leaves open.
    public var extra: [UInt8]?

    /// The original file name, without its terminator, in Latin-1 as the format asks.
    public var fileName: [UInt8]?

    public var comment: [UInt8]?

    /// Whether a CRC-16 over the header follows it.
    public var hasHeaderChecksum = false

    public init() {}

    /// The bytes this header is written as.
    func encoded(extraFlags: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [0x1F, 0x8B, 8]

        var flags: UInt8 = 0
        if self.isText { flags |= 0x01 }
        if self.hasHeaderChecksum { flags |= 0x02 }
        if self.extra != nil { flags |= 0x04 }
        if self.fileName != nil { flags |= 0x08 }
        if self.comment != nil { flags |= 0x10 }
        bytes.append(flags)

        bytes.append(UInt8(truncatingIfNeeded: self.modificationTime))
        bytes.append(UInt8(truncatingIfNeeded: self.modificationTime >> 8))
        bytes.append(UInt8(truncatingIfNeeded: self.modificationTime >> 16))
        bytes.append(UInt8(truncatingIfNeeded: self.modificationTime >> 24))

        bytes.append(extraFlags)
        bytes.append(self.operatingSystem)

        if let extra = self.extra {
            bytes.append(UInt8(truncatingIfNeeded: extra.count))
            bytes.append(UInt8(truncatingIfNeeded: extra.count >> 8))
            bytes.append(contentsOf: extra)
        }

        // Both of these are zero-terminated, which is also why neither may contain a zero.
        if let name = self.fileName {
            bytes.append(contentsOf: name)
            bytes.append(0)
        }

        if let comment = self.comment {
            bytes.append(contentsOf: comment)
            bytes.append(0)
        }

        if self.hasHeaderChecksum {
            // §2.3.1: the two low bytes of a CRC-32 over everything above.
            var checksum = Crc32()
            bytes.withUnsafeBufferPointer { checksum.update($0) }

            let value = checksum.checksum
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        return bytes
    }
}
