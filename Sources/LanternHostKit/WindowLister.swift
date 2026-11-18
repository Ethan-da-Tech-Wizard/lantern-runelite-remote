// WindowLister.swift - asks macOS which windows exist (title, owner, size, layer).
// Who calls it: WindowCapturer.listWindows, InputInjector's SystemWindowEnvironment (frame lookups,
// "what window is on top at this point?"), and lantern-host.
// Key ideas: a "window list" is the system's table of every window; reading it does not trigger a
// permission prompt, but titles of other apps' windows are hidden without Screen Recording permission.

// CoreGraphics (Quartz) provides CGWindowListCopyWindowInfo, the system's list of windows.
import CoreGraphics
// Foundation gives us the basic types (String, Dictionary, etc.).
import Foundation

// An enum with only static functions is just a namespace; nobody creates a WindowLister.
/// Lists windows through CGWindowList (no Screen Recording prompt; titles of other apps' windows
/// are empty until Screen Recording is granted).
public enum WindowLister {
    /// Returns the current windows as WindowInfo values, front-most first (that is the order CGWindowList uses).
    /// - Parameter onScreenOnly: true = only windows currently visible on a display.
    // Default is true so most callers get just the visible windows.
    public static func windows(onScreenOnly: Bool = true) -> [WindowInfo] {
        // Build the option flags: always skip desktop-background elements; optionally skip off-screen windows too.
        let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.excludeDesktopElements]
        // Ask macOS for the window list. It comes back as an array of dictionaries (one per window).
        // kCGNullWindowID means "relative to no particular window", i.e. the whole list.
        // If the call fails we return an empty list instead of crashing.
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        // compactMap = convert every dictionary into a WindowInfo, silently dropping ones that are missing the key facts.
        return raw.compactMap { d in
            // The window number, as the OS sees it (the same id ScreenCaptureKit uses).
            guard let id = d[kCGWindowNumber as String] as? UInt32,
                  // The window's bounds are stored as a nested dictionary (X, Y, Width, Height); convert it into a CGRect.
                  // Coordinates are in global screen points with the origin at the top-left.
                  let b = d[kCGWindowBounds as String] as? [String: Any],
                  // Convert that bounds dictionary into a CGRect; if it cannot be converted, skip this window.
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            // Fill in the rest with safe defaults: empty text if missing, layer 0 (normal windows), alpha 1 (opaque).
            // Note: other apps' window titles come back empty until Screen Recording permission is granted.
            return WindowInfo(id: id, ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                              ownerPID: Int32(d[kCGWindowOwnerPID as String] as? Int ?? 0),
                              title: d[kCGWindowName as String] as? String ?? "",
                              frame: rect, layer: d[kCGWindowLayer as String] as? Int ?? 0,
                              alpha: d[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}
