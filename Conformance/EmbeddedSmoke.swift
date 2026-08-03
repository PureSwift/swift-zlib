// A round trip under Embedded Swift: compress, decompress, check.
//
// The point of this file is that the engine is meant to run where there is no zlib to link
// against and no Swift runtime to speak of, and that claim is worth checking rather than
// repeating. It is built by scripts/check_embedded.sh, not by SwiftPM.
//
// Two things here are Embedded Swift's restrictions showing through, and both are the *test's*
// concessions rather than the library's. There is no `try!`, because it erases to `any Error`
// and existentials do not exist here — the library's own calls use typed throws, so an ordinary
// `catch` binds the concrete error and nothing existential is involved. And the buffers are raw
// pointers rather than `Array`, which is how the callers this configuration exists for are
// written anyway.

@main
struct EmbeddedSmoke {
    static func main() {
        let payloadCount = 40000
        let payload = UnsafeMutablePointer<UInt8>.allocate(capacity: payloadCount)

        // Mixed structure, so the encoder has to choose between block types rather than take
        // the same path throughout.
        for index in 0 ..< payloadCount {
            payload[index] = index % 4 == 0
                ? UInt8(truncatingIfNeeded: index / 7)
                : UInt8(0x61 + UInt8(index % 3))
        }

        let capacity = payloadCount + 1024
        let compressed = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        var compressedCount = 0

        let compressor = Compressor(level: 6)
        compressor.setInput(UnsafeBufferPointer(start: payload, count: payloadCount))

        while !compressor.isFinished {
            do {
                let made = try compressor.deflate(into: scratch, count: 4096, ending: .finish)

                for offset in 0 ..< made {
                    compressed[compressedCount + offset] = scratch[offset]
                }

                compressedCount += made
            } catch {
                print("deflate failed")
                return
            }
        }

        let recovered = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        var produced = 0

        let stream = Decompressor()
        stream.setInput(UnsafeBufferPointer(start: compressed, count: compressedCount))

        do {
            produced = try stream.inflate(into: recovered, count: capacity)
        } catch {
            print("inflate failed")
            return
        }

        var identical = stream.isFinished && produced == payloadCount

        for index in 0 ..< produced where identical {
            if recovered[index] != payload[index] { identical = false }
        }

        print("in=\(payloadCount) compressed=\(compressedCount) ok=\(identical)")
    }
}
