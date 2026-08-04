#!/usr/bin/env bash
# Times this library against the reference, side by side, and prints the ratio.
#
# Usage: scripts/run_benchmark.sh [path/to/libz.so.1.3.1]
#
# The numbers are measurements, not checks: this script always exits 0 (unless a build or a
# round trip fails outright), because a timing on a shared machine is not something to gate a
# merge on. What it is for is leaving a number next to every change, so a regression is
# something noticed rather than reconstructed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-}"

if [[ -z "$BUILD" ]]; then
    BUILD=$(ls -t "$ROOT"/build/cmake/libz.so.1.3.1 2>/dev/null | head -1 || true)
fi
if [[ -z "$BUILD" || ! -f "$BUILD" ]]; then
    echo "run_benchmark: no candidate library; build with cmake first" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cc -O2 -o "$WORK/reference" "$ROOT/Conformance/zbench.c" -lz
cc -O2 -I "$ROOT/Sources/CZlib/include" -o "$WORK/candidate" \
    "$ROOT/Conformance/zbench.c" "$BUILD" -Wl,-rpath,"$(dirname "$BUILD")"

echo "reference: $("$WORK/reference" | head -1)"
echo "candidate: $BUILD"
echo

"$WORK/reference" | grep '^BENCH' > "$WORK/reference.bench"
"$WORK/candidate" | grep '^BENCH' > "$WORK/candidate.bench"

paste "$WORK/reference.bench" "$WORK/candidate.bench" | awk -F'\t' '{
    split($1, r, /[ ]+/); split($2, c, /[ ]+/);
    # BENCH <op> <payload> [L<n>] <MB/s> MB/s -- the number is the next-to-last field.
    n1 = split($1, r, /[ ]+/); n2 = split($2, c, /[ ]+/);
    label = r[2] " " r[3]; if (n1 == 6) label = label " " r[4];
    ref = r[n1 - 1] + 0; ours = c[n2 - 1] + 0;
    ratio = ref > 0 ? ours / ref : 0;
    printf "  %-22s reference %8.1f MB/s   ours %8.1f MB/s   %5.2fx\n",
           label, ref, ours, ratio;
}'
