#!/usr/bin/env bash
# Compresses a corpus with both libraries and compares sizes, verifying every file in both
# directions on the way past.
#
# Round trips through this library alone would not catch a stream that only this library can
# read, so each file is compressed here and decompressed by the reference, and compressed by
# the reference and decompressed here.
#
# Usage: check_corpus.sh <directory> [level]
#
# The Canterbury and Silesia corpora are the usual ones; neither is vendored, both being large
# and neither being this project's to redistribute.
#
#   curl -O https://corpus.canterbury.ac.nz/resources/cantrbry.tar.gz
#   curl -O https://sun.aei.polsl.pl//~sdeor/corpus/silesia.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${1:-}"
LEVEL="${2:-6}"

if [[ -z "$CORPUS" || ! -d "$CORPUS" ]]; then
    echo "usage: $0 <corpus-directory> [level]" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One program to compress and one to decompress, each built against this library, so the
# comparison is against the real artifact rather than against a Swift test harness.
cat > "$WORK/tool.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
int main(int argc, char **argv) {
    int level = argc > 2 ? atoi(argv[2]) : 6;
    size_t cap = 1 << 20, len = 0;
    unsigned char *in = malloc(cap), *out;
    size_t got;
    while ((got = fread(in + len, 1, cap - len, stdin)) > 0) {
        len += got;
        if (len == cap) { cap <<= 1; in = realloc(in, cap); }
    }
    if (strcmp(argv[1], "c") == 0) {
        uLong bound = compressBound((uLong)len);
        out = malloc(bound);
        uLong outlen = bound;
        if (compress2(out, &outlen, in, (uLong)len, level) != Z_OK) return 1;
        fwrite(out, 1, outlen, stdout);
    } else {
        size_t outcap = len * 20 + (1 << 20);
        out = malloc(outcap);
        uLong outlen = (uLong)outcap;
        if (uncompress(out, &outlen, in, (uLong)len) != Z_OK) return 1;
        fwrite(out, 1, outlen, stdout);
    }
    return 0;
}
EOF

BUILD="$(find "$ROOT/build" "$ROOT/.build" -name 'libz.so*' -type f 2>/dev/null |
    xargs -r ls -t 2>/dev/null | head -1)"

if [[ -z "$BUILD" ]]; then
    echo "no built library found; run cmake or swift build first" >&2
    exit 1
fi

cc -O2 -I "$ROOT/Sources/CZlib/include" -o "$WORK/ours" "$WORK/tool.c" "$BUILD" \
    -Wl,-rpath,"$(dirname "$BUILD")"
cc -O2 -o "$WORK/ref" "$WORK/tool.c" -lz

printf '%-16s %10s %10s %10s %8s  %s\n' file bytes ours zlib delta verify

total_raw=0 total_ours=0 total_ref=0 failures=0

for file in "$CORPUS"/*; do
    [[ -f "$file" ]] || continue

    raw=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")

    "$WORK/ours" c "$LEVEL" < "$file" > "$WORK/o.z"
    "$WORK/ref"  c "$LEVEL" < "$file" > "$WORK/r.z"

    ours=$(stat -c%s "$WORK/o.z" 2>/dev/null || stat -f%z "$WORK/o.z")
    ref=$(stat -c%s "$WORK/r.z" 2>/dev/null || stat -f%z "$WORK/r.z")

    # Each library's output read by the other, which is the property that matters.
    verify=ok
    "$WORK/ref"  d < "$WORK/o.z" | cmp -s - "$file" || verify=OURS-UNREADABLE
    "$WORK/ours" d < "$WORK/r.z" | cmp -s - "$file" || verify=THEIRS-UNREADABLE

    [[ "$verify" == ok ]] || failures=$((failures + 1))

    delta=$(awk -v a="$ours" -v b="$ref" 'BEGIN { printf "%+.2f%%", (a / b - 1) * 100 }')
    printf '%-16s %10d %10d %10d %8s  %s\n' "$(basename "$file")" "$raw" "$ours" "$ref" "$delta" "$verify"

    total_raw=$((total_raw + raw))
    total_ours=$((total_ours + ours))
    total_ref=$((total_ref + ref))
done

delta=$(awk -v a="$total_ours" -v b="$total_ref" 'BEGIN { printf "%+.2f%%", (a / b - 1) * 100 }')
printf '%-16s %10d %10d %10d %8s  %s\n' TOTAL "$total_raw" "$total_ours" "$total_ref" "$delta" \
    "$([[ $failures -eq 0 ]] && echo 'all verified' || echo "$failures FAILURES")"

exit $((failures > 0))
