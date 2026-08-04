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
    # The newest, not the first found: debug and release builds sit side by side, and testing
    # whichever the filesystem listed first means quietly testing a stale library and trusting
    # the result.
    BUILD="$(find "$ROOT/.build" -name 'libz.so*' -type f -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | head -1 | cut -d' ' -f2-)"
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

: > "$WORK/reference.out"
: > "$WORK/candidate.out"
: > "$WORK/reference.err"
: > "$WORK/candidate.err"

for program in zconform zstream zgzfile zdict; do
    cc -O1 -o "$WORK/reference" "$ROOT/Conformance/$program.c" -lz

    # Against this library, the vendored header is the one to compile against, and the library
    # is named on the command line directly rather than found by -lz.
    cc -O1 -I "$ROOT/Sources/CZlib/include" -o "$WORK/candidate" \
        "$ROOT/Conformance/$program.c" "$BUILD" -Wl,-rpath,"$(dirname "$BUILD")"

    echo "== $program ==" | tee -a "$WORK/reference.out" >> "$WORK/candidate.out"

    # Each build gets its own directory to write into, so one cannot read a file the other
    # left behind and call it a pass.
    mkdir -p "$WORK/files-reference" "$WORK/files-candidate"

    "$WORK/reference" "$WORK/files-reference" \
        >> "$WORK/reference.out" 2>> "$WORK/reference.err" || true
    "$WORK/candidate" "$WORK/files-candidate" \
        >> "$WORK/candidate.out" 2>> "$WORK/candidate.err" || true
done

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
    awk -F'\t' '{
        # paste holds the reference line and ours apart with a tab. The lines themselves come
        # in more than one shape — "SIZE: <name> <level> <bytes> (bound <n>)" from zstream,
        # "SIZE: <name> <level> <bytes>" and "SIZE: <name> <bytes>" from zgzfile — so the
        # bytes are found by looking, not counted to by position.
        split($1, a, /[ ]+/); split($2, b, /[ ]+/);
        name = a[2];
        if (a[3] ~ /^[0-9]+$/) { level = "";   ref = a[3] + 0; ours = b[3] + 0 }
        else                   { level = a[3]; ref = a[4] + 0; ours = b[4] + 0 }
        ratio = ref > 0 ? ours / ref : 1;
        printf "  %-10s %-4s reference %10d   ours %10d   %+.1f%%\n",
               name, level, ref, ours, (ratio - 1) * 100;
    }'

exit $status
