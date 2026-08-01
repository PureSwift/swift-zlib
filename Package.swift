// swift-tools-version: 6.3

import PackageDescription

// DEFLATE and INFLATE in Swift, with no C library underneath.
//
// Two modules, split where the specifications split. `LZ77` is RFC 1951 and only
// that — bit packing, Huffman coding, match finding — and knows nothing of what
// might be wrapped around it. `Zlib` is RFC 1950: the two-byte header, the
// Adler-32 trailer, and the checksums, over a stream `LZ77` produces or consumes.
//
// The seam is there because the wrapper is the part that varies. gzip is the same
// DEFLATE data under a different header with a CRC-32 after it, so it belongs
// beside `Zlib` rather than inside it — and a caller wanting raw DEFLATE with no
// framing at all depends on `LZ77` directly and carries none of this.
//
// No Foundation, and no dependencies.

let package = Package(
    name: "swift-zlib",
    products: [
        .library(name: "Zlib", targets: ["Zlib"]),
        .library(name: "LZ77", targets: ["LZ77"]),
    ],
    targets: [
        // RFC 1951. Self-contained, and what everything else here is built on.
        .target(
            name: "LZ77",
            path: "Sources/LZ77"
        ),

        // RFC 1950, over the above.
        .target(
            name: "Zlib",
            dependencies: ["LZ77"],
            path: "Sources/Zlib"
        ),

        .testTarget(
            name: "LZ77Tests",
            dependencies: ["LZ77"],
            path: "Tests/LZ77Tests"
        ),
        .testTarget(
            name: "ZlibTests",
            dependencies: ["Zlib"],
            path: "Tests/ZlibTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
