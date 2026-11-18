#!/bin/bash
# ==============================================================================
# Program: verify.sh
# Programmer: Ethan-da-Tech-Wizard
# Course: CIS 156 / Advanced Systems
# Last Modified: November 18, 2026
# Purpose: Post-build security and integrity verification test suite.
#          Inputs: Build artifacts, Package.resolved, and binary executables.
#          Outputs: Verification report verifying zero external dependencies, Apple-only frameworks, and clean socket bindings.
#          Design Rationale: Enforces strict software supply chain security and project guardrails automatically.
# ==============================================================================
# Post-build checks: no 3rd-party deps, Apple-only linked frameworks, no telemetry strings, no wildcard listeners.
# Safety settings: stop on errors, error on unset variables, fail pipelines when any part fails.
set -euo pipefail
# Find the project folder (one level above scripts/) as an absolute path.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Where built programs live; the user may override with LANTERN_SCRATCH.
SCRATCH="${LANTERN_SCRATCH:-$ROOT/.build}"
# Work from the project folder.
cd "$ROOT"
# R = list of result rows; FAILS counts failures.
R=(); FAILS=0
SKIPS=0
# PASS and SKIP do not fail the run; anything else does. SKIP means "not checked", not "safe".
# rec = record a result row. PASS does nothing extra, SKIP is counted separately, anything else counts as a failure.
rec() { R+=("$1|$2|$3"); case "$2" in PASS) ;; SKIP) SKIPS=$((SKIPS+1));; *) FAILS=$((FAILS+1));; esac; }

# ===== CHECK 1: no third-party dependencies =====
# 1. dependencies
# If a lock file lists any pinned packages, someone added an outside library, which we do not allow.
if [ -e Package.resolved ] && grep -q '"identity"' Package.resolved; then rec "no 3rd-party deps (Package.resolved)" FAIL "pins present"
else rec "no 3rd-party deps (Package.resolved)" PASS "none pinned"; fi
# Also check the package manifest for a .package( declaration, which is how outside libraries are added.
if grep -Eq '\.package\(|dependencies:\s*\[[^]]*\.package' Package.swift; then rec "no .package() in Package.swift" FAIL "found"
else rec "no .package() in Package.swift" PASS "none"; fi
# And check the Xcode project for remote package references.
if grep -rq 'XCRemoteSwiftPackageReference' Apps 2>/dev/null; then rec "no remote packages in xcodeproj" FAIL "found"
else rec "no remote packages in xcodeproj" PASS "none"; fi

# ===== CHECK 2: built programs link only to Apple's own libraries =====
# 2. linked frameworks Apple-only
# Locate the built Mac host program (first match only). '|| true' avoids stopping if nothing is found.
HOST="$(find "$SCRATCH" -type f -name lantern-host -perm -u+x 2>/dev/null | head -1 || true)"
# Locate the built iPhone app folder the same way.
CLIENT="$(find "$SCRATCH" -type d -name LanternClient.app 2>/dev/null | head -1 || true)"
# The app's main program lives inside that folder; leave it empty if the app was not found.
CBIN=""; [ -n "$CLIENT" ] && CBIN="$CLIENT/LanternClient"
# Loop over both programs.
for b in "$HOST" "$CBIN"; do
  # Skip an empty entry (that program was not built; reported below).
  [ -n "$b" ] || continue
  # If the file is not really there, record a FAIL and go on to the next one.
  if [ ! -f "$b" ]; then rec "otool -L $(basename "$b")" FAIL "missing"; continue; fi
  # 'otool -L' lists libraries the program links to. Keep the library paths and filter out the allowed ones
  # (system folders and Swift/debug helpers); whatever is left is suspicious and goes in BAD.
  BAD="$(otool -L "$b" | grep -E '^[[:space:]]' | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/|@rpath/(libswift|LanternClient\.debug\.dylib|__preview\.dylib))' || true)"
  # Nothing left over = PASS; otherwise FAIL and list the offenders on one line.
  if [ -z "$BAD" ]; then rec "otool -L $(basename "$b")" PASS "Apple system only"; else rec "otool -L $(basename "$b")" FAIL "$(echo "$BAD" | tr '\n' ' ')"; fi
done
# If a program was never found, fail with advice to build first.
[ -n "$HOST" ] || rec "lantern-host binary found" FAIL "run bootstrap.sh first"
[ -n "$CBIN" ] || rec "LanternClient.app found" FAIL "run bootstrap.sh first"

# ===== CHECK 3: telemetry scan =====
# 3. telemetry
# Run the telemetry checker with its output saved in a temp file ($$ = this script's process number, to keep the name unique).
if "$ROOT/scripts/check_no_telemetry.sh" >/tmp/lantern-telemetry.$$ 2>&1; then rec "check_no_telemetry.sh" PASS "clean"
else rec "check_no_telemetry.sh" FAIL "see below"; cat /tmp/lantern-telemetry.$$; fi
# Remove the temp file.
rm -f /tmp/lantern-telemetry.$$

# ===== CHECK 4: network listeners =====
# 4. listeners: inspects an ALREADY RUNNING lantern-host only (this script never starts it).
#    No host running => SKIP (nothing was checked). To check for real: start `lantern-host serve ...`
#    in another terminal, then run scripts/verify.sh again while it is up.
# pgrep -x looks for a running process with exactly this name.
if pgrep -x lantern-host >/dev/null 2>&1; then
  # 'lsof' lists network sockets owned by the host; keep only listening TCP or UDP ones.
  L="$(lsof -nP -a -c lantern-host -i 2>/dev/null | grep -E 'LISTEN|UDP' || true)"
  # A wildcard address (any interface) would expose the host to the whole network, so that is a FAIL.
  if echo "$L" | grep -Eq '\*:[0-9]+|0\.0\.0\.0|\[::\]'; then rec "no wildcard listeners (lsof)" FAIL "$L"
  else rec "no wildcard listeners (lsof)" PASS "running host: no wildcard sockets"; fi
# Host not running: we could not check, so record SKIP rather than pretend it is safe.
else
  rec "no wildcard listeners (lsof)" SKIP "lantern-host not running, nothing checked; re-run while serving"
fi

# ===== Final report: print the table and verdict =====
printf '\n%-40s %-6s %s\n' CHECK RESULT DETAIL
# Print each saved row, split at the '|' marks, in aligned columns.
for r in "${R[@]}"; do IFS='|' read -r a b c <<<"$r"; printf '%-40s %-6s %s\n' "$a" "$b" "$c"; done
# Exit 0 and say PASS if no failures, otherwise say FAIL and exit 1.
[ "$FAILS" -eq 0 ] && echo "OVERALL: PASS ($SKIPS skipped)" || { echo "OVERALL: FAIL ($FAILS)"; exit 1; }
