#!/bin/bash
# Program: Lantern - print_hashes.sh
# Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
# Last Modified: 2026-11-18
# Purpose: Writes a SHA-256 manifest of the source files so others can compare copies.
#
# Write a sha256 manifest of the source tree so a friend can compare. Usage: scripts/print_hashes.sh [outfile]
# Safety settings: stop on errors, error on unset variables, and fail pipelines when any part fails.
set -euo pipefail
# Find the project folder (one level above scripts/) as an absolute path.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Output file: the first argument if given, otherwise MANIFEST.sha256 in the project folder.
OUT="${1:-$ROOT/MANIFEST.sha256}"
# Move into the project so file paths in the manifest are relative (./something) and comparable between machines.
cd "$ROOT"
# Make a temporary file to collect the list; we only replace the real manifest once it is complete.
TMP="$(mktemp)"
# List every file in the project, but skip build output, git data, user-specific Xcode folders, Finder junk,
# the manifest itself and log files, because those differ per machine or change every run.
# Then sort in a fixed (C locale) order so everyone gets the same ordering, and print each file's SHA-256 fingerprint.
find . -type f \
  -not -path './.build/*' -not -path './.git/*' -not -path '*/xcuserdata/*' -not -path '*/DerivedData/*' \
  -not -name '.DS_Store' -not -name 'MANIFEST.sha256' -not -name '*.log' \
  | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done > "$TMP"
# Copy the finished list into the output file and delete the temp file.
cat "$TMP" > "$OUT"; rm -f "$TMP"
# Report how many files were hashed (wc -l counts lines; tr removes padding spaces).
echo "files: $(wc -l < "$OUT" | tr -d ' ')"
# The 'tree hash' is one fingerprint of the whole manifest: if two people get the same value, their trees match.
echo "tree hash (sha256 of manifest): $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
# Tell the user where the manifest was written.
echo "manifest: $OUT"
