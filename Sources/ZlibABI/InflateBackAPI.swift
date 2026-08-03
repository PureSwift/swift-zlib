// InflateBackAPI.swift - decompression driven by callbacks instead of buffers
//
// The other calling convention. Everywhere else the caller owns the loop: it fills `next_in`,
// drains `next_out`, and calls again. Here the library owns it — the caller hands over two
// functions, one producing compressed bytes and one consuming decompressed ones, and a single
// call runs the whole stream through them.
//
// It exists for one kind of caller: the embedded one that wants the window to be *its* buffer
// (handed to `inflateBackInit_`) and everything decoded in one place, without the state machine
// costs of resumability. That shows in the contract's sharp edges — raw DEFLATE only, one
// stream only, and the output callback receives windowfuls, not arbitrary slices.

import CZlib
import LZ77

/// What `inflateBackInit_` attaches: the caller's window, and nothing else until the one call.
final class InflateBackState {
    let window: UnsafeMutablePointer<UInt8>
    let windowBits: Int32

    init(window: UnsafeMutablePointer<UInt8>, windowBits: Int32) {
        self.window = window
        self.windowBits = windowBits
    }
}

@c @implementation
public func inflateBackInit_(
    _ strm: z_streamp!,
    _ windowBits: Int32,
    _ window: UnsafeMutablePointer<UInt8>!,
    _ version: UnsafePointer<CChar>!,
    _ stream_size: Int32
) -> Int32 {
    if let failure = checkInitArguments(version, stream_size) { return failure }
    guard let strm, let window else { return Status.streamError }

    // §inflateBack: raw DEFLATE only, with the window's size fixed at init. The reference
    // requires 8 through 15 here — positive, unlike inflateInit2's negative-for-raw.
    guard windowBits >= 8, windowBits <= 15 else { return Status.streamError }

    strm.pointee.msg = nil

    attach(InflateBackState(window: window, windowBits: windowBits), to: strm)
    return Status.ok
}

@c @implementation
public func inflateBack(
    _ strm: z_streamp!,
    _ in_fn: in_func!,
    _ in_desc: UnsafeMutableRawPointer!,
    _ out_fn: out_func!,
    _ out_desc: UnsafeMutableRawPointer!
) -> Int32 {
    guard let strm, let state = attached(strm, as: InflateBackState.self), let in_fn, let out_fn
    else {
        return Status.streamError
    }

    let engine = Inflate()

    // Whatever is already in next_in is the stream's beginning; the input callback continues
    // from wherever it ends.
    var input: UnsafeBufferPointer<UInt8> = UnsafeBufferPointer(start: nil, count: 0)

    if let next = strm.pointee.next_in, strm.pointee.avail_in > 0 {
        input = UnsafeBufferPointer(start: next, count: Int(strm.pointee.avail_in))
        engine.setInput(input)
    }

    let windowSize = 1 << Int(state.windowBits)
    var filled = 0

    while true {
        var made = 0

        do {
            made = try engine.inflate(into: state.window + filled, count: windowSize - filled)
        } catch {
            setMessage(strm, zError(Status.dataError))
            return Status.dataError
        }

        filled += made

        // The output callback is handed whole windowfuls, and the final partial one — which is
        // the contract that lets the caller treat its window as the history the stream needs.
        if filled == windowSize || (engine.isFinished && filled > 0) {
            guard out_fn(out_desc, state.window, UInt32(filled)) == 0 else {
                consumeBackInput(strm, engine, input)
                return Status.bufferError
            }

            filled = 0
        }

        if engine.isFinished {
            consumeBackInput(strm, engine, input)
            return Status.streamEnd
        }

        if made == 0 {
            guard engine.needsInput else { continue }

            // The engine has used everything: ask the callback for more. A null or empty answer
            // is the input ending mid-stream, which has its own status.
            var next: UnsafeMutablePointer<UInt8>?
            let got = withUnsafeMutablePointer(to: &next) { pointer in
                in_fn(in_desc, pointer)
            }

            guard got > 0, let base = next else {
                consumeBackInput(strm, engine, input)
                setMessage(strm, zError(Status.bufferError))
                return Status.bufferError
            }

            input = UnsafeBufferPointer(start: base, count: Int(got))
            engine.setInput(input)
        }
    }
}

/// Writes back where the stream ended inside the last input buffer, which is the one part of
/// `z_stream` this convention still uses: the caller finds whatever follows the stream there.
private func consumeBackInput(
    _ strm: z_streamp,
    _ engine: Inflate,
    _ input: UnsafeBufferPointer<UInt8>
) {
    let used = engine.pulledInputCount

    if let base = input.baseAddress {
        strm.pointee.next_in = UnsafeMutablePointer(mutating: base) + used
        strm.pointee.avail_in = UInt32(input.count - used)
    }
}

@c @implementation
public func inflateBackEnd(_ strm: z_streamp!) -> Int32 {
    guard let strm, attached(strm, as: InflateBackState.self) != nil else {
        return Status.streamError
    }

    detach(strm, as: InflateBackState.self)
    return Status.ok
}
