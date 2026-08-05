#!/usr/bin/env bash
# Differential fuzz of inflate against the reference, and a gate unlike the benchmark:
# a disagreement here is a bug in one of the two libraries, not a timing.
#
# Usage: scripts/run_fuzz.sh [path/to/libz.so.1.3.1] [seed]
#
# The reference generates a batch of streams - mixed payloads, levels and framings, a share
# of them bit-flipped or truncated - and both libraries decode every one under six
# input/output chunking patterns. The seed defaults to the clock, so every run fuzzes new
# streams; it is printed first, and re-running with the printed seed reproduces the batch.
#
# What must agree, per stream and pattern:
#   - the verdict: accepted (Z_STREAM_END), rejected (which error), or still incomplete -
#     with Z_OK and Z_BUF_ERROR counted as one verdict, since which of the two a decoder
#     reports while starved for input is not part of the contract;
#   - for accepted streams, the output: length and bytes, exactly.
# What may differ: how many bytes came out before an error was reported - two decoders may
# discover the same corruption at different distances into their own read-ahead - and the
# interleaving of intermediate return codes on the way.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-}"
SEED="${2:-$(date +%s)}"

if [[ -z "$BUILD" ]]; then
    BUILD=$(ls -t "$ROOT"/build/cmake/libz.so.1.3.1 2>/dev/null | head -1 || true)
fi
if [[ -z "$BUILD" || ! -f "$BUILD" ]]; then
    echo "run_fuzz: no candidate library; build with cmake first" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cc -O2 -o "$WORK/reference" "$ROOT/Conformance/zfuzz.c" -lz
cc -O2 -I "$ROOT/Sources/CZlib/include" -o "$WORK/candidate" \
    "$ROOT/Conformance/zfuzz.c" "$BUILD" -Wl,-rpath,"$(dirname "$BUILD")"

mkdir "$WORK/streams"
"$WORK/reference" gen "$WORK/streams" "$SEED"

"$WORK/reference" check "$WORK/streams" > "$WORK/reference.out"
"$WORK/candidate" check "$WORK/streams" > "$WORK/candidate.out"

if [[ "$(wc -l < "$WORK/reference.out")" != "$(wc -l < "$WORK/candidate.out")" ]]; then
    echo "run_fuzz: the two checks printed different numbers of lines" >&2
    exit 1
fi

paste "$WORK/reference.out" "$WORK/candidate.out" | awk '
    function verdict(rc) {
        # rc0 (Z_OK) and rc-5 (Z_BUF_ERROR) are both "incomplete": which one a decoder
        # reports while starved for input is not part of the contract.
        return (rc == "rc0" || rc == "rc-5") ? "incomplete" : rc;
    }
    {
        if ($1 != $7 || $2 != $8) {
            print "misaligned:", $0; bad++; next;
        }
        if (verdict($3) != verdict($9)) {
            print "verdict differs:", $0; bad++; next;
        }
        if ($3 == "rc1" && ($4 != $10 || $6 != $12)) {
            print "accepted stream decodes differently:", $0; bad++; next;
        }
        checked++;
    }
    END {
        printf "  %d probes compared, %d disagreements\n", checked + bad, bad;
        exit bad > 0 ? 1 : 0;
    }
'
