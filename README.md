# swift-zlib

DEFLATE and INFLATE in Swift, with no C library underneath.

This is the compressor and decompressor themselves — bit packing, canonical Huffman coding,
match finding, the checksums — rather than a wrapper around the system zlib. There are no
dependencies and no Foundation, so it builds wherever Swift does, including targets that
have no zlib to link against.

The engine was taken from [swift-png](https://github.com/PureSwift/swift-png), where it
backs the PNG codec's compression path.

## Three modules

They split where the specifications split.

| | |
|---|---|
| `LZ77` | RFC 1951. DEFLATE data and nothing around it. Self-contained. |
| `Zlib` | RFC 1950. The two-byte header, the Adler-32 trailer. |
| `GZip` | RFC 1952. The longer header with its optional fields, the CRC-32 and length trailer. |

The seam is there because the wrapper is the part that varies. `Zlib` and `GZip` are
siblings over the same `LZ77`, not one inside the other — neither format is a special case
of the other, and a caller wanting raw DEFLATE depends on `LZ77` directly and carries
neither.

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

Each block is written as stored (RFC 1951 §3.2.4), fixed-Huffman (§3.2.6) or dynamic-Huffman
(§3.2.7) over LZ77 matches found with a hash chain — whichever of the three is smallest for
that block, decided by costing all three rather than guessed. The decompressor reads all three
as well, so it accepts anything zlib emits.

Matches are found greedily at the fast levels and lazily from level 4 up — taking a match only
after checking whether a longer one starts on the next byte — which is the same split the
reference makes, and for the same reason: deferring doubles the number of searches and on some
data costs a little size as well.

Sizes against zlib 1.3.1 at the same level: within 0.3% on most inputs at levels 6 and 9,
identical on incompressible input (both store it), and *smaller* on English text, source code
and run-structured data. At level 1 the output is smaller than the reference's on every input
measured. The two worst cases are highly repetitive payloads — 362 bytes against 313 for 300 KB
of zeroes, and 219 against 207 for a repeating pattern — where the absolute difference is a few
dozen bytes.

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

**All 88 symbols are implemented.** 86 in Swift, and the two variadics — `gzprintf` and
`gzvprintf` — in C, since Swift cannot define a C variadic. The stub generator that carried the
surface while it was being built now emits nothing, and remains in the build so that adding a
symbol to `scripts/symbols.txt` without implementing it fails loudly again.

| | |
|---|---|
| Checksums | `adler32`, `crc32`, both `_z` forms, every `_combine` variant |
| One-shot | `compress`, `compress2`, `uncompress`, `uncompress2`, `compressBound` |
| Streaming | `deflate`/`inflate` with `Init_`, `Init2_`, `End`, `Reset`, `ResetKeep`, plus `inflateReset2`, `deflateBound`, `deflatePending` |
| gzip metadata | `deflateSetHeader`, `inflateGetHeader` |
| Files | the whole `gz*` family — open, read, write, seek, tell, line and character access, buffering, errors |
| Dictionaries | `deflateSetDictionary`/`GetDictionary`, `inflateSetDictionary`/`GetDictionary`, with `Z_NEED_DICT` and the id check |
| Control | `deflateParams` (mid-stream level change), `deflateTune`, `deflatePrime`/`inflatePrime`, `deflateCopy`/`inflateCopy` |
| Recovery | `inflateSync` and `inflateSyncPoint`, over `Z_FULL_FLUSH`'s window reset; `inflateValidate` |
| Callback-driven | `inflateBack`, `inflateBackInit_`, `inflateBackEnd` |
| Identity | `zlibVersion`, `zError`, `zlibCompileFlags`, `get_crc_table` |

The streaming API covers every framing the format offers: zlib (`windowBits` 8…15), raw
DEFLATE (−8…−15), gzip (+16), and the mode that accepts either zlib or gzip without being told
which (+32). The window is honoured rather than noted, since a decoder sizes its own from the
header.

`gzFile` is worth a note, because it is the one part of the API that is not opaque: `zlib.h`
defines its three fields and makes `gzgetc` a macro that takes a byte straight out of them
without calling the library. So the handle really is a `struct gzFile_s`, the decompressed
buffer lives at a stable address published through it, and every entry point reconciles what
the macro consumed on the way in.

Two entry points answer honestly rather than identically: `inflateMark` and `inflateCodesUsed`
report on the reference's own table layout and bit accounting, which a decoder built
differently cannot reproduce — they return well-formed values and the contractual error cases,
and their in-stream numbers are documented as this library's own. `inflateUndermine` is
refused, as the reference refuses it unless built for it.

Two build systems on purpose. SwiftPM drives development and the tests; CMake builds the
shipped artifact, because the soname, the install name and the version script are not
expressible in `Package.swift`.

### What is verified

**zlib's own test programs**, built against this library unmodified: `test/example.c` passes
in full — including `inflateSync` recovery and preset dictionaries — with output identical to
the reference's, and `test/minigzip.c` round-trips in all three directions (ours to ours, ours
to the reference, the reference to ours).

