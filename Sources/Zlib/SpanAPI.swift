// SpanAPI.swift - the span-shaped entry points, forwarded from the wrapper
//
// Same contract as `LZ77`'s: input is borrowed per call and never stored, what was not
// consumed is offered again, and output advances an `OutputSpan`. See LZ77/SpanAPI.swift for
// why the shape is what it is.

import LZ77

extension Decompressor {
    /// Decompresses `input` into `output`'s free capacity, returning how many bytes of input
    /// were consumed.
    public func inflate(
        _ input: Span<UInt8>,
        into output: inout OutputSpan<UInt8>
    ) throws(DeflateError) -> Int {
        try unsafe input.withUnsafeBufferPointer { (buffer) throws(DeflateError) -> Int in
            self.setInput(buffer)

            try unsafe output.withUnsafeMutableBufferPointer {
                (destination, initialized) throws(DeflateError) -> Void in

                initialized += try self.inflate(
                    into: destination.baseAddress! + initialized,
                    count: destination.count - initialized
                )
            }

            return self.pulledInputCount
        }
    }
}

extension Compressor {
    /// Compresses `input` into `output`'s free capacity, returning how many bytes were
    /// produced this call. Input is copied on receipt and so always consumed in full.
    public func deflate(
        _ input: Span<UInt8>,
        into output: inout OutputSpan<UInt8>,
        ending: Ending = .none
    ) throws(DeflateError) -> Int {
        unsafe input.withUnsafeBufferPointer { buffer in
            self.setInput(buffer)
        }

        return try unsafe output.withUnsafeMutableBufferPointer {
            (destination, initialized) throws(DeflateError) -> Int in

            let made = try self.deflate(
                into: destination.baseAddress! + initialized,
                count: destination.count - initialized,
                ending: ending
            )

            initialized += made
            return made
        }
    }
}
