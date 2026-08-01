// Decompressor.swift - reading RFC 1950 framing off a DEFLATE stream
//
// The counterpart to Compressor, and harder than it for one reason: the framing is not merely
// concatenated with the DEFLATE data, it is interleaved with reading it. The header has to be
// consumed before the first block, the Adler-32 after the last, and both come off the same
// input the decompressor below is reading — which holds part of a byte at a time, so there is
// no byte offset this layer could hand it or take back from it.
//
// So this does not buffer input of its own. It reads its two fields *through* the `LZ77` stream,
// which is what ``Inflate.readBits(_:)`` exists for, and the question of who consumed how much
// never comes up.

import LZ77

public final class Decompressor {
    private enum State {
        case header
        case data
        case trailer
        case done
    }

    private var state: State = .header
    private let stream = Inflate()
    private var checksum = Adler32()

    /// Whether the stream has ended *and* its checksum has been read and matched.
    ///
    /// Deliberately not true the moment the last block is decoded: until the trailer is checked,
    /// the bytes produced are unverified, and a caller that stopped here would never learn that.
    public private(set) var isFinished = false

    public init() {}

    public var needsInput: Bool {
        self.stream.needsInput
    }

    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.stream.setInput(bytes)
    }

    /// Decompresses into `destination`, returning how many bytes were produced.
    public func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(DeflateError) -> Int {
        guard count > 0 else { return 0 }

        var produced = 0

        loop: while true {
            switch self.state {
            case .header:
                guard let raw = self.stream.readBits(16) else { break loop }
                try Self.checkHeader(raw)
                self.state = .data

            case .data:
                guard produced < count else { break loop }

                let made = try self.stream.inflate(
                    into: destination + produced,
                    count: count - produced
                )

                if made > 0 {
                    // Checksummed from the caller's buffer rather than as each byte is produced:
                    // the trailer covers the output in full, and folding it in a block at a time
                    // is what keeps Adler-32 a few adds per byte.
                    self.checksum.update(
                        UnsafeBufferPointer(start: destination + produced, count: made)
                    )
                    produced += made
                }

                if self.stream.isFinished {
                    self.state = .trailer
                    continue
                }

                // No progress and not finished: the input ran out, or the destination did.
                if made == 0 { break loop }

            case .trailer:
                // The last block ends wherever its final code did, but the checksum after it is
                // byte-aligned (RFC 1950 §2.2), so whatever is left of that byte is padding.
                // Aligning is idempotent, which matters because this state is re-entered every
                // time the four bytes have not all arrived yet.
                self.stream.alignToByte()

                guard let raw = self.stream.readBits(32) else { break loop }

                // The four bytes come off the reader in stream order at ascending bit positions
                // — `raw`'s low byte is the first one read — but the checksum they spell is big
                // endian, so reassembling it reverses that order.
                let stored =
                    ((raw & 0xFF) << 24)
                    | (((raw >> 8) & 0xFF) << 16)
                    | (((raw >> 16) & 0xFF) << 8)
                    | ((raw >> 24) & 0xFF)

                guard stored == self.checksum.value else {
                    throw DeflateError("Adler-32 checksum mismatch")
                }

                self.state = .done
                self.isFinished = true

            case .done:
                break loop
            }
        }

        return produced
    }

    /// §2.2: the two header bytes read as a big-endian number must divide by 31, the low nibble
    /// of the first must name deflate, and a preset dictionary is a contract this cannot meet
    /// without being given the dictionary.
    private static func checkHeader(_ raw: UInt32) throws(DeflateError) {
        let cmf = raw & 0xFF
        let flg = (raw >> 8) & 0xFF

        guard (cmf * 256 + flg) % 31 == 0 else {
            throw DeflateError("bad zlib header")
        }

        guard cmf & 0x0F == 8 else {
            throw DeflateError("unsupported compression method")
        }

        guard (flg >> 5) & 1 == 0 else {
            throw DeflateError("zlib preset dictionaries are not supported")
        }
    }
}
