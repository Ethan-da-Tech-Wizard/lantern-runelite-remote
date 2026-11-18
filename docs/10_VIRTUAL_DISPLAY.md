# 10 Virtual Display (phone-shaped, in-house)

Replaces paid BetterDisplay (see 06_OPEN_REPLACEMENTS.md). Library only, no CLI, no account, no network.
Files: `Sources/LanternHostKit/VirtualDisplay.swift` (API), `VirtualDisplayMath.swift` (pure size math), `Tests/LanternHostKitTests/VirtualDisplayTests.swift`.

## API
```swift
public protocol DisplayProvider { func create(width:height:refresh:hiDPI:name:) throws -> VirtualDisplayHandle; func destroy() }
let vd = VirtualDisplay()
let h = try vd.create(width: 2532, height: 1170, refresh: 60, hiDPI: true, name: "Lantern Phone")
h.displayID      // CGDirectDisplayID, hand this to ScreenCaptureKit
vd.destroy()     // releases the display
```
Defaults: 2532x1170@60 (iPhone landscape, 19.5:9), HiDPI logical 1266x585. `VirtualDisplaySpec` validates bounds (320...8192 px, refresh 1...120, even pixels when HiDPI) and computes modes, logical size, mm size, and larger same-ratio fallbacks (3036x1404).

## How it works
CoreGraphics has a private CGVirtualDisplay family (Descriptor, Mode, Settings, Display). We look the classes up at runtime with `NSClassFromString` and call them through the ObjC runtime (no header, no link). Steps: build a descriptor (name, max pixels, mm size, IDs), create the display, apply settings with `hiDPI` and the mode list (native pixel mode plus the half-size logical mode), read `displayID`. The display exists only while the `VirtualDisplayHandle` (and process) is alive. If any class or selector is missing, `create` throws `VirtualDisplayError.apiUnavailable` with a clear message; `VirtualDisplay.isAvailable` checks without creating anything. The usage pattern follows the open-source VoidDisplay (Apache-2.0) and DeskPad (MIT); our code is written independently with an attribution comment.

## Keeping other apps out of the stream
Capture the display, not the screen: `SCContentFilter(display:excludingWindows:)` on the SCDisplay whose `displayID` equals `h.displayID`. SCK only delivers pixels composited on that display. Put only RuneLite on it (extended, not mirrored; move the window there, full size). Messages, browsers etc. stay on the real display and never enter the stream. Caveats: the pointer and any window dragged onto the virtual display are captured; notifications may land on the main display only.

## Risks
- Private API: can change or vanish on any macOS update. We fail gracefully; fallbacks are VoidDisplay or DeskPad.
- Leaked display after a crash: the display normally disappears when the process dies. If it lingers (rare, e.g. a hung process): quit/kill the Lantern process (`pkill -f lantern-host`), then check System Settings > Displays; if still present, log out and back in, or reboot. Windows on it move back to the main display.
- Display layout may be rearranged by macOS when it appears or vanishes; check arrangement afterwards.
- Unverified: whether current macOS accepts 2532x1170 (see 06 open questions). This module has been compile- and math-tested only; no real display was created during development.

## Manual test (owner, later; not run yet)
1. Build and run a throwaway snippet or the host that calls `VirtualDisplay().create(width: 2532, height: 1170, refresh: 60, hiDPI: true, name: "Lantern Phone")`, printing `displayID`.
2. Expect: a new display appears in System Settings > Displays named "Lantern Phone", listed as 1266x585 (HiDPI), 60 Hz, a non-zero displayID printed, no error.
3. Set it to extended (not mirror). Drag RuneLite onto it; it should fill a 19.5:9 area.
4. Run the SCK display capture on that displayID: stream should show only RuneLite; moving Safari on the main display must not appear.
5. If `create` throws `apiUnavailable` or `settingsRejected`, record the message and the macOS version; try 3036x1404 and report.
Undo: stop the process (Ctrl-C or `destroy()`); the display vanishes. Confirm it is gone in System Settings > Displays; if not, use the cleanup procedure above. Nothing else is changed on disk.
