// BitWriter.swift - packing bits back out in DEFLATE's order
//
// The mirror of BitReader: fields go out low bit first within a byte and run across byte
// boundaries, so a writer accumulates into a wide register and drops whole bytes off the bottom
// as they complete.
//
// Huffman codes are the one exception, exactly as they are when reading — a code is defined
// most significant bit first, so it is reversed on the way out. That reversal is done here
// rather than at each call site so that no caller has to remember which of the two orders it is
// holding.
//
// Completed bytes live in raw memory this struct owns, not in an array, because one write
// lands per symbol emitted: an array append pays a uniqueness check and a bounds check per
// byte, and this path pays instead one eight-byte store per flush — the register is written
// out whole, and only the count of completed bytes advances, so however many bytes the flush
// completed cost the same single store.
struct BitWriter: ~Copyable {
    private var buffer: UInt64 = 0
    private var bitCount = 0

    private var storage: UnsafeMutablePointer<UInt8>
    private var capacity: Int
    private var count = 0

    init() {
        self.capacity = 1 << 16
        self.storage = .allocate(capacity: self.capacity)
    }

    deinit {
        self.storage.deallocate()
    }

    /// Room for `extra` more bytes, plus the eight of slack the whole-register store runs into.
    private mutating func ensure(_ extra: Int) {
        let needed = self.count + extra + 8
        guard needed > self.capacity else { return }

        let grown = max(self.capacity * 2, needed)
        let replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: grown)
        replacement.update(from: self.storage, count: self.count)
        self.storage.deallocate()
        self.storage = replacement
        self.capacity = grown
    }

    @inline(__always)
    mutating func write(_ value: UInt32, bits: Int) {
        guard bits > 0 else { return }

        let mask: UInt64 = ~UInt64(0) >> (64 - bits)
        self.buffer |= (UInt64(value) & mask) << self.bitCount
        self.bitCount += bits

        if self.bitCount >= 8 {
            self.ensure(8)
            UnsafeMutableRawPointer(self.storage + self.count)
                .storeBytes(of: self.buffer.littleEndian, as: UInt64.self)

            let completed = self.bitCount >> 3
            self.count += completed
            self.buffer >>= completed << 3
            self.bitCount &= 7
        }
    }

    /// Each byte backwards, for building the code reversals below out of two lookups.
    private static let reversedByte: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)

        for value in 0 ..< 256 {
            var reversed = 0
            for bit in 0 ..< 8 where value & (1 << bit) != 0 {
                reversed |= 1 << (7 - bit)
            }
            table[value] = UInt8(reversed)
        }

        return table
    }()

    /// A code turned around into writing order: DEFLATE defines codes most significant bit
    /// first, and this writer emits low bit first. A sixteen-bit byte-table reversal shifted
    /// down to `bits` — two lookups rather than a loop over the bits.
    static func reversed(_ code: UInt32, bits: Int) -> UInt32 {
        let low = Self.reversedByte[Int(code & 0xFF)]
        let high = Self.reversedByte[Int((code >> 8) & 0xFF)]
        return (UInt32(low) << 8 | UInt32(high)) >> (16 - bits)
    }

    /// Writes a Huffman code, reversing it so the most significant bit goes out first.
    @inline(__always)
    mutating func writeCode(_ code: UInt32, bits: Int) {
        self.write(Self.reversed(code, bits: bits), bits: bits)
    }

    /// Pads to the next byte boundary with zeroes, which is what a stored block's header needs
    /// and what ends a stream.
    mutating func alignToByte() {
        if self.bitCount > 0 {
            self.write(0, bits: 8 - self.bitCount)
        }
    }

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }

        self.ensure(bytes.count)
        (self.storage + self.count).update(from: base, count: bytes.count)
        self.count += bytes.count
    }

    mutating func append(_ byte: UInt8) {
        self.ensure(1)
        self.storage[self.count] = byte
        self.count += 1
    }

    /// Copies up to `limit` completed bytes out from the front, keeping the rest — and anything
    /// written later — behind them in order.
    mutating func drain(into destination: UnsafeMutablePointer<UInt8>, limit: Int) -> Int {
        let taking = min(limit, self.count)
        guard taking > 0 else { return 0 }

        destination.update(from: self.storage, count: taking)

        let remaining = self.count - taking
        if remaining > 0 {
            self.storage.update(from: self.storage + taking, count: remaining)
        }
        self.count = remaining

        return taking
    }

    /// An explicit duplicate sharing nothing, for the encoder's own `copied()`.
    borrowing func copied() -> BitWriter {
        var clone = BitWriter()
        clone.ensure(self.count)
        clone.storage.update(from: self.storage, count: self.count)
        clone.count = self.count
        clone.buffer = self.buffer
        clone.bitCount = self.bitCount
        return clone
    }

    var pendingByteCount: Int {
        self.count
    }

    /// Whether anything at all has been written, which is what tells a caller wanting to insert
    /// bits ahead of the stream whether it is still early enough to do so.
    var isEmpty: Bool {
        self.count == 0 && self.bitCount == 0
    }
}
