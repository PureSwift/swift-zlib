// Inflate.swift - decompressing a raw DEFLATE stream without a C library underneath
//
// Shaped the same as the caller on the other side of this module: compressed bytes go in
// whenever there are some, decompressed bytes come out into whatever buffer and however many
// at a time the caller asks for, and nothing here assumes those line up with each other or with
// a DEFLATE block boundary. That means every point in the format where more input might not be
// there yet — mid Huffman symbol, mid extra-bits field, mid a match copy that filled the
// caller's buffer before it filled the match — has to be resumable, and the state below is
// exactly the set of fields that survive across such a pause.
//
// The algorithm is RFC 1951 and only that: a sequence of blocks, each either stored literally,
// Huffman-coded against the format's fixed table, or Huffman-coded against a table the block
// carries with it. No zlib header, no Adler-32, no gzip member — a stream carrying one of those
// is this one with framing around it, and reading that framing belongs to whichever module owns
// it. ``alignToByte()`` and ``readBits(_:)`` are what such a module reads it *with*, so that a
// wrapper's fields and the DEFLATE data come off one input stream rather than two.
public final class Inflate {
    private enum State {
        case blockHeader
        case storedLength
        case storedCopy
        case dynamicCounts
        case dynamicCodeLengthLengths
        case dynamicLengths
        case dynamicLengthExtra
        case blockData
        case matchExtraLength
        case matchDistanceSymbol
        case matchExtraDistance
        case matchCopy
        case done
    }

    private var state: State = .blockHeader
    private var reader = BitReader()

    /// The last 32 KiB produced, which is as far back a match is ever asked to reach. Circular:
    /// `windowPosition` is where the next byte goes, wrapping at the end.
    private var window = [UInt8](repeating: 0, count: DeflateTables.windowSize)
    private var windowPosition = 0
    private var totalProduced = 0

    /// Whether the current block is the stream's last, read from its header and acted on once
    /// its end-of-block symbol is reached.
    private var isFinalBlock = false

    // -- dynamic block header ------------------------------------------------

    private var literalCount = 0
    private var distanceCount = 0
    private var codeLengthCodeCount = 0
    private var codeLengthLengths = [UInt8](repeating: 0, count: 19)
    private var codeLengthTable: HuffmanTable?

    /// The combined literal/length and distance code lengths a dynamic block declares, decoded
    /// in one pass because the format's repeat codes can copy across the boundary between them.
    private var combinedLengths: [UInt8] = []
    private var combinedLengthsIndex = 0
    private var previousCodeLength: UInt8 = 0

    private var literalTable: HuffmanTable?
    private var distanceTable: HuffmanTable?
    private var symbolPartial = HuffmanTable.Partial()

    // -- stored block ---------------------------------------------------------

    private var storedRemaining = 0

    // -- one literal/length/distance symbol being resolved ---------------------

    private var pendingSymbol: UInt16 = 0
    private var matchLength = 0
    private var matchDistance = 0

    /// A literal already decoded that the caller's buffer had no room for.
    ///
    /// Needed because a symbol has to be decoded before it is known whether it is a literal
    /// wanting a byte of room or the end-of-block marker wanting none, and the decode cannot be
    /// taken back once the bits are consumed.
    private var heldLiteral: UInt8?

    /// Whether the stream has delivered its end marker.
    public internal(set) var isFinished = false

    public init() {}

