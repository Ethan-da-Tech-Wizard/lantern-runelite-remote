#!/bin/bash
# Write a sha256 manifest of the source tree so a friend can compare. Usage: scripts/print_hashes.sh [outfile]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/MANIFEST.sha256}"
cd "$ROOT"
TMP="$(mktemp)"
find . -type f \
  -not -path './.build/*' -not -path './.git/*' -not -path '*/xcuserdata/*' -not -path '*/DerivedData/*' \
  -not -name '.DS_Store' -not -name 'MANIFEST.sha256' -not -name '*.log' \
  | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done > "$TMP"
cat "$TMP" > "$OUT"; rm -f "$TMP"
echo "files: $(wc -l < "$OUT" | tr -d ' ')"
echo "tree hash (sha256 of manifest): $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
echo "manifest: $OUT"
