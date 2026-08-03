import Testing

@testable import Zlib

/// The span entry points carry the contract the pointer ones could only document: input is
/// borrowed per call, never stored, and what was not consumed is offered again. What is under
/// test is that contract — a round trip that re-offers unconsumed input the way a real caller
/// must, driven through buffers small enough that every resumption path runs.
@Suite("Span API")
struct SpanAPITests {
    static let payload = Array(
        (String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 200)).utf8
    )

    /// Compresses and decompresses entirely through spans, in awkward chunk sizes.
    static func roundTrip(feeding feed: Int, collecting collect: Int) throws -> [UInt8] {
        let compressor = Compressor(level: 6)
        var compressed: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: collect)

        var offset = 0

        while offset < Self.payload.count || !compressor.isFinished {
            let take = min(feed, Self.payload.count - offset)
            var chunk = Array(Self.payload[offset ..< offset + take])
            offset += take

            let ending: Compressor.Ending = offset >= Self.payload.count ? .finish : .none

            while true {
                // Linear on purpose: `finalize` consumes the span, so there is no using it
                // afterwards and no deferring past it — the compiler enforcing that is the
                // ~Copyable design doing its job.
                let made = try scratch.withUnsafeMutableBufferPointer { raw -> Int in
                    var output = unsafe OutputSpan<UInt8>(buffer: raw, initializedCount: 0)

                    _ = try compressor.deflate(chunk.span, into: &output, ending: ending)

                    return unsafe output.finalize(for: raw)
                }

                // The encoder copies input on receipt, so each chunk is offered exactly once;
                // what is drained across calls is output.
                chunk = []
                compressed.append(contentsOf: scratch[0 ..< made])

                if ending == .none, made == 0 { break }
                if ending == .finish, compressor.isFinished { break }
                if made == 0 { break }
            }
        }

        // Decompression: input is consumed at the stream's own pace, and whatever a call did
        // not take has to be offered again — which is the half of the contract worth testing.
        let stream = Decompressor()
        var recovered: [UInt8] = []
        var out = [UInt8](repeating: 0, count: collect)
        var position = 0

        while !stream.isFinished {
            let end = min(position + feed, compressed.count)
            let piece = Array(compressed[position ..< end])

            let consumed = try out.withUnsafeMutableBufferPointer { raw -> Int in
                var output = unsafe OutputSpan<UInt8>(buffer: raw, initializedCount: 0)

                let consumed = try stream.inflate(piece.span, into: &output)
                let produced = unsafe output.finalize(for: raw)

                for index in 0 ..< produced {
                    recovered.append(raw[index])
                }

                return consumed
            }

            position += consumed

            if consumed == 0, end == compressed.count, position >= compressed.count {
                break
            }
        }

        #expect(stream.isFinished)
        return recovered
    }

    @Test("Round trip through spans, whole buffers")
    func wholeBuffers() throws {
        #expect(try Self.roundTrip(feeding: Self.payload.count, collecting: 16384) == Self.payload)
    }

    @Test("Round trip through spans, awkward chunks", arguments: [(7, 13), (64, 64), (1, 4096)])
    func chunked(_ sizes: (Int, Int)) throws {
        #expect(try Self.roundTrip(feeding: sizes.0, collecting: sizes.1) == Self.payload)
    }

    /// Unconsumed input re-offered is the contract; input dropped on the floor is the bug this
    /// would catch: a decoder that lost track would either stall or produce a short result.
    @Test("A one-byte output buffer forces maximal re-offering")
    func maximalReoffering() throws {
        #expect(try Self.roundTrip(feeding: 3, collecting: 1) == Self.payload)
    }
}