`test/infcover.c` cannot run whole against any other implementation: it includes zlib's private
headers and reaches into `struct inflate_state`. Its **24 adversarial streams** — written to
reach every error path in inflate — are extracted and run through the public API instead, and
**every one gives the identical answer**.

**Differential fuzzing of inflate**, which is where zlib's CVEs have been. 6000 streams —
intact, bit-flipped, truncated, byte-smashed and pure noise, across zlib, raw, gzip and
auto-detect framing — generated once by the reference so both libraries decode identical
bytes. **The accept/reject verdict matches on every one, and every accepted stream decodes to
identical bytes.** One stream salvages a different number of pre-error bytes, which is a
judgement two decoders may make differently.


- The built library exports **exactly** the reference's 88 symbols under the reference's own
  version nodes — nothing missing, and none of the ~190 Swift symbols a naive link leaks.
- Two conformance programs, each compiled twice — against the reference and against this
  library — are **identical on every compared line**. `zconform.c` covers the checksums, the
  one-shot API and the error paths; `zgzfile.c` covers the file layer — round trips at four
  levels, reads in chunks down to one byte, line and character access, seeking forwards and
  backwards, transparent reading of a non-gzip file, concatenated members, and the error paths;
  `zstream.c` covers the streaming API across six input and
  output chunk-size combinations (down to one byte at a time in both directions), ten
  compression levels, seven window sizes, all four framings, gzip headers written and read back
  through buffers too small for them, corrupt input, truncated members, and misuse such as
  calling `inflate` on an uninitialised stream.
- A binary compiled and linked against the real libz produces byte-identical output when run
  with this library `LD_PRELOAD`ed.
- **Python's `zlib` and `gzip` modules** — unmodified real consumers — pass one-shot, streaming,
  raw and gzip round trips with this library preloaded. **git** writes a commit through it, and
  `git fsck` then verifies those objects both with this library and with the stock one.
- A `.gz` written through this library is accepted by **`gunzip(1)`** with the bytes and the
  recorded filename intact, and a `.gz` written by `gzip(1)` reads back through it — including
  two of them concatenated, and including a plain file read transparently.

Three bugs were found by these harnesses that a round trip could not have found, all now
regression-tested in `Tests/ZlibTests/StreamingTests.swift`: decompressing into a zero-length
buffer never reported finished; a decoder reading ahead reported the wrong end of a stream and
then deadlocked; and handing the encoder a second input buffer while its output buffer was full
silently lost the first.

Compressed *sizes* are the one thing allowed to differ, since nothing requires two encoders to
agree. `run_conformance.sh` reports them as a table: equal or better on incompressible and
small inputs, and 2–6× larger on highly compressible input, which is the dynamic-block gap
above.

## License

MIT. See `LICENSE`.

The vendored `zlib.h` and `zconf.h` are under the zlib licence instead — see `LICENSE.zlib`.
