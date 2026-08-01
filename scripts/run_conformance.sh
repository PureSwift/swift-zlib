#!/usr/bin/env bash
# Builds Conformance/zconform.c twice — against the reference libz and against this library —
# and diffs what the two actually did.
#
# Lines beginning "SIZE:" are the one thing allowed to differ, because nothing requires two
# DEFLATE encoders to emit the same bytes. They are reported as a table so a regression in
# compression ratio is visible rather than silent. Everything else must match exactly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:-}"

if [[ -z "$BUILD" ]]; then
    BUILD="$(find "$ROOT/.build" -name 'libz.so*' -type f 2>/dev/null | head -1)"
fi

if [[ ! -f "$BUILD" ]]; then
    echo "no library to test; pass a path to libz.so or run 'swift build' first" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "reference: system libz"
echo "candidate: $BUILD"
echo

cc -O1 -o "$WORK/reference" "$ROOT/Conformance/zconform.c" -lz

# Against this library, the vendored header is the one to compile against, and the library is
# named on the command line directly rather than found by -lz.
cc -O1 -I "$ROOT/Sources/CZlib/include" -o "$WORK/candidate" \
    "$ROOT/Conformance/zconform.c" "$BUILD" -Wl,-rpath,"$(dirname "$BUILD")"

"$WORK/reference" > "$WORK/reference.out" 2> "$WORK/reference.err" || true
"$WORK/candidate" > "$WORK/candidate.out" 2> "$WORK/candidate.err" || true

if [[ -s "$WORK/candidate.err" ]]; then
    echo "candidate reported unimplemented entry points:"
    sed 's/^/  /' "$WORK/candidate.err"
    echo
fi

grep -v '^SIZE:' "$WORK/reference.out" > "$WORK/reference.cmp"
grep -v '^SIZE:' "$WORK/candidate.out" > "$WORK/candidate.cmp"

status=0
if diff -u "$WORK/reference.cmp" "$WORK/candidate.cmp" > "$WORK/diff"; then
    echo "behaviour: identical to the reference on every compared line"
else
    echo "behaviour: DIFFERS from the reference"
    sed 's/^/  /' "$WORK/diff"
    status=1
fi

echo
echo "compressed size vs reference:"
paste <(grep '^SIZE:' "$WORK/reference.out") <(grep '^SIZE:' "$WORK/candidate.out") |
    awk '{
        # Each SIZE line is "SIZE: <name> <level> <bytes> (bound <n>)", and paste puts the
        # reference line and ours side by side, so ours starts at field 7.
        name = $2; level = $3; ref = $4; ours = $10;
        ratio = ref > 0 ? ours / ref : 1;
        printf "  %-10s %-4s reference %10d   ours %10d   %+.1f%%\n",
               name, level, ref, ours, (ratio - 1) * 100;
    }'

exit $status
