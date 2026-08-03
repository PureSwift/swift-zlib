#!/usr/bin/env bash
# Builds the engine under Embedded Swift, runs a round trip, and compiles it for bare metal.
#
# This is the configuration the library exists to make possible: a target with no zlib to link
# against, where a Swift implementation is load-bearing rather than an alternative. It is easy
# to break from an ordinary desktop build without noticing — an existential in an error path, a
# reflection call, a dependency on the C library — so it belongs in CI rather than in a claim.
#
# The modules are flattened into one for the build. Embedded Swift can compile them separately,
# but `Zlib.Compressor` and `GZip.Compressor` share a name, so each wrapper is built with the
# engine and without the other. That is a restriction of this script, not of the library.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOST_TRIPLE="${HOST_TRIPLE:-x86_64-unknown-linux-gnu}"
BARE_TRIPLES=(aarch64-none-none-elf armv7-none-none-eabi riscv32-none-none-eabi)

status=0

echo "package modules under Embedded Swift (swift build --traits Embedded)"

# The package's own targets, built as real modules through SwiftPM — which is what a dependent
# project does, and what proves the module structure itself survives Embedded rather than only
# a flattened copy of the sources. -wmo comes from the command line because Embedded requires
# it and the manifest must not force unsafe flags on dependents.
for module in LZ77 Zlib GZip; do
    printf '  %-6s ' "$module"

    if (cd "$ROOT" && swift build --traits Embedded -Xswiftc -wmo --target "$module" \
        > "$WORK/$module.log" 2>&1)
    then
        echo "builds"
    else
        echo "FAILED"
        grep -E 'error' "$WORK/$module.log" | head -5 || true
        status=1
    fi
done

echo

# Assembles one wrapper plus the engine into a directory of uniquely named sources — needed
# only for the *runnable* smoke test below, an executable being something the package cannot
# gate behind the trait.
assemble() {
    local wrapper="$1" target="$2"
    mkdir -p "$target"
    cp "$ROOT"/Sources/LZ77/*.swift "$target/"

    for file in "$ROOT"/Sources/"$wrapper"/*.swift; do
        # The typealias that re-exports the error type is redundant in a single module, and
        # would collide with the engine's own declaration of it.
        [[ "$(basename "$file")" == "DeflateError.swift" ]] && continue
        cp "$file" "$target/${wrapper}_$(basename "$file")"
    done

    # Same reason: in one module there is nothing to import.
    sed -i'' -e 's/^import LZ77$//' "$target"/${wrapper}_*.swift
}

echo "host round trip under Embedded Swift ($HOST_TRIPLE)"

for wrapper in Zlib GZip; do
    assemble "$wrapper" "$WORK/$wrapper"
    cp "$ROOT/Conformance/EmbeddedSmoke.swift" "$WORK/$wrapper/"

    printf '  %-6s ' "$wrapper"

    if swiftc -target "$HOST_TRIPLE" -enable-experimental-feature Embedded -wmo \
        -parse-as-library "$WORK/$wrapper"/*.swift -o "$WORK/$wrapper/smoke" \
        > "$WORK/$wrapper/build.log" 2>&1
    then
        result="$("$WORK/$wrapper/smoke")"
        echo "$result"
        [[ "$result" == *"ok=true"* ]] || status=1
    else
        echo "FAILED TO BUILD"
        grep -E 'error' "$WORK/$wrapper/build.log" | head -5 || true
        status=1
    fi
done

echo
echo "bare-metal compilation"

# No @main and no print: a bare-metal target has neither stdout nor a start-up to hook. One
# exported entry point is enough to make the compiler emit the whole engine.
cat > "$WORK/bare.swift" <<'SWIFT'
@_cdecl("swiftzlib_selftest")
public func selftest(_ input: UnsafeMutablePointer<UInt8>, _ count: Int,
                     _ scratch: UnsafeMutablePointer<UInt8>, _ scratchCount: Int) -> Int32 {
    let compressor = Compressor(level: 6)
    compressor.setInput(UnsafeBufferPointer(start: input, count: count))

    var total = 0
    while !compressor.isFinished {
        do {
            total += try compressor.deflate(into: scratch, count: scratchCount, ending: .finish)
        } catch {
            return -1
        }
    }
    return Int32(total)
}
SWIFT

for triple in "${BARE_TRIPLES[@]}"; do
    printf '  %-26s ' "$triple"

    rm -rf "$WORK/bare"
    assemble Zlib "$WORK/bare"
    cp "$WORK/bare.swift" "$WORK/bare/"

    if swiftc -target "$triple" -enable-experimental-feature Embedded -wmo \
        -parse-as-library -c "$WORK/bare"/*.swift -o "$WORK/bare/out.o" \
        > "$WORK/bare/build.log" 2>&1
    then
        echo "compiles ($(stat -c%s "$WORK/bare/out.o" 2>/dev/null || stat -f%z "$WORK/bare/out.o") bytes)"
    else
        echo "FAILED"
        grep -E 'error' "$WORK/bare/build.log" | head -5 || true
        status=1
    fi
done

exit $status
