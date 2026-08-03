// Decompressor.swift - reading RFC 1952 framing off a DEFLATE stream
//
// Harder than writing it, and harder than the zlib side, for one reason: the header is not a
// fixed ten bytes. Four optional fields may follow it, two of them variable length and
// terminated rather than counted, and any of them may be split across however many bytes the
// caller happened to supply. So every field is its own resumable step, and the state below is
// exactly what has to survive running out of input in the middle of one.
//
// Like the zlib wrapper, this reads its fields *through* the `LZ77` stream rather than buffering
// input of its own, so there is never a question of who consumed what.

import LZ77

public final class Decompressor {
    private enum State {
        /// The ten bytes every member starts with.
        case fixedHeader
        /// §2.3.1.1: two bytes of length, then that many bytes, both skipped.
        case extraLength
        case extraField
        /// Zero-terminated, so read until the terminator rather than to a count.
        case fileName
        case comment
        /// A CRC-16 over the header, present only if the flags say so.
        case headerChecksum
        case data
        case trailerChecksum
        case trailerLength
        case done
    }

    private var state: State = .fixedHeader
    private var stream = Inflate()

    private var checksumState = Crc32()

    /// The CRC-32 of the header itself, which the optional header checksum covers. Kept
    /// separately from the payload's, which it has nothing to do with.
    private var headerChecksumState = Crc32()

    /// Bytes of the field being read, and how many it needs. A field half-read when the input
    /// ran out is resumed rather than restarted, which is what makes any chunking work.
    private var field: [UInt8] = []
    private var fieldLength = 0

    private var flags: UInt8 = 0
    private var producedLength: UInt32 = 0

    /// What the member said about itself, once enough of the header has been read to know.
    ///
    /// Kept rather than skipped because callers want it — the name is what a decompressing
    /// tool calls the file it writes. Complete only when ``headerIsComplete``: the fields
    /// arrive one after another, and a caller reading it too early sees half a header.
    public private(set) var header = Header()

    /// Whether the whole header has been read, optional fields included.
    public private(set) var headerIsComplete = false

    public private(set) var isFinished = false

    public init() {}

