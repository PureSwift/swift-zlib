// DeflateError.swift - what this module can fail with
//
// A static message, so an error is safe to construct without allocating — on the targets
// this library exists to serve, the path that reports a malformed stream is the last one
// that should need the heap.

public struct DeflateError: Error, Sendable {
    public let message: StaticString

    public init(_ message: StaticString) {
        self.message = message
    }
}
