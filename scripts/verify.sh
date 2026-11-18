#!/bin/bash
# Post-build checks: no 3rd-party deps, Apple-only linked frameworks, no telemetry strings, no wildcard listeners.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${LANTERN_SCRATCH:-$ROOT/.build}"
cd "$ROOT"
R=(); FAILS=0
SKIPS=0
# PASS and SKIP do not fail the run; anything else does. SKIP means "not checked", not "safe".
rec() { R+=("$1|$2|$3"); case "$2" in PASS) ;; SKIP) SKIPS=$((SKIPS+1));; *) FAILS=$((FAILS+1));; esac; }

# 1. dependencies
if [ -e Package.resolved ] && grep -q '"identity"' Package.resolved; then rec "no 3rd-party deps (Package.resolved)" FAIL "pins present"
else rec "no 3rd-party deps (Package.resolved)" PASS "none pinned"; fi
if grep -Eq '\.package\(|dependencies:\s*\[[^]]*\.package' Package.swift; then rec "no .package() in Package.swift" FAIL "found"
else rec "no .package() in Package.swift" PASS "none"; fi
if grep -rq 'XCRemoteSwiftPackageReference' Apps 2>/dev/null; then rec "no remote packages in xcodeproj" FAIL "found"
else rec "no remote packages in xcodeproj" PASS "none"; fi

# 2. linked frameworks Apple-only
HOST="$(find "$SCRATCH" -type f -name lantern-host -perm -u+x 2>/dev/null | head -1 || true)"
CLIENT="$(find "$SCRATCH" -type d -name LanternClient.app 2>/dev/null | head -1 || true)"
CBIN=""; [ -n "$CLIENT" ] && CBIN="$CLIENT/LanternClient"
for b in "$HOST" "$CBIN"; do
  [ -n "$b" ] || continue
  if [ ! -f "$b" ]; then rec "otool -L $(basename "$b")" FAIL "missing"; continue; fi
  BAD="$(otool -L "$b" | grep -E '^[[:space:]]' | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/|@rpath/(libswift|LanternClient\.debug\.dylib|__preview\.dylib))' || true)"
  if [ -z "$BAD" ]; then rec "otool -L $(basename "$b")" PASS "Apple system only"; else rec "otool -L $(basename "$b")" FAIL "$(echo "$BAD" | tr '\n' ' ')"; fi
done
[ -n "$HOST" ] || rec "lantern-host binary found" FAIL "run bootstrap.sh first"
[ -n "$CBIN" ] || rec "LanternClient.app found" FAIL "run bootstrap.sh first"

# 3. telemetry
if "$ROOT/scripts/check_no_telemetry.sh" >/tmp/lantern-telemetry.$$ 2>&1; then rec "check_no_telemetry.sh" PASS "clean"
else rec "check_no_telemetry.sh" FAIL "see below"; cat /tmp/lantern-telemetry.$$; fi
rm -f /tmp/lantern-telemetry.$$

# 4. listeners: inspects an ALREADY RUNNING lantern-host only (this script never starts it).
#    No host running => SKIP (nothing was checked). To check for real: start `lantern-host serve ...`
#    in another terminal, then run scripts/verify.sh again while it is up.
if pgrep -x lantern-host >/dev/null 2>&1; then
  L="$(lsof -nP -a -c lantern-host -i 2>/dev/null | grep -E 'LISTEN|UDP' || true)"
  if echo "$L" | grep -Eq '\*:[0-9]+|0\.0\.0\.0|\[::\]'; then rec "no wildcard listeners (lsof)" FAIL "$L"
  else rec "no wildcard listeners (lsof)" PASS "running host: no wildcard sockets"; fi
else
  rec "no wildcard listeners (lsof)" SKIP "lantern-host not running, nothing checked; re-run while serving"
fi

printf '\n%-40s %-6s %s\n' CHECK RESULT DETAIL
for r in "${R[@]}"; do IFS='|' read -r a b c <<<"$r"; printf '%-40s %-6s %s\n' "$a" "$b" "$c"; done
[ "$FAILS" -eq 0 ] && echo "OVERALL: PASS ($SKIPS skipped)" || { echo "OVERALL: FAIL ($FAILS)"; exit 1; }
