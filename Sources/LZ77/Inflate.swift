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
// The state lives in a noncopyable struct and the public class is a box around it, and the
// split is not cosmetic: it is where a third of the decoder's running time went. A mutating
// access to a struct stored in a class — every `&self.reader`, every write to a counter — is
// dynamically checked for exclusivity, once per symbol. The same mutation through `inout self`
// of a struct is checked statically, at compile time, for free. So the box pays one dynamic
// access per public call, and the hot loops inside pay none.
//
// ~Copyable because the struct owns raw memory: the window is freed in deinit, and a copy that
// duplicated the pointer would free it twice. Duplication is explicit, via ``copied()``.
struct InflateCore: ~Copyable {
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
    ///
    /// Held as raw memory rather than an `Array` because every decoded byte is written here, and
    /// a Swift array checks on each write whether its storage is uniquely referenced. That check
    /// is worth paying where it buys safety; in a buffer this type allocates, owns, never shares
    /// and never resizes, it buys nothing and costs a branch per byte.
    private let window: UnsafeMutablePointer<UInt8>
    private var windowPosition = 0
    private var totalProduced = 0

    /// The packed decode tables the fast path indexes: the literal/length table at offset
    /// zero, the distance table at ``DecodeTable/enoughLengths``. Rebuilt for every block that
    /// reaches `blockData`; `packedValid` is false in the states between.
    ///
    /// A second representation of the same codes the `HuffmanTable`s hold, kept in parallel on
    /// purpose: the careful path can pause mid-symbol and the packed one cannot, so each path
    /// keeps the shape it needs and the block-header cost of building both is noise against
    /// decoding even a small block.
    private let packed: UnsafeMutablePointer<UInt32>
    private var packedLiteralRoot = 0
    private var packedDistanceRoot = 0
    private var packedValid = false

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
    private(set) var isFinished = false

    init() {
        self.window = .allocate(capacity: DeflateTables.windowSize)
        self.window.initialize(repeating: 0, count: DeflateTables.windowSize)

        let packedCapacity = DecodeTable.enoughLengths + DecodeTable.enoughDistances
        self.packed = .allocate(capacity: packedCapacity)
        self.packed.initialize(repeating: 0, count: packedCapacity)
    }

    deinit {
        self.window.deallocate()
        self.packed.deallocate()
    }

    var needsInput: Bool {
        self.reader.needsInput
    }

