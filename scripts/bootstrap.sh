#!/bin/bash
# Program: Lantern - bootstrap.sh
# Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
# Last Modified: 2026-11-18
# Purpose: One-command setup check, build and test for a fresh Mac.
#
# One-command setup check + build for a fresh Mac. Read-only preflight, then build and test.
# NEVER installs anything, never uses sudo, never pipes downloads into a shell.
# Env: LANTERN_SCRATCH = build scratch dir (default ./.build under the project)
# ===== SECTION 1: Safety settings and basic setup =====
# -e: stop on the first failing command. -u: using an unset variable is an error.
# -o pipefail: a pipeline fails if ANY part of it fails, not just the last part.
set -euo pipefail
# Work out where the project folder is: this script lives in scripts/, so go one folder up.
# 'cd ... && pwd' turns that into a full absolute path we can trust.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Move into the project folder so every relative path below starts from the same place.
cd "$ROOT"
# Scratch folder for build output. If the user set LANTERN_SCRATCH use it, otherwise use .build.
SCRATCH="${LANTERN_SCRATCH:-$ROOT/.build}"
# Make the scratch folder (-p means: no error if it already exists).
mkdir -p "$SCRATCH"
# Folder for log files from each build step, so we can read them later if something fails.
LOG="$SCRATCH/bootstrap-logs"; mkdir -p "$LOG"

# Safety rule: building as root (administrator) is risky, so refuse. 'id -u' prints the user number; 0 means root.
if [ "$(id -u)" = "0" ]; then echo "Refusing to run as root. Run as your normal user, without sudo."; exit 2; fi

# Bookkeeping: RESULTS holds one row per check, FAILS counts failures, MISSING holds fix-it advice for the user.
RESULTS=(); FAILS=0; MISSING=()
# rec = 'record a result'. Arguments: step name, PASS or FAIL, detail text.
# It saves the row as name|result|detail and adds 1 to FAILS if the result is not PASS.
rec() { RESULTS+=("$1|$2|$3"); [ "$2" = "PASS" ] || FAILS=$((FAILS+1)); }

# ===== SECTION 2: Preflight checks (read-only, nothing is changed on the Mac) =====
echo "== Preflight (read-only) =="
# --- Check: macOS version ---
# macOS
# Ask macOS for its version (or 'unknown' if that fails), then keep only the part before the first dot (the major number).
OSV="$(sw_vers -productVersion 2>/dev/null || echo unknown)"; OSMAJ="${OSV%%.*}"
# Pass if this is a Mac (Darwin) and the major version is 14 or higher. 2>/dev/null hides errors if the test cannot compare.
if [ "$(uname -s)" = "Darwin" ] && [ "$OSMAJ" -ge 14 ] 2>/dev/null; then rec "macOS >= 14" PASS "$OSV"
# Otherwise record a FAIL and remember a plain-English fix for the user.
else rec "macOS >= 14" FAIL "found $OSV"; MISSING+=("macOS 14 or newer is required. Update in System Settings > General > Software Update."); fi
# --- Check: Apple Silicon chip ---
# Apple Silicon
# 'uname -m' prints the chip type; arm64 means an Apple Silicon (M-series) Mac.
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then rec "Apple Silicon" PASS "$ARCH"
else rec "Apple Silicon" FAIL "$ARCH"; MISSING+=("Apple Silicon (M-series) is expected; Intel is untested."); fi
# Xcode
# --- Check: Xcode and command line tools ---
# XCODE_OK stays 0 until we prove full Xcode works; later checks use it.
XCODE_OK=0
# 'xcode-select -p' prints the active developer folder; it fails if none is set. Output is discarded here.
if xcode-select -p >/dev/null 2>&1; then rec "Command Line Tools path" PASS "$(xcode-select -p)"
else rec "Command Line Tools path" FAIL "none"; MISSING+=("Run: xcode-select --install   (Apple's own installer dialog)"); fi
# Try running xcodebuild -version and capture its text. The 'if' is true only if the command succeeds.
if XV="$(xcodebuild -version 2>&1)"; then
  # Success: record the version (newlines turned into spaces so it fits on one row) and mark Xcode as OK.
  rec "xcodebuild -version" PASS "$(echo "$XV" | tr '\n' ' ')"; XCODE_OK=1
else
  # Failure: record it and tell the user how to install or select Xcode themselves.
  rec "xcodebuild -version" FAIL "full Xcode not usable"
  MISSING+=("Install Xcode from the Mac App Store (free), open it once, accept the license. If installed, run: xcode-select -s /Applications/Xcode.app/Contents/Developer (needs your admin password; do it yourself).")
