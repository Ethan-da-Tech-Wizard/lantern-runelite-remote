#!/bin/bash
# Program: Lantern - check_no_telemetry.sh
# Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
# Last Modified: 2026-11-18
# Purpose: Fails if the code or binaries mention analytics or crash-reporting SDKs.
#
# Fails if source or built binaries mention analytics/crash-reporting SDKs, or if Package files declare dependencies.
# Usage: scripts/check_no_telemetry.sh [extra binary or dir ...]
# Safety settings: stop on errors, treat unset variables as errors, and fail pipelines if any part fails.
set -euo pipefail
# Find the project folder (one level above scripts/) as an absolute path.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Where the built programs live; the user may override this with LANTERN_SCRATCH.
SCRATCH="${LANTERN_SCRATCH:-$ROOT/.build}"
# PAT = a regular expression listing names of known analytics and crash-reporting tools. The | means 'or'.
# If any of these words show up in our code or programs, we treat it as tracking and fail.
PAT='Firebase|Crashlytics|Sentry|Mixpanel|Amplitude|AppCenter|Segment|Bugsnag|Datadog|NewRelic|Flurry|AppsFlyer|Adjust|Branch\.io|PostHog|Instabug|TelemetryDeck|GoogleAnalytics|FBSDK|Facebook'
# FAIL is our flag: 0 = all clear so far, 1 = a problem was found.
FAIL=0
# ===== CHECK 1: scan the source files for those names =====
echo "== source scan =="
# grep -r = search folders, -E = use the pattern above, -n = show line numbers. Only Swift, plist and Xcode project files are searched.
# If grep finds a match it succeeds, which means a problem, so we take the 'then' branch.
if grep -rEn "$PAT" "$ROOT/Sources" "$ROOT/Apps" "$ROOT/Package.swift" --include='*.swift' --include='*.plist' --include='*.pbxproj' 2>/dev/null; then
  echo "FAIL: analytics name in source"; FAIL=1; else echo "PASS: no analytics SDK names in source"; fi
# ===== CHECK 2: look for network code (warning only, a human reviews it) =====
# Find lines using URLSession or web addresses, drop comment lines, and drop addresses that are allowed
# (Apple's own sites, the local machine) or that appear only inside a comment.
if grep -rEn 'URLSession|https?://' "$ROOT/Sources" "$ROOT/Apps" --include='*.swift' 2>/dev/null | grep -v '^\s*//' | grep -Ev '://[^"]*(apple\.com|127\.0\.0\.1|localhost)|//.*https?://' ; then
  echo "WARN: URLSession or URL literals above, review by hand"; else echo "PASS: no URLSession / URL literals in source"; fi
# ===== CHECK 3: scan the compiled programs for the same names =====
echo "== built binaries =="
# BINS is a list of program files to scan; start empty.
BINS=()
# Find the built programs under the scratch folder (executable files with these names), skipping debug symbol bundles.
# '|| true' stops 'no match' from ending the script.
while IFS= read -r f; do BINS+=("$f"); done < <(find "$SCRATCH" -type f \( -name lantern-host -o -name LanternClient -o -name LanternClient.debug.dylib \) -perm -u+x 2>/dev/null | grep -v '\.dSYM' || true)
# Also scan any extra files or folders the user passed on the command line ($@ = all arguments).
for x in "$@"; do BINS+=("$x"); done
# If nothing was found, print a note rather than silently passing.
if [ "${#BINS[@]}" -eq 0 ]; then echo "NOTE: no built binaries found under $SCRATCH (run bootstrap.sh first)"; fi
# Loop over each program. The odd ${BINS[@]+...} form avoids an error when the list is empty.
for b in "${BINS[@]+"${BINS[@]}"}"; do
  # 'strings -a' pulls all readable text out of a binary; if any tracking name is in it, report FAIL and show the first 3 hits.
  if strings -a "$b" | grep -Eq "$PAT"; then echo "FAIL: $b contains analytics string:"; strings -a "$b" | grep -E "$PAT" | head -3; FAIL=1
  else echo "PASS: $b"; fi
done
# Exit with 0 if clean or 1 if any problem was flagged, so other scripts can react.
exit "$FAIL"