    mutating func setInput(_ bytes: UnsafeBufferPointer<UInt8>) {
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
    mutating func alignToByte() {
        self.reader.alignToByte()
    }

    /// Reads `count` bits (0...32) from the same input this stream decodes from, low bit first.
    ///
    /// Returns nil, consuming nothing, when that many bits have not arrived — so a wrapper can
    /// retry the identical call once more input has.
    mutating func readBits(_ count: Int) -> UInt32? {
        self.reader.bits(count)
    }

    // -- accounting for how much input was used --------------------------------

    /// How many bytes of the buffer last handed to ``setInput(_:)`` this stream has taken.
    ///
    /// Exact rather than approximate: nothing here reads ahead past what it needs, so when a
    /// stream reports itself finished, this is the stream's length to the byte and everything
    /// after it is still the caller's. That is what makes concatenated streams work, and what
    /// lets a caller find the data following one embedded in a larger file.
    var pulledInputCount: Int {
        self.reader.pulledByteCount
    }

    // -- what a caller can set or carry over ------------------------------------

    /// Fills the window with bytes the stream is entitled to refer back to.
    ///
    /// A preset dictionary: text the encoder assumed was already here, so a distance may reach
    /// into it before this stream has produced anything of its own. Only the last window's
    /// worth is kept, the rest being unreachable by any distance.
    mutating func primeWindow(_ bytes: UnsafeBufferPointer<UInt8>) {
        let start = max(0, bytes.count - DeflateTables.windowSize)

        for index in start ..< bytes.count {
            self.window[self.windowPosition] = bytes[index]
            self.windowPosition = (self.windowPosition &+ 1) & DeflateTables.windowMask
        }

        // Counted as produced so that distance checking allows reaching into it — which is the
        // whole point of a dictionary — while staying bounded by the window.
        self.totalProduced += bytes.count - start
    }

    /// The most recent window's worth of output, which is what a decoder resuming from here
    /// would need and what `inflateGetDictionary` reports.
    var dictionary: [UInt8] {
        let available = min(self.totalProduced, DeflateTables.windowSize)
        guard available > 0 else { return [] }

        var bytes = [UInt8](repeating: 0, count: available)
        var position = (self.windowPosition &+ DeflateTables.windowSize &- available)
            & DeflateTables.windowMask

        for index in 0 ..< available {
            bytes[index] = self.window[position]
            position = (position &+ 1) & DeflateTables.windowMask
        }

        return bytes
    }

    /// Puts bits in front of the stream, for a caller that consumed part of it itself.
    mutating func prime(_ value: UInt32, bits count: Int) -> Bool {
        self.reader.prime(value, bits: count)
    }

    /// Whether the stream sits exactly at a stored block's length field with no bits consumed.
    ///
    /// Narrower than "between blocks", deliberately: this is the reference's definition, the
    /// spot an empty stored block's header leaves a decoder at, and callers compare against
    /// what the reference answers. At the very start of a stream, or after an ordinary block,
    /// it answers no — there is a boundary there, but not a stored block's.
    var isAtSyncPoint: Bool {
        self.state == .storedLength && self.reader.isByteAligned
    }

    /// Restarts block decoding from the current position, throwing away whatever partial state
    /// the stream was in. For resynchronising after damage, where the alternative is to stop.
    mutating func resumeAtBlockBoundary() {
        self.state = .blockHeader
        self.symbolPartial = HuffmanTable.Partial()
        self.heldLiteral = nil
        self.isFinalBlock = false
        self.isFinished = false
    }

    /// Reads one byte, for a caller scanning the input itself.
    mutating func readByte() -> UInt8? {
        self.reader.bits(8).map { UInt8(truncatingIfNeeded: $0) }
    }

    /// An explicit duplicate, sharing nothing — the operation ~Copyable exists to make visible.
    borrowing func copied() -> InflateCore {
        var clone = InflateCore()

        clone.state = self.state
        clone.reader = self.reader

        // Copied rather than shared: the whole point of a copy is that writing through one
        // handle cannot be seen through the other.
        clone.window.update(from: self.window, count: DeflateTables.windowSize)
        clone.packed.update(
            from: self.packed,
            count: DecodeTable.enoughLengths + DecodeTable.enoughDistances
        )
        clone.packedLiteralRoot = self.packedLiteralRoot
        clone.packedDistanceRoot = self.packedDistanceRoot
        clone.packedValid = self.packedValid
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
        clone.setFinished(self.isFinished)

        return clone
    }

    /// For ``copied()`` and the box, `isFinished` being settable only from inside this file.
    mutating func setFinished(_ value: Bool) {
        self.isFinished = value
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
    var producedInLastCall: Int {
        self.destinationCount
    }

    private var destinationFull: Bool {
        self.destinationCount >= self.destinationCapacity
    }

    /// Writes one produced byte to both the caller's buffer and this stream's own window, which
    /// is the only history a later match can read back through — the caller's buffers are not
    /// assumed to stay valid or stay adjacent to each other.
    private mutating func emit(_ byte: UInt8) {
        self.destination[self.destinationCount] = byte
        self.destinationCount += 1

        self.window[self.windowPosition] = byte
        self.windowPosition = (self.windowPosition &+ 1) & DeflateTables.windowMask
        self.totalProduced &+= 1
    }

    /// Decompresses into `destination`, returning how many bytes were produced.
    ///
    /// A result smaller than `count` means the stream needs more input, has filled the window
    /// past what fit here, or has ended — the caller distinguishes those with ``needsInput`` and
    /// ``isFinished``, exactly as it would with the system decompressor this stands in for.
    ///
    /// Stops as soon as the final block's end-of-block symbol is read, leaving anything after it
    /// unconsumed for a wrapper to read as its trailer.
    mutating func inflate(
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
    private mutating func step() throws(DeflateError) -> Bool {
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
                self.buildPackedTables(
                    literalLengths: DeflateTables.fixedLiteralLengths,
                    distanceLengths: DeflateTables.fixedDistanceLengths
                )
                self.symbolPartial = HuffmanTable.Partial()
                self.state = .blockData

            case 2:
                self.state = .dynamicCounts

            default:
                throw DeflateError("invalid block type")
            }

            return true

        case .storedLength:
            guard let raw = self.reader.bits(32) else { return false }

            let length = Int(raw & 0xFFFF)
            let complement = Int((raw >> 16) & 0xFFFF)

            guard length == (complement ^ 0xFFFF) else {
                throw DeflateError("invalid stored block lengths")
            }

            self.storedRemaining = length
            self.state = .storedCopy
            return true

        case .storedCopy:
            // Stored data is not bit-packed, so when the reader sits on a byte boundary — which
            // the header's alignment guarantees, unless a caller primed odd bits underneath it —
            // the block moves as bulk copies: input to destination in one, destination into the
            // window in another.
            if self.reader.isByteAligned {
                while self.storedRemaining > 0, !self.destinationFull {
                    let want = min(
                        self.storedRemaining,
                        self.destinationCapacity - self.destinationCount
                    )
                    let got = self.reader.copyAlignedBytes(
                        into: self.destination + self.destinationCount,
                        count: want
                    )

                    guard got > 0 else { return false }

                    self.syncWindow(from: self.destination + self.destinationCount, count: got)
                    self.totalProduced &+= got
                    self.destinationCount += got
                    self.storedRemaining -= got
                }
            } else {
                while self.storedRemaining > 0, !self.destinationFull {
                    guard let byte = self.reader.bits(8) else { return false }

                    self.emit(UInt8(truncatingIfNeeded: byte))
                    self.storedRemaining -= 1
                }
            }

            guard self.storedRemaining == 0 else {
                // Still bytes to copy, so the loops above ended on a full destination.
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
            let literalLengths = Array(self.combinedLengths[0 ..< self.literalCount])
            let distanceLengths = Array(self.combinedLengths[self.literalCount...])

            self.literalTable = try HuffmanTable(
                lengths: literalLengths,
                allowingIncomplete: true
            )
            self.distanceTable = try HuffmanTable(
                lengths: distanceLengths,
                allowingIncomplete: true
            )
            self.buildPackedTables(
                literalLengths: literalLengths,
                distanceLengths: distanceLengths
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

            // The fast path handles whole symbols only, so anything held over from a previous
            // call — a parked literal, a part-read code — is settled by the careful loop below
            // before it can run. It pauses only at symbol boundaries, which is exactly where
            // the careful loop knows how to continue.
            if self.packedValid, self.heldLiteral == nil, self.symbolPartial.length == 0 {
                switch self.inflateFast() {
                case .endOfBlock:
                    self.endBlock()
                    return true
                case .invalidLengthSymbol:
                    throw DeflateError("invalid literal/length code")
                case .invalidDistanceSymbol:
                    throw DeflateError("invalid distance code")
                case .distanceTooFar:
                    throw DeflateError("invalid distance too far back")
                case .paused:
                    break
                }
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
                        throw DeflateError("invalid literal/length code")
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
                    throw DeflateError("invalid distance code")
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
                throw DeflateError("invalid distance too far back")
            }

            self.symbolPartial = HuffmanTable.Partial()
            self.state = .matchCopy
            return true

        case .matchCopy:
            // The inner loop of the whole decoder: every byte of every match passes through it.
            // Written against local copies and an unsafe view of the window so that each byte
            // costs a load, a store and a mask, rather than that plus a bounds check and a
            // reload of four properties through the class.
            var position = self.windowPosition
            var produced = self.destinationCount
            var remaining = self.matchLength

            let capacity = self.destinationCapacity
            let distance = self.matchDistance
            let destination = self.destination
            let mask = DeflateTables.windowMask

            let window = self.window

            while remaining > 0, produced < capacity {
                let byte = window[(position &+ DeflateTables.windowSize &- distance) & mask]

                destination[produced] = byte
                window[position] = byte

                position = (position &+ 1) & mask
                produced &+= 1
                remaining &-= 1
            }

            // However many the loop managed, which is what the match had left less what it has
            // left now.
            self.totalProduced &+= self.matchLength &- remaining

            self.windowPosition = position
            self.destinationCount = produced
            self.matchLength = remaining

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

    // -- the fast path ----------------------------------------------------------

    private mutating func buildPackedTables(literalLengths: [UInt8], distanceLengths: [UInt8]) {
        let literal = DecodeTable.build(
            .literals,
            lengths: literalLengths,
            into: self.packed,
            capacity: DecodeTable.enoughLengths
        )
        let distance = DecodeTable.build(
            .distances,
            lengths: distanceLengths,
            into: self.packed + DecodeTable.enoughLengths,
            capacity: DecodeTable.enoughDistances
        )

        if let literal, let distance {
            self.packedLiteralRoot = literal.rootBits
            self.packedDistanceRoot = distance.rootBits
            self.packedValid = true
        } else {
            // Cannot happen for lengths the HuffmanTable initializers accepted; if it somehow
            // does, the careful path decodes the block alone and correctness is untouched.
            self.packedValid = false
        }
    }

    /// Folds bytes the fast loop wrote to the destination into the circular window, in at most
    /// two copies — the bulk replacement for the byte-at-a-time bookkeeping `emit` does.
    ///
    /// Only the last window's worth of `count` matters; anything older is unreachable by any
    /// distance and is skipped rather than copied.
    private mutating func syncWindow(from source: UnsafePointer<UInt8>, count: Int) {
        let size = DeflateTables.windowSize
        let mask = DeflateTables.windowMask

        let effective = min(count, size)
        let skipped = count - effective
        var position = (self.windowPosition &+ skipped) & mask
        var copied = 0

        while copied < effective {
            let run = min(effective - copied, size - position)
            (self.window + position).update(from: source + skipped + copied, count: run)
            position = (position &+ run) & mask
            copied += run
        }

        self.windowPosition = (self.windowPosition &+ count) & mask
    }

    private enum FastOutcome {
        case paused
        case endOfBlock
        case invalidLengthSymbol
        case invalidDistanceSymbol
        case distanceTooFar
    }

    /// The reference's `inflate_fast`, in this decoder's terms: while there is enough input
    /// that an eight-byte load cannot run off the end, and enough output room that a maximal
    /// match cannot either, decode whole symbols against the packed tables with every check
    /// hoisted out of the loop.
    ///
    /// Runs on locals and reconciles once, on any exit: whole bytes over-read are handed back
    /// to the reader — restoring the at-most-seven-bit invariant `pulledInputCount` documents —
    /// and everything produced is folded into the window in one bulk copy. Within the run, the
    /// caller's own buffer serves as the history for any match that reaches only into this
    /// call's output, which is most of them; the window is read only for distances reaching
    /// back past the call boundary.
    ///
    /// Never entered mid-symbol and never exits mid-symbol, which is what lets it coexist with
    /// the careful path's resumability: pausing here means "at a symbol boundary, out of
    /// slack", and the careful loop picks up from exactly that boundary.
    private mutating func inflateFast() -> FastOutcome {
        let input = self.reader.rawInput
        guard let inBase = input.baseAddress else { return .paused }

        // 48 bits covers the longest symbol pair (15 + 5 + 15 + 13), so one refill per
        // iteration is enough; 272 of output slack covers a maximal match of 258 plus a wide
        // copy's overshoot.
        let inLimit = input.count - 7
        let outLimit = self.destinationCapacity - 272

        var inOffset = self.reader.rawInputOffset
        var hold = self.reader.rawBuffer
        var bits = self.reader.rawBitCount
        var produced = self.destinationCount

        guard inOffset < inLimit, produced < outLimit else { return .paused }

        let out = self.destination
        let window = self.window
        let mask = DeflateTables.windowMask
        let literalTable = self.packed
        let distanceTable = self.packed + DecodeTable.enoughLengths
        let literalMask = UInt64((1 << self.packedLiteralRoot) - 1)
        let distanceMask = UInt64((1 << self.packedDistanceRoot) - 1)

        let runStart = produced

        // History that exists before this call's first byte: what a distance may reach beyond
        // this call's own output. `totalProduced` already counts this call's earlier bytes, so
        // they are subtracted back out here and re-added as `produced` in the check.
        let historyBeforeCall = self.totalProduced - runStart

        var outcome = FastOutcome.paused

        run: while true {
            if bits < 48 {
                let raw = UnsafeRawPointer(inBase + inOffset).loadUnaligned(as: UInt64.self)
                hold |= UInt64(littleEndian: raw) << UInt64(bits)
                inOffset &+= (63 - bits) >> 3
                bits |= 56
            }

            var entry = literalTable[Int(hold & literalMask)]
            var op = Int((entry >> 8) & 0xFF)

            symbol: while true {
                let took = Int(entry & 0xFF)
                hold >>= UInt64(took)
                bits &-= took

                if op == 0 {
                    out[produced] = UInt8(truncatingIfNeeded: entry >> 16)
                    produced &+= 1
                    break symbol
                }

                if op & 16 != 0 {
                    var length = Int(entry >> 16)
                    let lengthExtra = op & 15
                    if lengthExtra > 0 {
                        length &+= Int(hold & ((1 << UInt64(lengthExtra)) - 1))
                        hold >>= UInt64(lengthExtra)
                        bits &-= lengthExtra
                    }

                    entry = distanceTable[Int(hold & distanceMask)]
                    op = Int((entry >> 8) & 0xFF)

                    distance: while true {
                        let took = Int(entry & 0xFF)
                        hold >>= UInt64(took)
                        bits &-= took

                        if op & 16 != 0 {
                            var dist = Int(entry >> 16)
                            let distExtra = op & 15
                            if distExtra > 0 {
                                dist &+= Int(hold & ((1 << UInt64(distExtra)) - 1))
                                hold >>= UInt64(distExtra)
                                bits &-= distExtra
                            }

                            guard dist <= historyBeforeCall &+ produced,
                                  dist <= DeflateTables.windowSize
                            else {
                                outcome = .distanceTooFar
                                break run
                            }

                            if dist <= produced {
                                // The whole match lies inside this call's own output, which is
                                // contiguous — no window, no masking. Eight bytes at a time is
                                // safe whenever the source runs at least eight bytes behind
                                // the destination: every load reads bytes already final.
                                let src = out + (produced - dist)
                                let dst = out + produced

                                if dist >= 8 {
                                    var index = 0
                                    while index < length {
                                        let chunk = UnsafeRawPointer(src + index)
                                            .loadUnaligned(as: UInt64.self)
                                        UnsafeMutableRawPointer(dst + index)
                                            .storeBytes(of: chunk, as: UInt64.self)
                                        index &+= 8
                                    }
                                } else if dist == 1 {
                                    dst.update(repeating: src.pointee, count: length)
                                } else {
                                    for index in 0 ..< length {
                                        dst[index] = src[index]
                                    }
                                }
                                produced &+= length
                            } else {
                                // The head of the match reaches past this call's output into
                                // the window; the tail, if any, continues from the output.
                                var fromWindow = dist - produced
                                var remaining = length
                                var readPosition = (self.windowPosition &- runStart &- fromWindow) & mask

                                while fromWindow > 0, remaining > 0 {
                                    out[produced] = window[readPosition]
                                    readPosition = (readPosition &+ 1) & mask
                                    produced &+= 1
                                    fromWindow &-= 1
                                    remaining &-= 1
                                }

                                let src = out + (produced - dist)
                                for index in 0 ..< remaining {
                                    out[produced &+ index] = src[index]
                                }
                                produced &+= remaining
                            }

                            break symbol
                        }

                        if op & 64 == 0 {
                            let link = Int(entry >> 16) &+ Int(hold & ((1 << UInt64(op)) - 1))
                            entry = distanceTable[link]
                            op = Int((entry >> 8) & 0xFF)
                            continue distance
                        }

                        outcome = .invalidDistanceSymbol
                        break run
                    }
                }

                if op & 64 == 0 {
                    let link = Int(entry >> 16) &+ Int(hold & ((1 << UInt64(op)) - 1))
                    entry = literalTable[link]
                    op = Int((entry >> 8) & 0xFF)
                    continue symbol
                }

                if op & 32 != 0 {
                    outcome = .endOfBlock
                    break run
                }

                outcome = .invalidLengthSymbol
                break run
            }

            if inOffset >= inLimit || produced >= outLimit {
                break run
            }
        }

        // Hand back the whole bytes the wide refills over-read, which is what keeps
        // `pulledInputCount` exact: at most seven bits stay buffered, less than a byte, the
        // same invariant the careful reader maintains.
        let giveBack = bits >> 3
        inOffset &-= giveBack
        bits &= 7
        hold &= (UInt64(1) << UInt64(bits)) - 1

        self.reader.restoreRaw(buffer: hold, bitCount: bits, inputOffset: inOffset)

        let producedInRun = produced - runStart
        if producedInRun > 0 {
            self.syncWindow(from: out + runStart, count: producedInRun)
            self.totalProduced &+= producedInRun
        }
        self.destinationCount = produced

        return outcome
    }

    /// Ends the block just completed, and the stream with it if that block declared itself last.
    ///
    /// Nothing is read past the end-of-block symbol: whatever follows is either the next block's
    /// header, which the next step reads, or a wrapper's trailer, which is not this module's to
    /// interpret.
    private mutating func endBlock() {
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
    private mutating func repeatPreviousLength(count: Int) throws(DeflateError) {
        guard self.combinedLengthsIndex > 0 else {
            throw DeflateError("invalid bit length repeat")
        }

        try self.fill(self.previousCodeLength, count: count)
    }

    private mutating func fillZeroLength(count: Int) throws(DeflateError) {
        try self.fill(0, count: count)
        self.previousCodeLength = 0
    }

    private mutating func fill(_ value: UInt8, count: Int) throws(DeflateError) {
        guard self.combinedLengthsIndex + count <= self.combinedLengths.count else {
            throw DeflateError("invalid bit length repeat")
        }

        for _ in 0 ..< count {
            self.combinedLengths[self.combinedLengthsIndex] = value
            self.combinedLengthsIndex += 1
        }
    }
}


/// The public face: a reference type over ``InflateCore``, because that is what the streaming
/// contract wants — a stream is one thing with identity that several stages of a pipeline hand
/// around, not a value to be copied. The box costs one dynamically checked access per call;
/// everything under it is checked statically.
public final class Inflate {
    var core = InflateCore()

    public init() {}

    public var needsInput: Bool { self.core.needsInput }
    public var isFinished: Bool { self.core.isFinished }
    public var pulledInputCount: Int { self.core.pulledInputCount }
    public var producedInLastCall: Int { self.core.producedInLastCall }
    public var dictionary: [UInt8] { self.core.dictionary }
    public var isAtSyncPoint: Bool { self.core.isAtSyncPoint }

    public func setInput(_ bytes: UnsafeBufferPointer<UInt8>) { self.core.setInput(bytes) }
    public func alignToByte() { self.core.alignToByte() }
    public func readBits(_ count: Int) -> UInt32? { self.core.readBits(count) }
    public func readByte() -> UInt8? { self.core.readByte() }
    public func primeWindow(_ bytes: UnsafeBufferPointer<UInt8>) { self.core.primeWindow(bytes) }
    public func prime(_ value: UInt32, bits count: Int) -> Bool { self.core.prime(value, bits: count) }
    public func resumeAtBlockBoundary() { self.core.resumeAtBlockBoundary() }

    public func inflate(
        into destination: UnsafeMutablePointer<UInt8>,
        count: Int
    ) throws(DeflateError) -> Int {
        try self.core.inflate(into: destination, count: count)
    }

    /// An independent copy, sharing nothing.
    public func copy() -> Inflate {
        let clone = Inflate()
        clone.core = self.core.copied()
        return clone
    }
}
