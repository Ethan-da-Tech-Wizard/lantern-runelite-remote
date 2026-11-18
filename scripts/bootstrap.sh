#!/bin/bash
# One-command setup check + build for a fresh Mac. Read-only preflight, then build and test.
# NEVER installs anything, never uses sudo, never pipes downloads into a shell.
# Env: LANTERN_SCRATCH = build scratch dir (default ./.build under the project)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SCRATCH="${LANTERN_SCRATCH:-$ROOT/.build}"
mkdir -p "$SCRATCH"
LOG="$SCRATCH/bootstrap-logs"; mkdir -p "$LOG"

if [ "$(id -u)" = "0" ]; then echo "Refusing to run as root. Run as your normal user, without sudo."; exit 2; fi

RESULTS=(); FAILS=0; MISSING=()
rec() { RESULTS+=("$1|$2|$3"); [ "$2" = "PASS" ] || FAILS=$((FAILS+1)); }

echo "== Preflight (read-only) =="
# macOS
OSV="$(sw_vers -productVersion 2>/dev/null || echo unknown)"; OSMAJ="${OSV%%.*}"
if [ "$(uname -s)" = "Darwin" ] && [ "$OSMAJ" -ge 14 ] 2>/dev/null; then rec "macOS >= 14" PASS "$OSV"
else rec "macOS >= 14" FAIL "found $OSV"; MISSING+=("macOS 14 or newer is required. Update in System Settings > General > Software Update."); fi
# Apple Silicon
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then rec "Apple Silicon" PASS "$ARCH"
else rec "Apple Silicon" FAIL "$ARCH"; MISSING+=("Apple Silicon (M-series) is expected; Intel is untested."); fi
# Xcode
XCODE_OK=0
if xcode-select -p >/dev/null 2>&1; then rec "Command Line Tools path" PASS "$(xcode-select -p)"
else rec "Command Line Tools path" FAIL "none"; MISSING+=("Run: xcode-select --install   (Apple's own installer dialog)"); fi
if XV="$(xcodebuild -version 2>&1)"; then
  rec "xcodebuild -version" PASS "$(echo "$XV" | tr '\n' ' ')"; XCODE_OK=1
else
  rec "xcodebuild -version" FAIL "full Xcode not usable"
  MISSING+=("Install Xcode from the Mac App Store (free), open it once, accept the license. If installed, run: xcode-select -s /Applications/Xcode.app/Contents/Developer (needs your admin password; do it yourself).")
fi
if SV="$(swift --version 2>&1 | head -1)" && [ -n "$SV" ] && echo "$SV" | grep -q -i swift; then rec "swift --version" PASS "$SV"
else rec "swift --version" FAIL "swift not found"; MISSING+=("swift comes with Xcode / Command Line Tools; see above."); fi
# Disk (need ~5 GB)
FREE_KB="$(df -k "$SCRATCH" | awk 'NR==2{print $4}')"
FREE_GB=$((FREE_KB/1024/1024))
MING="${LANTERN_MIN_GB:-5}"
if [ "$FREE_GB" -ge "$MING" ]; then rec "Free disk >= ${MING} GB" PASS "${FREE_GB} GB"
else rec "Free disk >= ${MING} GB" FAIL "${FREE_GB} GB"; MISSING+=("Free up disk space (need about 5 GB; override with LANTERN_MIN_GB=1 at your own risk)."); fi
# iOS simulator SDK
if [ "$XCODE_OK" = 1 ] && xcodebuild -showsdks 2>/dev/null | grep -q iphonesimulator; then rec "iOS Simulator SDK" PASS "present"
else rec "iOS Simulator SDK" FAIL "missing"; MISSING+=("In Xcode > Settings > Components, download the iOS platform/simulator."); fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo; echo "== What is missing and how to fix =="
  for m in "${MISSING[@]}"; do echo " - $m"; done
fi

table() {
  echo; echo "== Result table =="
  printf '%-32s %-6s %s\n' STEP RESULT DETAIL
  for r in "${RESULTS[@]}"; do IFS='|' read -r a b c <<<"$r"; printf '%-32s %-6s %s\n' "$a" "$b" "$c"; done
}
if [ "$FAILS" -gt 0 ]; then
  table; echo; echo "OVERALL: FAIL (preflight). Nothing was built. Fix the items above and re-run."; exit 1
fi

step() { # name, logfile, cmd...
  local name="$1" lf="$LOG/$2.log"; shift 2
  echo "== $name =="
  if "$@" >"$lf" 2>&1; then rec "$name" PASS "log: $lf"; else rec "$name" FAIL "see $lf"; tail -n 15 "$lf"; fi
}
step "swift build (package)" build swift build --scratch-path "$SCRATCH/swift"
step "swift test" test swift test --scratch-path "$SCRATCH/swift"
step "macOS host CLI (lantern-host)" host swift build --scratch-path "$SCRATCH/swift" --product lantern-host
step "iOS client (simulator)" ios "$ROOT/scripts/build_ios_sim.sh" "$SCRATCH/dd-client"
if [ -f "$LOG/test.log" ]; then grep -E "Executed [0-9]+ tests|Test run with" "$LOG/test.log" | tail -n 2 || true; fi

table
cat <<'NEXT'

== Next manual steps (nothing here is automatic) ==
1. Screen Recording: System Settings > Privacy & Security > Screen & System Audio Recording > allow the app you run lantern-host from (Terminal). Restart that app.
2. Accessibility: System Settings > Privacy & Security > Accessibility > allow the same app (needed for touch to mouse).
3. Real iPhone: open Apps/LanternClient/LanternClient.xcodeproj in Xcode, Signing & Capabilities,
   Team = your own personal team (Xcode > Settings > Accounts > add your own Apple ID; free).
4. Change the bundle id from org.twu.lantern.client to your own, e.g. com.yourname.lantern.client.
5. Run scripts/verify.sh, then scripts/print_hashes.sh and compare with the sender's manifest.
NEXT
if [ "$FAILS" -gt 0 ]; then echo "OVERALL: FAIL ($FAILS step(s))"; exit 1; fi
echo "OVERALL: PASS"
