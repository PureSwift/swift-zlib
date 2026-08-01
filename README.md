# swift-zlib

DEFLATE and INFLATE in Swift, with no C library underneath.

This is the compressor and decompressor themselves — bit packing, canonical Huffman coding,
match finding, the checksums — rather than a wrapper around the system zlib. There are no
dependencies and no Foundation, so it builds wherever Swift does, including targets that
have no zlib to link against.

The engine was taken from [swift-png](https://github.com/PureSwift/swift-png), where it
backs the PNG codec's compression path.

## Two modules

They split where the specifications split.

| | |
|---|---|
| `LZ77` | RFC 1951. DEFLATE data and nothing around it. Self-contained. |
| `Zlib` | RFC 1950. The two-byte header, the Adler-32 trailer, and the checksums. |

The seam is there because the wrapper is the part that varies: gzip is the same DEFLATE
data under a different header with a CRC-32 after it, so it belongs beside `Zlib` rather
than inside it. A caller wanting raw DEFLATE depends on `LZ77` directly and carries none of
the framing.

`LZ77` never reads past the final block's end-of-block symbol, and exposes `alignToByte()`
and `readBits(_:)` so a wrapper reads its own fields off the *same* input stream. That is
what keeps the two layers from having to agree on a byte offset that neither can name — a
bit reader holds part of a byte, so there is no such offset to hand over.

## Using it

Both types are push-in, pull-out: bytes go in whenever the caller has some, and bytes come
out into whatever buffer, and however many at a time, the caller asks for. Neither side
dictates the other's block size, and every point where input might run out mid-field is
resumable — so a stream fed one byte at a time decodes identically to one fed whole.

```swift
import Zlib

let stream = Decompressor()
stream.setInput(bytes)                       // UnsafeBufferPointer<UInt8>
let produced = try stream.inflate(into: destination, count: capacity)
// ... `needsInput` and `isFinished` say which of the two ran out.
```

```swift
let compressor = Compressor(level: 6)
compressor.setInput(bytes)
let produced = try compressor.deflate(into: destination, count: capacity, ending: .finish)
```

`isFinished` on the decompressor waits for the Adler-32 to be read and matched, not merely
for the last block to decode — until then the bytes produced are unverified, and a caller
that stopped early would never learn it.

## What it produces

A valid zlib stream (RFC 1950) of fixed-Huffman DEFLATE blocks (RFC 1951 §3.2.6) over LZ77
matches found with a hash chain. Fixed blocks need no table sent and no tree built, which is
most of the code and nearly all of the memory a dynamic-block encoder wants; on the targets
this exists to serve, that trade is the right way round.

The decompressor is complete: stored, fixed, and dynamic blocks are all read, so it accepts
anything zlib emits.

Two consequences of the encoder stopping at fixed blocks, both measured against zlib 1.3.1:

- Compressible input comes out a few per cent larger than zlib's dynamic blocks would make it.
- Incompressible input **expands by about 5.4%**, where zlib emits a stored block and expands
  by 0.03%. There is no stored-block fallback yet, and `level: 0` does not mean "stored" here
  the way it does in zlib — it means "literals only, no match search."

## Status

The codec is verified in both directions against the system zlib:

- 128 cases of `Compressor` output — levels 0/1/6/9 over empty, tiny, repetitive,
  incompressible, and larger-than-window inputs, fed and collected in chunks down to one
  byte at a time — are all accepted by zlib and decode back to the original bytes.
- 178 cases of zlib output — all five of its strategies, including `Z_FIXED` and
  `Z_HUFFMAN_ONLY`, at four levels — decode correctly through `Decompressor`, whole and fed
  in chunks of 1, 2, 3, 7, 13, and 997 bytes.

Those differential runs are not yet in the repository. `swift test` runs the unit suites,
which check the decoder against known-good streams, the encoder by round trip, and the
framing by direct assertion.

## The C ABI

`cmake --build` produces a `libz.so.1` that a program compiled against the reference can load
unchanged. The Swift engine knows nothing about it: `ZlibABI` is a separate target holding one
`@c @implementation` function per entry point, each type-checked against the declaration in the
vendored `zlib.h`, so the exported ABI cannot drift from what clients were compiled against.

```
cmake -S . -B build/cmake -G Ninja && cmake --build build/cmake
./scripts/check_exports.sh          # exactly the reference's 88 symbols, right version nodes
./scripts/run_conformance.sh        # differential test against the system libz
```

**All 88 symbols are exported; 19 are implemented.** The rest are generated stubs that report
the gap on stderr and return the library's own error value, so a client gets a diagnostic
rather than a link failure — and so each one becomes "move a name from `scripts/implemented.txt`
and watch the conformance diff shrink". A name in both files is a duplicate-symbol link error,
so the two cannot drift.

Implemented: the checksums (`adler32`, `crc32`, both `_z` and every `_combine` variant),
`compress`/`compress2`/`uncompress`/`uncompress2`/`compressBound`, and
`zlibVersion`/`zError`/`zlibCompileFlags`. Not yet: the `z_stream` streaming API, and the whole
`gz*` file layer.

Two build systems on purpose. SwiftPM drives development and the tests; CMake builds the
shipped artifact, because the soname, the install name and the version script are not
expressible in `Package.swift`.

### What is verified

- The built library exports **exactly** the reference's 88 symbols under the reference's own
  version nodes — nothing missing, and none of the ~190 Swift symbols a naive link leaks.
- `Conformance/zconform.c` compiled twice, against the reference and against this library, is
  **identical on every compared line**: every checksum, every running and combined checksum,
  every return code, every error path.
- A binary compiled and linked against the real libz produces byte-identical output when run
  with this library `LD_PRELOAD`ed.

Compressed *sizes* are the one thing allowed to differ, since nothing requires two encoders to
agree. `run_conformance.sh` reports them as a table: equal or better on incompressible and
small inputs, and 2–6× larger on highly compressible input, which is the dynamic-block gap
above.

## License

MIT. See `LICENSE`.

The vendored `zlib.h` and `zconf.h` are under the zlib licence instead — see `LICENSE.zlib`.