fi
# Check swift: take the first line of its version output, make sure it is not empty and really mentions 'swift'.
if SV="$(swift --version 2>&1 | head -1)" && [ -n "$SV" ] && echo "$SV" | grep -q -i swift; then rec "swift --version" PASS "$SV"
else rec "swift --version" FAIL "swift not found"; MISSING+=("swift comes with Xcode / Command Line Tools; see above."); fi
# --- Check: free disk space ---
# Disk (need ~5 GB)
# 'df -k' shows free space in kilobytes; awk picks the 4th column (available) from the 2nd line.
FREE_KB="$(df -k "$SCRATCH" | awk 'NR==2{print $4}')"
# Convert kilobytes to gigabytes by dividing by 1024 twice (whole numbers only).
FREE_GB=$((FREE_KB/1024/1024))
# Minimum GB needed: default 5, but the user may override with LANTERN_MIN_GB.
MING="${LANTERN_MIN_GB:-5}"
if [ "$FREE_GB" -ge "$MING" ]; then rec "Free disk >= ${MING} GB" PASS "${FREE_GB} GB"
else rec "Free disk >= ${MING} GB" FAIL "${FREE_GB} GB"; MISSING+=("Free up disk space (need about 5 GB; override with LANTERN_MIN_GB=1 at your own risk)."); fi
# --- Check: iOS Simulator SDK ---
# Only look if Xcode works. 'xcodebuild -showsdks' lists SDKs; we search for the simulator one.
# iOS simulator SDK
if [ "$XCODE_OK" = 1 ] && xcodebuild -showsdks 2>/dev/null | grep -q iphonesimulator; then rec "iOS Simulator SDK" PASS "present"
else rec "iOS Simulator SDK" FAIL "missing"; MISSING+=("In Xcode > Settings > Components, download the iOS platform/simulator."); fi

# If anything was missing, print the list of fixes so the user knows what to do.
if [ "${#MISSING[@]}" -gt 0 ]; then
  # ${#MISSING[@]} is the number of items in the MISSING list.
  echo; echo "== What is missing and how to fix =="
  for m in "${MISSING[@]}"; do echo " - $m"; done
fi

# table = print the result table. It is a function so we can call it from two places below.
table() {
  echo; echo "== Result table =="
  # Header row. printf pads each column to a fixed width so the table lines up.
  printf '%-32s %-6s %s\n' STEP RESULT DETAIL
  # Loop over every saved row, split it at the '|' marks into a, b, c, and print it in the same column layout.
  for r in "${RESULTS[@]}"; do IFS='|' read -r a b c <<<"$r"; printf '%-32s %-6s %s\n' "$a" "$b" "$c"; done
}
# If any preflight check failed, show the table, say nothing was built, and stop with exit code 1 (failure).
if [ "$FAILS" -gt 0 ]; then
  table; echo; echo "OVERALL: FAIL (preflight). Nothing was built. Fix the items above and re-run."; exit 1
fi

# ===== SECTION 3: Build and test steps (only reached when the preflight passed) =====
# step = run one command, send all its output to a log file, and record PASS or FAIL.
# Arguments: a display name, a log file name, then the command to run.
step() { # name, logfile, cmd...
  # Take the first two arguments as name and log path, then 'shift 2' removes them so "$@" is just the command.
  local name="$1" lf="$LOG/$2.log"; shift 2
  echo "== $name =="
  # Run the command with output into the log. On failure also show the last 15 lines so the user sees why.
  if "$@" >"$lf" 2>&1; then rec "$name" PASS "log: $lf"; else rec "$name" FAIL "see $lf"; tail -n 15 "$lf"; fi
}
# Build the Swift package.
step "swift build (package)" build swift build --scratch-path "$SCRATCH/swift"
# Run the automated tests.
step "swift test" test swift test --scratch-path "$SCRATCH/swift"
# Build just the Mac host command-line tool.
step "macOS host CLI (lantern-host)" host swift build --scratch-path "$SCRATCH/swift" --product lantern-host
# Build the iPhone app for the simulator using the helper script.
step "iOS client (simulator)" ios "$ROOT/scripts/build_ios_sim.sh" "$SCRATCH/dd-client"
# Show the test count line(s) from the test log if present. '|| true' keeps the script going if grep finds nothing.
if [ -f "$LOG/test.log" ]; then grep -E "Executed [0-9]+ tests|Test run with" "$LOG/test.log" | tail -n 2 || true; fi

# ===== SECTION 4: Final report =====
table
# Print the manual to-do list. The quoted 'NEXT' means the text is printed exactly as written, with no variable expansion.
cat <<'NEXT'

== Next manual steps (nothing here is automatic) ==
1. Screen Recording: System Settings > Privacy & Security > Screen & System Audio Recording > allow the app you run lantern-host from (Terminal). Restart that app.
2. Accessibility: System Settings > Privacy & Security > Accessibility > allow the same app (needed for touch to mouse).
3. Real iPhone: open Apps/LanternClient/LanternClient.xcodeproj in Xcode, Signing & Capabilities,
   Team = your own personal team (Xcode > Settings > Accounts > add your own Apple ID; free).
4. Change the bundle id from org.twu.lantern.client to your own, e.g. com.yourname.lantern.client.
5. Run scripts/verify.sh, then scripts/print_hashes.sh and compare with the sender's manifest.
NEXT
# Final verdict: exit 1 if any step failed, otherwise say PASS.
if [ "$FAILS" -gt 0 ]; then echo "OVERALL: FAIL ($FAILS step(s))"; exit 1; fi
echo "OVERALL: PASS"
