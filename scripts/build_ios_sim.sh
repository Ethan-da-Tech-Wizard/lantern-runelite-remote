#!/bin/bash
# ==============================================================================
# Program: build_ios_sim.sh
# Programmer: Ethan-da-Tech-Wizard
# Course: CIS 156 / Advanced Systems
# Last Modified: November 18, 2026
# Purpose: Builds the iOS client application for the iOS Simulator.
#          Inputs: Simulator destination parameters and build configuration flags.
#          Outputs: Compiled LanternClient.app bundle installed in target simulator.
#          Design Rationale: Automates xcodebuild invocations for rapid local client testing without Xcode GUI overhead.
# ==============================================================================
# Build LanternClient for the iOS Simulator; with --run, install and launch on a simulator (default iPhone 17).
# Never touches a real device. Usage: scripts/build_ios_sim.sh [--run] [DerivedDataPath]
# Safety settings: stop on errors, error on unset variables, fail pipelines when any part fails.
set -euo pipefail
# Find the project folder (one level above scripts/) as an absolute path.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# RUN=1 only if the first argument is --run; 'shift' then removes that argument so the next one is the build folder.
RUN=0; [ "${1:-}" = "--run" ] && { RUN=1; shift; }
# DD = folder where Xcode puts build products. Use the argument if given, else a folder in the temp directory.
DD="${1:-${TMPDIR:-/tmp}/lantern-dd-client}"
# Which simulator to use: the user's choice via LANTERN_SIM, or iPhone 17 by default.
SIM_NAME="${LANTERN_SIM:-iPhone 17}"
# The app's bundle identifier, used to launch it after install.
BID=com.example.lantern.client
# Build the app with Xcode for the simulator. CODE_SIGNING_ALLOWED=NO because simulators need no signing.
# 'tail -n 15' shows only the last 15 lines of Xcode's very long output.
xcodebuild -project "$ROOT/Apps/LanternClient/LanternClient.xcodeproj" -scheme LanternClient \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -n 15
# Where we expect the finished app to be.
APP="$DD/Build/Products/Debug-iphonesimulator/LanternClient.app"
# If that folder does not exist the build did not work, so say so and stop.
[ -d "$APP" ] || { echo "no app bundle at $APP"; exit 1; }
# Only when --run was requested: install and start the app in the simulator.
if [ "$RUN" = 1 ]; then
  # Find the simulator's ID from the list of available devices: match the name, take the first, and cut out the ID inside parentheses.
  UDID=$(xcrun simctl list devices available | grep -F "    $SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  # If no simulator with that name exists, stop with a message.
  [ -n "$UDID" ] || { echo "simulator '$SIM_NAME' not found"; exit 1; }
  # Boot the simulator; '|| true' ignores the error if it is already running.
  xcrun simctl boot "$UDID" 2>/dev/null || true
  # Wait until the simulator has finished booting.
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  # Install the freshly built app.
  xcrun simctl install "$UDID" "$APP"
  # Launch the app.
  xcrun simctl launch "$UDID" $BID
fi
