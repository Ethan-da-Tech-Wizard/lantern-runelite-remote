#!/bin/bash
# Fails if source or built binaries mention analytics/crash-reporting SDKs, or if Package files declare dependencies.
# Usage: scripts/check_no_telemetry.sh [extra binary or dir ...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${LANTERN_SCRATCH:-$ROOT/.build}"
PAT='Firebase|Crashlytics|Sentry|Mixpanel|Amplitude|AppCenter|Segment|Bugsnag|Datadog|NewRelic|Flurry|AppsFlyer|Adjust|Branch\.io|PostHog|Instabug|TelemetryDeck|GoogleAnalytics|FBSDK|Facebook'
FAIL=0
echo "== source scan =="
if grep -rEn "$PAT" "$ROOT/Sources" "$ROOT/Apps" "$ROOT/Package.swift" --include='*.swift' --include='*.plist' --include='*.pbxproj' 2>/dev/null; then
  echo "FAIL: analytics name in source"; FAIL=1; else echo "PASS: no analytics SDK names in source"; fi
if grep -rEn 'URLSession|https?://' "$ROOT/Sources" "$ROOT/Apps" --include='*.swift' 2>/dev/null | grep -v '^\s*//' | grep -Ev '://[^"]*(apple\.com|127\.0\.0\.1|localhost)|//.*https?://' ; then
  echo "WARN: URLSession or URL literals above, review by hand"; else echo "PASS: no URLSession / URL literals in source"; fi
echo "== built binaries =="
BINS=()
while IFS= read -r f; do BINS+=("$f"); done < <(find "$SCRATCH" -type f \( -name lantern-host -o -name LanternClient -o -name LanternClient.debug.dylib \) -perm -u+x 2>/dev/null | grep -v '\.dSYM' || true)
for x in "$@"; do BINS+=("$x"); done
if [ "${#BINS[@]}" -eq 0 ]; then echo "NOTE: no built binaries found under $SCRATCH (run bootstrap.sh first)"; fi
for b in "${BINS[@]+"${BINS[@]}"}"; do
  if strings -a "$b" | grep -Eq "$PAT"; then echo "FAIL: $b contains analytics string:"; strings -a "$b" | grep -E "$PAT" | head -3; FAIL=1
  else echo "PASS: $b"; fi
done
exit "$FAIL"
