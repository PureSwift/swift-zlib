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
        .library(name: "GZip", targets: ["GZip"]),
        .library(name: "LZ77", targets: ["LZ77"]),

        // For iterating on the C surface locally. The artifact that gets installed is built by
        // CMakeLists.txt instead, because the soname, the install name and the version script
        // that make substitution work are not expressible here.
        .library(name: "z", type: .dynamic, targets: ["ZlibABI"]),
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

        // RFC 1952, over the same. A sibling of Zlib rather than a mode inside it: the two
        // wrap identical DEFLATE data in different framing, and neither is a case of the other.
        .target(
            name: "GZip",
            dependencies: ["LZ77"],
            path: "Sources/GZip"
        ),

        // The published C API as clients see it, plus the parts of the implementation that
        // have to be C: reporting an unimplemented entry point, and the variadics.
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            publicHeadersPath: "include"
        ),

        // One @c function per implemented entry point, bound to the declaration in the
        // vendored header. Nothing here decides anything about compression.
        .target(
            name: "ZlibABI",
            dependencies: ["CZlib", "Zlib", "GZip"],
            path: "Sources/ZlibABI"
        ),

        .testTarget(
            name: "LZ77Tests",
            dependencies: ["LZ77"],
            path: "Tests/LZ77Tests"
        ),
        .testTarget(
            name: "GZipTests",
            dependencies: ["GZip"],
            path: "Tests/GZipTests"
        ),
        .testTarget(
            name: "ZlibTests",
            dependencies: ["Zlib"],
            path: "Tests/ZlibTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
