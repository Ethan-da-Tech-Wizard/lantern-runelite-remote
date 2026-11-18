#!/bin/bash
# Build LanternClient for the iOS Simulator; with --run, install and launch on a simulator (default iPhone 17).
# Never touches a real device. Usage: scripts/build_ios_sim.sh [--run] [DerivedDataPath]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN=0; [ "${1:-}" = "--run" ] && { RUN=1; shift; }
DD="${1:-${TMPDIR:-/tmp}/lantern-dd-client}"
SIM_NAME="${LANTERN_SIM:-iPhone 17}"
BID=org.twu.lantern.client
xcodebuild -project "$ROOT/Apps/LanternClient/LanternClient.xcodeproj" -scheme LanternClient \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -n 15
APP="$DD/Build/Products/Debug-iphonesimulator/LanternClient.app"
[ -d "$APP" ] || { echo "no app bundle at $APP"; exit 1; }
if [ "$RUN" = 1 ]; then
  UDID=$(xcrun simctl list devices available | grep -F "    $SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [ -n "$UDID" ] || { echo "simulator '$SIM_NAME' not found"; exit 1; }
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl launch "$UDID" $BID
fi
