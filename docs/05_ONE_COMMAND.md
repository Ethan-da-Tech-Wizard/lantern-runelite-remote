# One-command setup (design and results, 2026-11-17)

## Scripts (all `set -euo pipefail`, idempotent, never sudo, never install, never curl|bash)
| Script | Job |
|---|---|
| scripts/bootstrap.sh | Refuses root. Read-only preflight (macOS >= 14, arm64, CLT path, `xcodebuild -version`, `swift --version`, free disk, iOS simulator SDK), prints what is missing and the fix, stops on any preflight FAIL. Then: `swift build`, `swift test`, `swift build --product lantern-host`, `scripts/build_ios_sim.sh`. Prints PASS/FAIL table and manual next steps. |
| scripts/verify.sh | No pins in Package.resolved, no `.package(` in Package.swift, no remote packages in the xcodeproj, `otool -L` of lantern-host and the client must list only /usr/lib, /System/Library (and Swift runtime rpaths), runs check_no_telemetry.sh, `lsof` check that a running lantern-host has no wildcard listener. This check needs a running host: with none running it prints SKIP (not PASS) and the overall result can still be PASS. |
| scripts/check_no_telemetry.sh | Greps source and built binaries (`strings`) for analytics/crash SDK names; flags URL literals in source. |
| scripts/print_hashes.sh | sha256 of every source file (excluding .build, .git, xcuserdata, logs) into MANIFEST.sha256 plus one tree hash. |

Env: `LANTERN_SCRATCH` (build dir, default ./.build), `LANTERN_MIN_GB` (default 5), `LANTERN_SIM`.

## Results on the author's Mac (Xcode 26.3, Swift 6.2.4, macOS 26.1, arm64)
- Preflight caught real low disk (1 GB free): bootstrap refused, as designed. Rerun with `LANTERN_MIN_GB=0`.
- bootstrap: swift build PASS, swift test PASS (counts: see the script output; they change as tests are added), host CLI PASS, iOS simulator build PASS. One earlier run failed "input file modified during the build" because another agent edited Sources concurrently; rerun passed.
- verify (before the SKIP change): static checks PASS (no deps, Apple-only frameworks on both binaries, telemetry clean). Logs were not retained; rerun to confirm.
- Limitation: the lsof listener check only inspects a lantern-host that is already running; with none running it prints SKIP (nothing checked, not proof of safety). To run it for real: in one terminal start `lantern-host serve --bind <LAN-IP> --port N --window-id <id>` (needs a human to choose the window), then in another run `scripts/verify.sh` and confirm the row says PASS rather than SKIP. bootstrap.sh does not start the host.
- bootstrap preflight treats Intel (non-arm64) as FAIL; after a build FAIL it still runs later steps and prints OVERALL FAIL.
- Limitation: `strings` grep and otool prove no known SDK names or non-Apple dylibs, not absence of network use.

## Why not Docker
Docker runs Linux containers. The host uses ScreenCaptureKit, VideoToolbox, CGEvent and Network.framework, and the client is a UIKit/iOS app built with Xcode and run in the iOS Simulator. All are macOS/iOS-only frameworks with no Linux equivalent, so neither can run or be built in a container. Docker could at most host a Linux Swift toolchain, which would not even compile these targets.
