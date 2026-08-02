// DeflateError.swift - the error type, named here as well as below
//
// Everything that can fail in a gzip member fails for a DEFLATE reason or a framing reason, and
// both want the same error type. This layer throws `LZ77`'s, and names it here so that
// `import GZip` alone is enough to write the `catch`.

import LZ77

public typealias DeflateError = LZ77.DeflateError
