#!/usr/bin/env bash
# Asserts that the built library publishes exactly the reference's API — no symbol missing, and
# nothing extra.
#
# The "nothing extra" half is the one that needs a check rather than a review. A Swift library
# exports hundreds of names beyond its own API, and they are hidden here by pattern; a pattern
# that stops matching leaks an implementation detail into the public ABI, where a client can
# bind to it and where removing it later is a break. That failure is invisible without this.
#
# Symbol versions are compared too, not just names: a client records the node its symbol came
# from, and a definition under the wrong node does not satisfy it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${1:-$ROOT/build/cmake/libz.so.1.3.1}"

if [[ ! -f "$LIB" ]]; then
    echo "no library at $LIB; build with cmake first" >&2
    exit 1
fi

echo "checking: $LIB"

python3 - "$LIB" "$ROOT/scripts/symbols.txt" <<'PY'
import subprocess
import sys

lib, symbols_path = sys.argv[1], sys.argv[2]

# What the reference says the API is, name and version node together.
want = {}
node = None
for line in open(symbols_path):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("[") and line.endswith("]"):
        node = line[1:-1]
        continue
    want[line] = node

# What the library actually publishes.
out = subprocess.run(
    ["nm", "-D", "--with-symbol-versions", "--defined-only", lib],
    capture_output=True, text=True, check=True,
).stdout

have = {}
for line in out.splitlines():
    fields = line.split()
    if len(fields) != 3 or fields[1] != "T":
        continue
    name = fields[2]
    if "@@" in name:
        name, _, version = name.partition("@@")
    elif "@" in name:
        name, _, version = name.partition("@")
    else:
        version = "(unversioned)"
    have[name] = version

missing = sorted(set(want) - set(have))
extra = sorted(set(have) - set(want))
mismatched = sorted(
    (name, want[name], have[name]) for name in set(want) & set(have)
    if want[name] != have[name]
)

print(f"  reference API:  {len(want)} symbols")
print(f"  library exports: {len(have)} symbols")

status = 0

if missing:
    print(f"  MISSING ({len(missing)}): {' '.join(missing)}")
    status = 1

if extra:
    print(f"  LEAKED ({len(extra)}): {' '.join(extra[:20])}"
          + (" ..." if len(extra) > 20 else ""))
    status = 1

if mismatched:
    print(f"  WRONG VERSION NODE ({len(mismatched)}):")
    for name, expected, actual in mismatched:
        print(f"    {name}: expected {expected}, got {actual}")
    status = 1

if status == 0:
    print("  exactly the reference API, under the reference's version nodes")

sys.exit(status)
PY