    public var needsInput: Bool {
        self.reader.needsInput
    }

    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.reader.setInput(bytes)
    }

    // -- reading a wrapper's own framing --------------------------------------
    //
    // A zlib or gzip stream is DEFLATE data with fields before and after it, on the same input.
    // Rather than have the wrapping module buffer input separately and guess how much of it this
    // one consumed — which it cannot know, since a bit reader holds part of a byte — it reads
    // those fields through here, and the question never arises.

    /// Drops whatever is left of the current byte, so the next read starts on a byte boundary.
    ///
    /// Idempotent, which is what lets a wrapper call it every time it re-enters a trailer it
    /// could not finish reading last time.
    public func alignToByte() {
        self.reader.alignToByte()
    }

    /// Reads `count` bits (0...32) from the same input this stream decodes from, low bit first.
    ///
    /// Returns nil, consuming nothing, when that many bits have not arrived — so a wrapper can
    /// retry the identical call once more input has.
    public func readBits(_ count: Int) -> UInt32? {
        self.reader.bits(count)
    }

    // -- accounting for how much input was used --------------------------------

    /// How many bytes of the buffer last handed to ``setInput(_:)`` this stream has taken.
    ///
    /// Exact rather than approximate: nothing here reads ahead past what it needs, so when a
    /// stream reports itself finished, this is the stream's length to the byte and everything
    /// after it is still the caller's. That is what makes concatenated streams work, and what
    /// lets a caller find the data following one embedded in a larger file.
    public var pulledInputCount: Int {
        self.reader.pulledByteCount
    }

    // -- what a caller can set or carry over ------------------------------------

    /// Fills the window with bytes the stream is entitled to refer back to.
    ///
    /// A preset dictionary: text the encoder assumed was already here, so a distance may reach
    /// into it before this stream has produced anything of its own. Only the last window's
    /// worth is kept, the rest being unreachable by any distance.
    public func primeWindow(_ bytes: UnsafeBufferPointer<UInt8>) {
        let start = max(0, bytes.count - DeflateTables.windowSize)

        for index in start ..< bytes.count {
            self.window[self.windowPosition] = bytes[index]
            self.windowPosition = (self.windowPosition + 1) % DeflateTables.windowSize
        }

        // Counted as produced so that distance checking allows reaching into it — which is the
        // whole point of a dictionary — while staying bounded by the window.
        self.totalProduced += bytes.count - start
    }

    /// The most recent window's worth of output, which is what a decoder resuming from here
    /// would need and what `inflateGetDictionary` reports.
    public var dictionary: [UInt8] {
        let available = min(self.totalProduced, DeflateTables.windowSize)
        guard available > 0 else { return [] }

        var bytes = [UInt8](repeating: 0, count: available)
        var position = (self.windowPosition + DeflateTables.windowSize - available)
            % DeflateTables.windowSize

        for index in 0 ..< available {
            bytes[index] = self.window[position]
            position = (position + 1) % DeflateTables.windowSize
        }

        return bytes
    }

    /// Puts bits in front of the stream, for a caller that consumed part of it itself.
    public func prime(_ value: UInt32, bits count: Int) -> Bool {
        self.reader.prime(value, bits: count)
    }

    /// Whether the stream sits exactly at a stored block's length field with no bits consumed.
    ///
    /// Narrower than "between blocks", deliberately: this is the reference's definition, the
    /// spot an empty stored block's header leaves a decoder at, and callers compare against
    /// what the reference answers. At the very start of a stream, or after an ordinary block,
    /// it answers no — there is a boundary there, but not a stored block's.
    public var isAtSyncPoint: Bool {
        self.state == .storedLength && self.reader.isByteAligned
    }

    /// Restarts block decoding from the current position, throwing away whatever partial state
    /// the stream was in. For resynchronising after damage, where the alternative is to stop.
    public func resumeAtBlockBoundary() {
        self.state = .blockHeader
        self.symbolPartial = HuffmanTable.Partial()
        self.heldLiteral = nil
        self.isFinalBlock = false
        self.isFinished = false
    }

    /// Reads one byte, for a caller scanning the input itself.
    public func readByte() -> UInt8? {
        self.reader.bits(8).map { UInt8(truncatingIfNeeded: $0) }
    }

    /// An independent copy, sharing nothing.
    public func copy() -> Inflate {
        let clone = Inflate()

        clone.state = self.state
        clone.reader = self.reader
        clone.window = self.window
        clone.windowPosition = self.windowPosition
        clone.totalProduced = self.totalProduced
        clone.isFinalBlock = self.isFinalBlock
        clone.literalCount = self.literalCount
        clone.distanceCount = self.distanceCount
        clone.codeLengthCodeCount = self.codeLengthCodeCount
        clone.codeLengthLengths = self.codeLengthLengths
        clone.codeLengthTable = self.codeLengthTable
        clone.combinedLengths = self.combinedLengths
        clone.combinedLengthsIndex = self.combinedLengthsIndex
        clone.previousCodeLength = self.previousCodeLength
        clone.literalTable = self.literalTable
        clone.distanceTable = self.distanceTable
        clone.symbolPartial = self.symbolPartial
        clone.storedRemaining = self.storedRemaining
        clone.pendingSymbol = self.pendingSymbol
        clone.matchLength = self.matchLength
        clone.matchDistance = self.matchDistance
        clone.heldLiteral = self.heldLiteral
        clone.isFinished = self.isFinished

        return clone
    }

    // -- emitting produced bytes ------------------------------------------------

    /// Where the caller's buffer has been filled to; reset at the start of every call and
    /// advanced by `emit` as bytes are produced.
    private var destination: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>(
        bitPattern: 1
    )!
    private var destinationCapacity = 0
    private var destinationCount = 0

    /// How many bytes the last call wrote, whether it returned or threw.
    ///
    /// Needed because a stream that fails partway has still produced everything up to the
    /// point it failed, and those bytes are in the caller's buffer. Losing the count with the
    /// error would leave them there unclaimed — which is not merely wasteful: a caller
    /// recovering from damage wants exactly the part that decoded.
    public var producedInLastCall: Int {
        self.destinationCount
    }

    private var destinationFull: Bool {
        self.destinationCount >= self.destinationCapacity
    }

    /// Writes one produced byte to both the caller's buffer and this stream's own window, which
    /// is the only history a later match can read back through — the caller's buffers are not
    /// assumed to stay valid or stay adjacent to each other.
    private func emit(_ byte: UInt8) {
        self.destination[self.destinationCount] = byte
        self.destinationCount += 1

        self.window[self.windowPosition] = byte
        self.windowPosition = (self.windowPosition + 1) % DeflateTables.windowSize
        self.totalProduced += 1
    }

    /// Decompresses into `destination`, returning how many bytes were produced.
    ///
    /// A result smaller than `count` means the stream needs more input, has filled the window
    /// past what fit here, or has ended — the caller distinguishes those with ``needsInput`` and
    /// ``isFinished``, exactly as it would with the system decompressor this stands in for.
    ///
    /// Stops as soon as the final block's end-of-block symbol is read, leaving anything after it
    /// unconsumed for a wrapper to read as its trailer.
    public func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(DeflateError) -> Int {
        self.destination = destination
        self.destinationCapacity = count
        self.destinationCount = 0

        // Deliberately not stopping on a full destination: the states that produce bytes report
        // for themselves when they are blocked on room, and the ones that do not — a block
        // header, a dynamic table, the end of the stream — can still finish without any. A
        // stream whose remaining output is nothing at all reaches `done` on a zero-length
        // buffer, which is what a caller decompressing into an empty result depends on.
        while self.state != .done {
            guard try self.step() else { break }
        }

        return self.destinationCount
    }

    /// Advances the state machine by as much as it can with what is currently buffered.
    ///
    /// Returns false when nothing more can happen right now — either the input has run out or
    /// the destination has — so the caller's loop above knows to stop rather than spin.
    private func step() throws(DeflateError) -> Bool {
        switch self.state {
        case .blockHeader:
            // Read as one field: two separate reads would each be atomic on their own, but
            // input running out between them would leave BFINAL consumed with BTYPE
            // unavailable, and nowhere to remember that it already happened.
            guard let raw = self.reader.bits(3) else { return false }

            let final = raw & 1
            let type = (raw >> 1) & 0b11

            self.isFinalBlock = final == 1

            switch type {
            case 0:
                self.reader.alignToByte()
                self.state = .storedLength

            case 1:
                self.literalTable = try HuffmanTable(lengths: DeflateTables.fixedLiteralLengths)
                self.distanceTable = try HuffmanTable(lengths: DeflateTables.fixedDistanceLengths)
                self.symbolPartial = HuffmanTable.Partial()
                self.state = .blockData

            case 2:
                self.state = .dynamicCounts

            default:
                throw DeflateError("reserved block type")
            }

            return true

        case .storedLength:
            guard let raw = self.reader.bits(32) else { return false }

            let length = Int(raw & 0xFFFF)
            let complement = Int((raw >> 16) & 0xFFFF)

            guard length == (complement ^ 0xFFFF) else {
                throw DeflateError("stored block length check failed")
            }

            self.storedRemaining = length
            self.state = .storedCopy
            return true

        case .storedCopy:
            while self.storedRemaining > 0, !self.destinationFull {
                guard let byte = self.reader.bits(8) else { return false }

                self.emit(UInt8(truncatingIfNeeded: byte))
                self.storedRemaining -= 1
            }

            guard self.storedRemaining == 0 else {
                // Still bytes to copy, so the loop above ended on a full destination.
                return false
            }

            self.endBlock()
            return true

        case .dynamicCounts:
            // One field, again for the same resumability reason.
            guard let raw = self.reader.bits(14) else { return false }

            let hlit = raw & 0x1F
            let hdist = (raw >> 5) & 0x1F
            let hclen = (raw >> 10) & 0xF

            self.literalCount = Int(hlit) + 257
            self.distanceCount = Int(hdist) + 1
            self.codeLengthCodeCount = Int(hclen) + 4
            self.codeLengthLengths = [UInt8](repeating: 0, count: 19)
            self.combinedLengthsIndex = 0
            self.state = .dynamicCodeLengthLengths
            return true

        case .dynamicCodeLengthLengths:
            while self.combinedLengthsIndex < self.codeLengthCodeCount {
                guard let bits = self.reader.bits(3) else { return false }

                let position = DeflateTables.codeLengthOrder[self.combinedLengthsIndex]
                self.codeLengthLengths[position] = UInt8(bits)
                self.combinedLengthsIndex += 1
            }

            self.codeLengthTable = try HuffmanTable(lengths: self.codeLengthLengths)
            self.combinedLengths = [UInt8](
                repeating: 0,
                count: self.literalCount + self.distanceCount
            )
            self.combinedLengthsIndex = 0
            self.previousCodeLength = 0
            self.symbolPartial = HuffmanTable.Partial()
            self.state = .dynamicLengths
            return true

        case .dynamicLengths:
            guard let table = self.codeLengthTable else {
                throw DeflateError("internal: no code-length table")
            }

            while self.combinedLengthsIndex < self.combinedLengths.count {
                switch try table.decode(&self.reader, partial: &self.symbolPartial) {
                case .needsInput:
                    return false

                case let .symbol(symbol):
                    switch symbol {
                    case 0 ... 15:
                        self.combinedLengths[self.combinedLengthsIndex] = UInt8(symbol)
                        self.previousCodeLength = UInt8(symbol)
                        self.combinedLengthsIndex += 1

                    case 16, 17, 18:
                        // The symbol is fully decoded and `symbolPartial` already reset; what
                        // is left is its extra-bits field, which is its own resumable step so
                        // that running out of input here does not re-decode the symbol.
                        self.pendingSymbol = symbol
                        self.state = .dynamicLengthExtra
                        return true

                    default:
                        throw DeflateError("invalid code-length symbol")
                    }
                }
            }

            // These two alphabets may be §3.2.7's permitted single one-bit code; the
            // code-length alphabet built above may not, and is checked without the exemption.
            self.literalTable = try HuffmanTable(
                lengths: Array(self.combinedLengths[0 ..< self.literalCount]),
                allowingIncomplete: true
            )
            self.distanceTable = try HuffmanTable(
                lengths: Array(self.combinedLengths[self.literalCount...]),
                allowingIncomplete: true
            )
            self.symbolPartial = HuffmanTable.Partial()
            self.state = .blockData
            return true

        case .dynamicLengthExtra:
            switch self.pendingSymbol {
            case 16:
                guard let extra = self.reader.bits(2) else { return false }
                try self.repeatPreviousLength(count: 3 + Int(extra))

            case 17:
                guard let extra = self.reader.bits(3) else { return false }
                try self.fillZeroLength(count: 3 + Int(extra))

            case 18:
                guard let extra = self.reader.bits(7) else { return false }
                try self.fillZeroLength(count: 11 + Int(extra))

            default:
                throw DeflateError("internal: unexpected pending code-length symbol")
            }

            self.state = .dynamicLengths
            return true

        case .blockData:
            guard let table = self.literalTable else {
                throw DeflateError("internal: no literal table")
            }

            while true {
                // A literal decoded when there was nowhere to put it. Placing it before
                // reading anything else is what keeps the stream in order.
                if let literal = self.heldLiteral {
                    guard !self.destinationFull else { return false }

                    self.emit(literal)
                    self.heldLiteral = nil
                    continue
                }

                switch try table.decode(&self.reader, partial: &self.symbolPartial) {
                case .needsInput:
                    return false

                case let .symbol(symbol):
                    if symbol < 256 {
                        // Decoded before the room for it was checked, deliberately: the symbol
                        // might have been end-of-block, and a stream whose last block is empty
                        // has to be able to end on a destination with no room left at all.
                        guard !self.destinationFull else {
                            self.heldLiteral = UInt8(symbol)
                            return false
                        }

                        self.emit(UInt8(symbol))
                        continue
                    }

                    if symbol == DeflateTables.endOfBlock {
                        self.endBlock()
                        return true
                    }

                    guard symbol <= 285 else {
                        throw DeflateError("invalid length symbol")
                    }

                    self.pendingSymbol = symbol
                    self.state = .matchExtraLength
                    return true
                }
            }

        case .matchExtraLength:
            let index = Int(self.pendingSymbol) - 257
            let extraBits = DeflateTables.lengthExtraBits[index]

            guard let extra = self.reader.bits(extraBits) else { return false }

            self.matchLength = DeflateTables.lengthBase[index] + Int(extra)
            self.state = .matchDistanceSymbol
            return true

        case .matchDistanceSymbol:
            guard let table = self.distanceTable else {
                throw DeflateError("internal: no distance table")
            }

            switch try table.decode(&self.reader, partial: &self.symbolPartial) {
            case .needsInput:
                return false

            case let .symbol(symbol):
                guard symbol <= 29 else {
                    throw DeflateError("invalid distance symbol")
                }

                self.pendingSymbol = symbol
                self.state = .matchExtraDistance
                return true
            }

        case .matchExtraDistance:
            let index = Int(self.pendingSymbol)
            let extraBits = DeflateTables.distanceExtraBits[index]

            guard let extra = self.reader.bits(extraBits) else { return false }

            self.matchDistance = DeflateTables.distanceBase[index] + Int(extra)

            guard self.matchDistance >= 1,
                  self.matchDistance <= min(DeflateTables.windowSize, self.totalProduced)
            else {
                throw DeflateError("match distance reaches before the start of the stream")
            }

            self.symbolPartial = HuffmanTable.Partial()
            self.state = .matchCopy
            return true

        case .matchCopy:
            while self.matchLength > 0, !self.destinationFull {
                let sourceIndex =
                    (self.windowPosition + DeflateTables.windowSize - self.matchDistance)
                        % DeflateTables.windowSize

                self.emit(self.window[sourceIndex])
                self.matchLength -= 1
            }

            guard self.matchLength == 0 else {
                // Match unfinished, so the loop above ended on a full destination.
                return false
            }

            self.state = .blockData
            return true

        case .done:
            return false
        }
    }

    /// Ends the block just completed, and the stream with it if that block declared itself last.
    ///
    /// Nothing is read past the end-of-block symbol: whatever follows is either the next block's
    /// header, which the next step reads, or a wrapper's trailer, which is not this module's to
    /// interpret.
    private func endBlock() {
        guard self.isFinalBlock else {
            self.state = .blockHeader
            return
        }

        self.state = .done
        self.isFinished = true
    }

    /// The two repeat codes in the code-length alphabet: 16 copies the previous length again,
    /// 17 and 18 insert runs of zero — three different symbols for what is, underneath, the same
    /// "extend the array by `count` entries" operation.
    private func repeatPreviousLength(count: Int) throws(DeflateError) {
        guard self.combinedLengthsIndex > 0 else {
            throw DeflateError("repeat code with nothing to repeat")
        }

        try self.fill(self.previousCodeLength, count: count)
    }

    private func fillZeroLength(count: Int) throws(DeflateError) {
        try self.fill(0, count: count)
        self.previousCodeLength = 0
    }

    private func fill(_ value: UInt8, count: Int) throws(DeflateError) {
        guard self.combinedLengthsIndex + count <= self.combinedLengths.count else {
            throw DeflateError("code-length repeat runs past the table")
        }

        for _ in 0 ..< count {
            self.combinedLengths[self.combinedLengthsIndex] = value
            self.combinedLengthsIndex += 1
        }
    }
}
