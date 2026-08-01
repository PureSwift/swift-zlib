// DeflateError.swift - the error type, named here as well as below
//
// Everything that can fail in a zlib stream fails for a DEFLATE reason or a framing reason, and
// both want the same error type; inventing a second one at this layer would mean every caller
// catching two things that mean the same. So this layer throws `LZ77`'s, and names it here so
// that `import Zlib` alone is enough to write the `catch`.

import LZ77

public typealias DeflateError = LZ77.DeflateError