    public var needsInput: Bool {
        self.stream.needsInput
    }

    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.stream.setInput(bytes)
    }

    /// The CRC-32 of everything produced so far.
    public var checksum: UInt32 {
        self.checksumState.checksum
    }

    public var pulledInputCount: Int {
        self.stream.pulledInputCount
    }

    /// The DEFLATE stream under the framing, for operations that work on it directly.
    public var rawStream: Inflate {
        self.stream
    }

    /// Whether the trailer's checksum and length are checked.
    public var validatesChecksum = true

    /// The window's worth of output a decoder would need to carry on from here.
    public var dictionary: [UInt8] {
        self.stream.dictionary
    }

    public func prime(_ value: UInt32, bits count: Int) -> Bool {
        self.stream.prime(value, bits: count)
    }

    /// An independent copy, sharing nothing.
    public func copy() -> Decompressor {
        let clone = Decompressor()

        clone.state = self.state
        clone.stream = self.stream.copy()
        clone.checksumState = self.checksumState
        clone.headerChecksumState = self.headerChecksumState
        clone.field = self.field
        clone.fieldLength = self.fieldLength
        clone.flags = self.flags
        clone.producedLength = self.producedLength
        clone.header = self.header
        clone.headerIsComplete = self.headerIsComplete
        clone.isFinished = self.isFinished
        clone.validatesChecksum = self.validatesChecksum

        return clone
    }

    public func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(DeflateError) -> Int {
        var produced = 0

        loop: while true {
            switch self.state {
            case .fixedHeader:
                guard try self.collect(10) else { break loop }
                try self.parseFixedHeader()

            case .extraLength:
                guard try self.collect(2) else { break loop }
                self.fieldLength = Int(self.field[0]) | (Int(self.field[1]) << 8)
                self.field = []
                self.state = self.fieldLength > 0 ? .extraField : self.afterExtra()

            case .extraField:
                guard try self.collect(self.fieldLength) else { break loop }
                self.header.extra = self.field
                self.field = []
                self.state = self.afterExtra()

            case .fileName:
                guard try self.collectUntilTerminator() else { break loop }
                self.header.fileName = self.field
                self.field = []
                self.state = self.afterName()

            case .comment:
                guard try self.collectUntilTerminator() else { break loop }
                self.header.comment = self.field
                self.field = []
                self.state = self.afterComment()

            case .headerChecksum:
                guard try self.collect(2, checksummingHeader: false) else { break loop }

                let stored = UInt16(self.field[0]) | (UInt16(self.field[1]) << 8)
                self.field = []

                guard stored == UInt16(truncatingIfNeeded: self.headerChecksumState.checksum)
                else {
                    throw DeflateError("gzip header checksum mismatch")
                }

                self.headerIsComplete = true
                self.state = .data

            case .data:
                let made = try self.stream.inflate(
                    into: destination + produced,
                    count: count - produced
                )

                if made > 0 {
                    self.checksumState.update(
                        UnsafeBufferPointer(start: destination + produced, count: made)
                    )
                    self.producedLength &+= UInt32(truncatingIfNeeded: made)
                    produced += made
                }

                if self.stream.isFinished {
                    self.state = .trailerChecksum
                    continue
                }

                if made == 0 { break loop }

            case .trailerChecksum:
                // The DEFLATE data ends wherever its last code did; the trailer after it is
                // byte-aligned. Aligning is idempotent, which matters because this state is
                // re-entered every time the four bytes have not all arrived.
                self.stream.alignToByte()

                guard let raw = self.stream.readBits(32) else { break loop }

                // Least significant byte first, which is the order `readBits` already assembles
                // — the opposite of zlib's trailer, which had to be reversed.
                guard !self.validatesChecksum || raw == self.checksumState.checksum else {
                    throw DeflateError("gzip CRC-32 mismatch")
                }

                self.state = .trailerLength

            case .trailerLength:
                guard let raw = self.stream.readBits(32) else { break loop }

                // §2.3.1: the original length modulo 2³². A member whose checksum matches but
                // whose length does not is one that decoded to the right bytes and the wrong
                // number of them, which no checksum alone would catch.
                guard !self.validatesChecksum || raw == self.producedLength else {
                    throw DeflateError("gzip length mismatch")
                }

                self.state = .done
                self.isFinished = true

            case .done:
                break loop
            }
        }

        return produced
    }

    // -- reading header fields ----------------------------------------------------

    /// Collects `count` bytes into ``field``, resuming where a previous call left off.
    ///
    /// Returns false when the input ran out, having kept whatever did arrive.
    private func collect(
        _ count: Int,
        checksummingHeader: Bool = true
    ) throws(DeflateError) -> Bool {
        while self.field.count < count {
            guard let value = self.stream.readBits(8) else { return false }

            let byte = UInt8(truncatingIfNeeded: value)
            self.field.append(byte)

            // The header checksum covers the header up to but not including itself.
            if checksummingHeader {
                self.headerChecksumState.update(byte)
            }
        }

        return true
    }

    /// Reads into ``field`` up to a zero, which is how §2.3.1.1 ends the name and comment
    /// fields. The terminator is consumed and not kept.
    private func collectUntilTerminator() throws(DeflateError) -> Bool {
        while true {
            guard let value = self.stream.readBits(8) else { return false }

            let byte = UInt8(truncatingIfNeeded: value)
            self.headerChecksumState.update(byte)

            if byte == 0 { return true }

            self.field.append(byte)
        }
    }

    private func parseFixedHeader() throws(DeflateError) {
        guard self.field[0] == 0x1F, self.field[1] == 0x8B else {
            throw DeflateError("not a gzip member")
        }

        guard self.field[2] == 8 else {
            throw DeflateError("unsupported compression method")
        }

        self.flags = self.field[3]

        self.header.isText = self.flags & 0x01 != 0
        self.header.hasHeaderChecksum = self.flags & 0x02 != 0
        self.header.modificationTime =
            UInt32(self.field[4])
            | (UInt32(self.field[5]) << 8)
            | (UInt32(self.field[6]) << 16)
            | (UInt32(self.field[7]) << 24)
        self.header.extraFlags = self.field[8]
        self.header.operatingSystem = self.field[9]

        self.field = []

        guard self.flags & 0xE0 == 0 else {
            // §2.3.1.2 reserves the top three bits and requires a decoder to refuse a member
            // that sets them, rather than guess what they were meant to mean.
            throw DeflateError("reserved gzip flags are set")
        }

        if self.flags & 0x04 != 0 {
            self.state = .extraLength
        } else {
            self.state = self.afterExtra()
        }
    }

    // §2.3.1.1 fixes the order of the optional fields: extra, name, comment, header checksum.
    // Each of these answers "what comes after the one just finished", so the order lives in one
    // chain rather than in a condition at each of the four places a field can end.

    private func afterExtra() -> State {
        self.flags & 0x08 != 0 ? .fileName : self.afterName()
    }

    private func afterName() -> State {
        self.flags & 0x10 != 0 ? .comment : self.afterComment()
    }

    private func afterComment() -> State {
        guard self.flags & 0x02 == 0 else { return .headerChecksum }

        self.headerIsComplete = true
        return .data
    }
}
