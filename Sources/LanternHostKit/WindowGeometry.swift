// Program: Lantern - WindowGeometry.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Window description type and the math converting phone touch fractions to screen points.
//
// WindowGeometry.swift - the WindowInfo snapshot type and the math that turns phone touch coordinates
// (0 to 1 across the window) into real screen points.
// Who calls it: InputPlanner (planning events), InputInjector (bounds checks), CaptureGuard and
// WindowLister (WindowInfo), lantern-host (printing).
// Key ideas: coordinates here are in 'global display points' with the origin at the TOP-left, the same
// space that CGEvent mouse events use, so no flipping is needed.

// CoreGraphics gives CGRect/CGPoint (rectangles and points in screen space).
import CoreGraphics
// Foundation: basic types.
import Foundation

// WindowInfo is a plain snapshot of one window as listed by WindowLister.
/// One on-screen window. `frame` is in global display coordinates, origin top-left (same space as CGEvent).
// Equatable so tests can compare; Sendable so it can safely cross threads (it is only plain values).
public struct WindowInfo: Equatable, Sendable {
    // The window's number in the system window list (same id ScreenCaptureKit uses to find it).
    public var id: UInt32
    // The name of the app that owns this window.
    public var ownerName: String
    // The owning app's process id (used to check which app is in front).
    public var ownerPID: Int32
    // The window's title text (may be empty without Screen Recording permission).
    public var title: String
    // Position and size in global screen points (top-left origin).
    public var frame: CGRect
    // Window layer: 0 is a normal app window; menus, banners and the cursor use higher layers.
    public var layer: Int
    // Opacity of the window as reported by the system.
    /// kCGWindowAlpha (1 = opaque). Fully transparent windows do not occlude.
    public var alpha: Double
    // Spelled-out initializer so it is public; layer and alpha have defaults for convenience.
    public init(id: UInt32, ownerName: String, ownerPID: Int32, title: String, frame: CGRect, layer: Int = 0, alpha: Double = 1) {
        // Copy each parameter into the matching property.
        self.id = id; self.ownerName = ownerName; self.ownerPID = ownerPID
        self.title = title; self.frame = frame; self.layer = layer; self.alpha = alpha
    }

    // Used to find a window from text the user typed on the command line.
    /// Case-insensitive substring match on title or owner name. Empty needle never matches.
    public func matches(_ needle: String) -> Bool {
        // Lowercase both sides so the search ignores upper/lower case.
        let n = needle.lowercased()
        // An empty search text would match everything, so refuse it.
        guard !n.isEmpty else { return false }
        // True if the text appears in either the title or the owner app's name.
        return title.lowercased().contains(n) || ownerName.lowercased().contains(n)
    }
}

// 'Normalized' means a 0 to 1 scale: (0,0) is the window's top-left, (1,1) its bottom-right.
// The phone sends touches this way so it does not need to know the Mac window's pixel size.
/// Pure window-frame math: normalized 0...1 (origin top-left) <-> global screen points.
// Namespace for static helper functions (no state).
public enum WindowGeometry {
    // Reject NaN (not-a-number), values outside 0...1, and windows smaller than 2 points.
    /// Maps normalized coordinates to a global point strictly inside `frame`. Returns nil if the
    /// coordinates are NaN/out of 0...1 or the frame is empty (out-of-range events are dropped, not clamped).
    public static func point(normX x: Float, normY y: Float, in frame: CGRect) -> CGPoint? {
        // Any failure here returns nil, and the caller drops the event.
        guard !x.isNaN, !y.isNaN, (0...1).contains(x), (0...1).contains(y),
              frame.width >= 2, frame.height >= 2 else { return nil }
        // Keep one pixel inside the right/bottom edge so the point is contained in the window.
        // Scale 0...1 across the window width (minus one pixel), then shift by the window's left edge.
        let px = frame.minX + CGFloat(x) * (frame.width - 1)
        // Same for the vertical direction using the window's top edge.
        let py = frame.minY + CGFloat(y) * (frame.height - 1)
        // The finished screen point, in the same coordinate space CGEvent uses.
        return CGPoint(x: px, y: py)
    }

    /// True if the point lies inside the frame. Left/top edges count as inside, right/bottom edges do not
    /// (the same convention pixels use).
    public static func contains(_ p: CGPoint, in frame: CGRect) -> Bool {
        // Four comparisons: not left of, not above, strictly before the right edge, strictly before the bottom edge.
        p.x >= frame.minX && p.x < frame.maxX && p.y >= frame.minY && p.y < frame.maxY
    }

    /// Inverse of `point`, for tests and logging. Clamped to 0...1.
    public static func normalized(_ p: CGPoint, in frame: CGRect) -> (x: Float, y: Float) {
        // A frame this tiny cannot be divided; return the origin.
        guard frame.width > 1, frame.height > 1 else { return (0, 0) }
        // Reverse of `point`: subtract the window origin and divide by the usable size.
        let x = (p.x - frame.minX) / (frame.width - 1), y = (p.y - frame.minY) / (frame.height - 1)
        // Clamp into 0...1 so slightly off values stay in range, and convert to Float.
        return (Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }
}
