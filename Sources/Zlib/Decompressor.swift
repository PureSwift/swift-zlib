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
        /// The header said a preset dictionary was used; four bytes naming which follow.
        case dictionaryId
        /// Waiting for the caller to supply it.
        case needsDictionary
        case data
        case trailer
        case done
    }

    private var state: State = .header
    private var stream = Inflate()
    private var checksumState = Adler32()

    /// Whether the stream has ended *and* its checksum has been read and matched.
    ///
    /// Deliberately not true the moment the last block is decoded: until the trailer is checked,
    /// the bytes produced are unverified, and a caller that stopped here would never learn that.
    public private(set) var isFinished = false

    /// How many bytes the last call wrote, whether it returned or threw.
    public private(set) var producedInLastCall = 0

    /// The Adler-32 of the dictionary this stream was compressed against, once its header has
    /// said there is one. A caller matches it against the dictionaries it holds.
    public private(set) var dictionaryId: UInt32?

    /// Whether this stream cannot go further until a dictionary is supplied.
    ///
    /// Not an error, though it is fatal if ignored: the stream is well formed and simply refers
    /// to text that was never in it.
    public var needsDictionary: Bool {
        self.state == .needsDictionary
    }

    /// The largest window the caller is prepared for, or nil to take whatever the header
    /// declares. A stream declaring more than the caller allowed for is refused rather than
    /// decoded into a window it was not sized for.
    private let maximumWindowBits: Int32?

    public init(maximumWindowBits: Int32? = 15) {
        self.maximumWindowBits = maximumWindowBits
    }

    /// Supplies the preset dictionary the header asked for.
    public func setDictionary(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard self.state == .needsDictionary else { return false }

        self.stream.primeWindow(bytes)
        self.state = .data
        return true
    }

    /// The window's worth of output a decoder would need to carry on from here.
    public var dictionary: [UInt8] {
        self.stream.dictionary
    }

    public func prime(_ value: UInt32, bits count: Int) -> Bool {
        self.stream.prime(value, bits: count)
    }

    /// The DEFLATE stream under the framing, for the few operations that work on it directly —
    /// resynchronising after damage, and asking where it sits between blocks.
    public var rawStream: Inflate {
        self.stream
    }

    /// Whether the trailer is checked. On by default, and off only because the reference lets a
    /// caller turn it off: a stream recovered from a damaged file may be worth reading even
    /// though nothing can vouch for it.
    public var validatesChecksum = true

    /// An independent copy, sharing nothing.
    public func copy() -> Decompressor {
        let clone = Decompressor(maximumWindowBits: self.maximumWindowBits)

        clone.state = self.state
        clone.stream = self.stream.copy()
        clone.checksumState = self.checksumState
        clone.isFinished = self.isFinished
        clone.dictionaryId = self.dictionaryId
        clone.validatesChecksum = self.validatesChecksum

        return clone
    }

    public var needsInput: Bool {
        self.stream.needsInput
    }

    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.stream.setInput(bytes)
    }

    /// The Adler-32 of everything produced so far.
    public var checksum: UInt32 {
        self.checksumState.value
    }

    /// How many bytes of the buffer last handed to ``setInput(_:)`` this stream has taken —
    /// see ``LZ77/Inflate/pulledInputCount``, whose exactness this inherits.
    public var pulledInputCount: Int {
        self.stream.pulledInputCount
    }

    /// Decompresses into `destination`, returning how many bytes were produced.
    public func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(DeflateError) -> Int {
        var produced = 0

        // Recorded on the way out however this returns, so a stream that fails partway can
        // still say how much of the caller's buffer it filled before it did.
        defer { self.producedInLastCall = produced }

        loop: while true {
            switch self.state {
            case .header:
                guard let raw = self.stream.readBits(16) else { break loop }
                try self.checkHeader(raw)

                // §2.2: bit 5 of the flags says a preset dictionary was used, and names it in
                // the four bytes that follow.
                self.state = ((raw >> 8) >> 5) & 1 == 1 ? .dictionaryId : .data

            case .dictionaryId:
                guard let raw = self.stream.readBits(32) else { break loop }

                // Most significant byte first, as the trailer is.
                self.dictionaryId =
                    ((raw & 0xFF) << 24)
                    | (((raw >> 8) & 0xFF) << 16)
                    | (((raw >> 16) & 0xFF) << 8)
                    | ((raw >> 24) & 0xFF)

                self.state = .needsDictionary

            case .needsDictionary:
                // Nothing can be decoded until the caller supplies it, and nothing here can
                // decide to carry on without it.
                break loop

            case .data:
                // Called even with no room left, because a stream can still reach its end
                // without producing anything — and a caller decompressing into a zero-length
                // buffer is asking exactly whether it does.
                let made: Int

                do {
                    made = try self.stream.inflate(
                        into: destination + produced,
                        count: count - produced
                    )
                } catch {
                    // The stream below wrote whatever it decoded before it failed, straight
                    // into the caller's buffer. Counting it on the way past is the only chance
                    // to: the error carries a message, not a length.
                    produced += self.stream.producedInLastCall
                    throw error
                }

                if made > 0 {
                    // Checksummed from the caller's buffer rather than as each byte is produced:
                    // the trailer covers the output in full, and folding it in a block at a time
                    // is what keeps Adler-32 a few adds per byte.
                    self.checksumState.update(
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

                guard !self.validatesChecksum || stored == self.checksumState.value else {
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
    /// of the first must name deflate, and the high nibble must not declare a window this
    /// decoder was not asked to provide.
    private func checkHeader(_ raw: UInt32) throws(DeflateError) {
        let cmf = raw & 0xFF
        let flg = (raw >> 8) & 0xFF

        guard (cmf * 256 + flg) % 31 == 0 else {
            throw DeflateError("bad zlib header")
        }

        guard cmf & 0x0F == 8 else {
            throw DeflateError("unsupported compression method")
        }

        // The window as a power of two, less eight. Beyond fifteen is outside the format;
        // beyond what the caller asked for is outside what it allocated, and decoding into a
        // window smaller than the stream reaches back through yields silent rubbish rather
        // than a failure.
        let declared = Int32((cmf >> 4) & 0x0F) + 8

        guard declared <= 15 else {
            throw DeflateError("zlib window size out of range")
        }

        if let maximumWindowBits = self.maximumWindowBits {
            guard declared <= maximumWindowBits else {
                throw DeflateError("zlib window size larger than requested")
            }
        }
    }
}
