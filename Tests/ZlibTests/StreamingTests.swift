import Testing

@testable import Zlib

/// The behaviour a caller driving these a piece at a time depends on, rather than what a whole
/// buffer in and a whole buffer out exercises.
///
/// Every case here is one that a plain round trip passes and that a real caller hits: input
/// arriving in pieces, output collected in pieces, and a stream that has to say exactly where
/// it ended. Two of them are regressions from bugs that a round trip could not have found,
/// because a round trip never asks the encoder and the decoder the awkward question at the same
/// time.
@Suite("Streaming")
struct StreamingTests {
    static let payload = Array(
        (String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 40)
            + String(repeating: "abcabcabcabc", count: 30)).utf8
    )

    /// Handing over input has to mean the compressor owns it.
    ///
    /// It used to mean only that the compressor had been *shown* it, with the copy happening
    /// inside the next call that produced output. A caller whose output buffer was full took no
    /// such call, handed over a second buffer, and silently lost the first. Feeding one byte at
    /// a time while collecting one byte at a time is the shape that does it.
    @Test("Input handed over is kept, even when no output can be taken")
    func inputIsCopiedOnHandover() throws {
        let compressed = try CompressorTests.compress(
            Self.payload,
            feeding: 1,
            collecting: 1
        )

        #expect(
            try DecompressorTests.inflate(compressed, into: Self.payload.count * 2 + 64)
                == Self.payload
        )
    }

    /// Two buffers handed over with no call in between: the first must not be forgotten.
    @Test("A second input buffer does not displace the first")
    func consecutiveInputs() throws {
        let compressor = Compressor(level: 6)
        var first = Array("first half, ".utf8)
        var second = Array("second half".utf8)

        first.withUnsafeMutableBufferPointer { compressor.setInput(UnsafeBufferPointer($0)) }
        second.withUnsafeMutableBufferPointer { compressor.setInput(UnsafeBufferPointer($0)) }

        var compressed: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 512)

        while !compressor.isFinished {
            let made = try scratch.withUnsafeMutableBufferPointer {
                try compressor.deflate(into: $0.baseAddress!, count: $0.count, ending: .finish)
            }
            compressed.append(contentsOf: scratch[0 ..< made])
        }

        #expect(try DecompressorTests.inflate(compressed) == Array("first half, second half".utf8))
    }

    /// A stream that produces nothing still has to be able to finish.
    ///
    /// Both layers used to give up the moment the destination was full, so a stream whose
    /// remaining output was nothing at all could never reach its end — and decompressing into a
    /// zero-length buffer never reported finished no matter how often it was called.
    @Test("An empty payload finishes with no room to write into")
    func finishesWithNoOutputRoom() throws {
        let compressed = try CompressorTests.compress([])
        let stream = Decompressor()
        var input = compressed

        input.withUnsafeMutableBufferPointer {
            stream.setInput(UnsafeBufferPointer($0))
        }

        var scratch = [UInt8](repeating: 0, count: 1)
        let made = try scratch.withUnsafeMutableBufferPointer {
            try stream.inflate(into: $0.baseAddress!, count: 0)
        }

        #expect(made == 0)
        #expect(stream.isFinished)
    }

    /// How much input a stream used has to be exactly the stream, so that whatever follows it
    /// can be found. A decoder reading ahead into the next stream's bytes is the reason a
    /// second one cannot be decoded after the first.
    @Test("A finished stream reports its length to the byte")
    func reportsExactStreamLength() throws {
        let compressed = try CompressorTests.compress(Self.payload)
        var withTrailer = compressed
        withTrailer.append(contentsOf: Array("AFTER THE STREAM".utf8))

        let stream = Decompressor()
        var output = [UInt8](repeating: 0, count: Self.payload.count + 64)
        var produced = 0

        try withTrailer.withUnsafeMutableBufferPointer { buffer in
            stream.setInput(UnsafeBufferPointer(buffer))

            produced = try output.withUnsafeMutableBufferPointer {
                try stream.inflate(into: $0.baseAddress!, count: $0.count)
            }
        }

        #expect(stream.isFinished)
        #expect(Array(output[0 ..< produced]) == Self.payload)
        #expect(stream.pulledInputCount == compressed.count)
    }

    /// The same, with the trailing bytes fed in the same buffer one at a time — which is where
    /// a decoder that pulls whole bytes ahead of reading them would swallow the first of them.
    @Test("The stream length is exact even when fed a byte at a time")
    func exactLengthBytewise() throws {
        let compressed = try CompressorTests.compress(Array("hello, world".utf8))

        let stream = Decompressor()
        var output = [UInt8](repeating: 0, count: 64)
        var produced = 0
        var used = 0
        var input = compressed

        try input.withUnsafeMutableBufferPointer { buffer in
            var offset = 0

            while offset < buffer.count, !stream.isFinished {
                stream.setInput(
                    UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: 1)
                )

                produced += try output.withUnsafeMutableBufferPointer {
                    try stream.inflate(
                        into: $0.baseAddress! + produced,
                        count: $0.count - produced
                    )
                }

                used += stream.pulledInputCount
                offset += 1
            }
        }

        #expect(stream.isFinished)
        #expect(Array(output[0 ..< produced]) == Array("hello, world".utf8))
        #expect(used == compressed.count)
    }

    /// A window smaller than the default has to be honoured rather than noted: a decoder sizes
    /// its own from the header, so a distance beyond what was declared is unreadable to it.
    @Test("A declared window is what the encoder is held to", arguments: [9, 10, 12, 15] as [Int32])
    func honoursWindowBits(_ windowBits: Int32) throws {
        let compressed = try CompressorTests.compress(Self.payload, windowBits: windowBits)

        #expect(compressed[0] & 0x0F == 8)
        #expect((compressed[0] >> 4) == UInt8(windowBits - 8))

        #expect(
            try DecompressorTests.inflate(compressed, into: Self.payload.count * 2 + 64)
                == Self.payload
        )
    }
}
