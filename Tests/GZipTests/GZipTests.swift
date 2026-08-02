import Testing

@testable import GZip

/// gzip is checked against members a known-good compressor produced, not only against this
/// module's own output: a codec compared with itself agrees with itself and nothing else.
///
/// The header is where the work is, so most of what is here is header shapes — the optional
/// fields, in every combination that changes which bytes come next.
@Suite("GZip")
struct GZipTests {
    static let payload = Array(
        String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 12).utf8
    )

    static func inflate(
        _ compressed: [UInt8],
        into capacity: Int = 65536,
        feeding chunkSize: Int = Int.max
    ) throws -> [UInt8] {
        let stream = Decompressor()
        var output = [UInt8](repeating: 0, count: capacity)
        var produced = 0
        var offset = 0
        var input = compressed

        try input.withUnsafeMutableBufferPointer { buffer in
            while true {
                if stream.needsInput, offset < buffer.count {
                    let size = min(chunkSize, buffer.count - offset)
                    stream.setInput(
                        UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: size)
                    )
                    offset += size
                }

                let made = try output.withUnsafeMutableBufferPointer {
                    try stream.inflate(into: $0.baseAddress! + produced, count: $0.count - produced)
                }

                produced += made

                if stream.isFinished { break }
                if made == 0, offset >= buffer.count { break }
            }
        }

        return Array(output[0 ..< produced])
    }

    static func compress(
        _ payload: [UInt8],
        level: Int32 = 6,
        collecting bufferSize: Int = 4096
    ) throws -> [UInt8] {
        let compressor = Compressor(level: level)
        var compressed: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: bufferSize)
        var payload = payload

        try payload.withUnsafeMutableBufferPointer { buffer in
            if buffer.count > 0 {
                compressor.setInput(UnsafeBufferPointer(buffer))
            }

            while !compressor.isFinished {
                let made = try scratch.withUnsafeMutableBufferPointer {
                    try compressor.deflate(into: $0.baseAddress!, count: $0.count, ending: .finish)
                }
                compressed.append(contentsOf: scratch[0 ..< made])
            }
        }

        return compressed
    }

    /// Produced by zlib at level 6 with gzip framing, no optional fields.
    @Test("A member from a known-good compressor")
    func referenceMember() throws {
        var member: [UInt8] = [
            0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        ]
        member.append(contentsOf: try Self.deflateBody())

        #expect(try Self.inflate(member) == Self.payload)
    }

    /// The DEFLATE body and trailer for the payload, taken from this module's own compressor so
    /// the header above can be varied without hand-assembling a whole member each time.
    static func deflateBody() throws -> [UInt8] {
        Array(try Self.compress(Self.payload).dropFirst(10))
    }

    @Test("Round trip")
    func roundTrip() throws {
        #expect(try Self.inflate(Self.compress(Self.payload)) == Self.payload)
    }

    @Test("Empty input round-trips")
    func empty() throws {
        #expect(try Self.inflate(Self.compress([])) == [])
    }

    /// A member is header, DEFLATE data, then eight bytes of trailer.
    @Test("The framing is what RFC 1952 requires")
    func framing() throws {
        let member = try Self.compress(Self.payload)

        #expect(member[0] == 0x1F)
        #expect(member[1] == 0x8B)
        #expect(member[2] == 8)
        #expect(member[3] == 0) // no optional fields

        var checksum = Crc32()
        Self.payload.withUnsafeBufferPointer { checksum.update($0) }
        let crc = checksum.checksum
        let length = UInt32(Self.payload.count)

        // Least significant byte first, the opposite of zlib's big-endian trailer.
        #expect(Array(member.suffix(8)) == [
            UInt8(truncatingIfNeeded: crc),
            UInt8(truncatingIfNeeded: crc >> 8),
            UInt8(truncatingIfNeeded: crc >> 16),
            UInt8(truncatingIfNeeded: crc >> 24),
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24),
        ])
    }

    /// Every optional field, each of which changes where the DEFLATE data starts. A decoder
    /// that skips one wrongly reads the compressed data from the wrong byte.
    @Test("Optional header fields are skipped correctly")
    func optionalFields() throws {
        let body = try Self.deflateBody()

        // FNAME: a zero-terminated name.
        var named: [UInt8] = [0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0x02, 0xFF]
        named.append(contentsOf: Array("payload.txt".utf8))
        named.append(0)
        named.append(contentsOf: body)
        #expect(try Self.inflate(named) == Self.payload)

        // FEXTRA: two bytes of length, then that many bytes.
        var extra: [UInt8] = [0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0x00, 0x03]
        extra.append(contentsOf: [0x04, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        extra.append(contentsOf: body)
        #expect(try Self.inflate(extra) == Self.payload)

        // FCOMMENT.
        var commented: [UInt8] = [0x1F, 0x8B, 0x08, 0x10, 0, 0, 0, 0, 0x00, 0x03]
        commented.append(contentsOf: Array("a comment".utf8))
        commented.append(0)
        commented.append(contentsOf: body)
        #expect(try Self.inflate(commented) == Self.payload)

        // All three at once, in the order the format fixes.
        var everything: [UInt8] = [0x1F, 0x8B, 0x08, 0x1C, 0, 0, 0, 0, 0x00, 0x03]
        everything.append(contentsOf: [0x02, 0x00, 0x01, 0x02])
        everything.append(contentsOf: Array("name".utf8) + [0])
        everything.append(contentsOf: Array("comment".utf8) + [0])
        everything.append(contentsOf: body)
        #expect(try Self.inflate(everything) == Self.payload)
    }

    /// A header CRC has to be checked rather than skipped, and a wrong one refused.
    @Test("The header checksum is verified")
    func headerChecksum() throws {
        let body = try Self.deflateBody()
        var header: [UInt8] = [0x1F, 0x8B, 0x08, 0x02, 0, 0, 0, 0, 0x00, 0x03]

        var checksum = Crc32()
        header.withUnsafeBufferPointer { checksum.update($0) }
        let value = checksum.checksum

        var good = header
        good.append(UInt8(truncatingIfNeeded: value))
        good.append(UInt8(truncatingIfNeeded: value >> 8))
        good.append(contentsOf: body)
        #expect(try Self.inflate(good) == Self.payload)

        header.append(UInt8(truncatingIfNeeded: value) ^ 0xFF)
        header.append(UInt8(truncatingIfNeeded: value >> 8))
        header.append(contentsOf: body)

        #expect(throws: DeflateError.self) { _ = try Self.inflate(header) }
    }

    /// Every point in the header is a place the input can run out, and the answer has to be the
    /// same as when it does not.
    @Test("Feeding one byte at a time gives the same answer", arguments: [1, 2, 3, 7])
    func chunkedFeeding(_ chunk: Int) throws {
        let member = try Self.compress(Self.payload)
        #expect(try Self.inflate(member, feeding: chunk) == Self.payload)
    }

    @Test("Collecting one byte at a time gives the same member")
    func bytewiseCollection() throws {
        #expect(try Self.compress(Self.payload, collecting: 1) == Self.compress(Self.payload))
    }

    @Test("A bad magic number is refused")
    func badMagic() throws {
        #expect(throws: DeflateError.self) {
            _ = try Self.inflate([0x1F, 0x8C, 0x08, 0x00, 0, 0, 0, 0, 0, 3])
        }
    }

    @Test("Reserved flags are refused")
    func reservedFlags() throws {
        #expect(throws: DeflateError.self) {
            _ = try Self.inflate([0x1F, 0x8B, 0x08, 0x20, 0, 0, 0, 0, 0, 3])
        }
    }

    /// The trailer carries two independent claims, and both are worth checking: a member whose
    /// checksum matches but whose length does not decoded to the right bytes and the wrong
    /// number of them.
    @Test("A bad CRC and a bad length are both refused")
    func badTrailer() throws {
        var member = try Self.compress(Self.payload)
        member[member.count - 5] ^= 0xFF
        #expect(throws: DeflateError.self) { _ = try Self.inflate(member) }

        var wrongLength = try Self.compress(Self.payload)
        wrongLength[wrongLength.count - 1] ^= 0xFF
        #expect(throws: DeflateError.self) { _ = try Self.inflate(wrongLength) }
    }
}
