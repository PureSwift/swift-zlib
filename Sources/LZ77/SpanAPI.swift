// SpanAPI.swift - the same streams, with lifetimes the compiler can see
//
// The pointer-based entry points carry a contract the type system cannot express: the buffer
// handed to `setInput` has to stay valid until the stream has consumed it, and nothing but the
// programmer enforces that. `Span` expresses exactly that contract — a borrowed view that
// cannot be stored — so these entry points take their input per call and hand back how much of
// it was used, and the caller re-offers the rest next time. That is `z_stream`'s own shape,
// which is no accident: it is the shape a streaming API has when nobody may retain anybody's
// buffer.
//
// Output goes through `OutputSpan`, the append-shaped view over uninitialized memory, which is
// what a decompressor's output actually is. The bulk escape hatch is used inside rather than
// per-byte `append`, so the safety of the boundary costs nothing in the loop.
//
// These are additions, not replacements. The pointer API remains, because the C ABI underneath
// this library is made of exactly such pointers, and pretending otherwise would only move the
// unsafety somewhere less visible.

extension Inflate {
    /// Decompresses `input` into `output`'s free capacity, returning how many bytes of input
    /// were consumed.
    ///
    /// Input not consumed — because output filled up first, or because it ends mid-symbol —
    /// must be offered again on the next call. `output`'s count advances by what was produced.
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

extension Deflate {
    /// Compresses `input` into `output`'s free capacity, returning how many bytes were
    /// produced this call.
    ///
    /// The encoder copies its input on receipt, so unlike ``Inflate``, input is always consumed
    /// in full — what may be left behind is output, which later calls hand over as room
    /// appears.
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
