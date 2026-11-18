// Program: Lantern - OSRSZones.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Decides whether a touch lands on the 3D game world (camera drag) or on an interface panel (normal drag) in the Fixed Classic layout.
//
// =====================================================================================
// OSRSZones.swift
//
// PURPOSE
//   Works out whether a touch landed on the 3D game world (where a drag should rotate the
//   camera) or on an interface widget (where a drag should be a normal left-drag).
//
// WHO CALLS IT
//   The touch-gesture mapping code on the phone calls `isWorld` with the touch position and the
//   size of the video picture before deciding which kind of drag event to send.
//
// KEY IDEAS (in plain English)
//   - Touch positions arrive as fractions (0 to 1) of the picture; we convert them to window
//     "points" and compare against fixed rectangles.
//   - The picture is captured at 2 pixels per point, so dividing pixels by 2 gives points.
// =====================================================================================

import Foundation

/// Decides what a one-finger drag means from where the finger lands, like the official mobile client:
/// a drag that starts on the 3D game world rotates the camera; a drag that starts on an interface widget
/// (inventory, bank, chat, minimap, tabs, RuneLite's own sidebar) is a normal left-drag (moves items, scrolls).
///
/// Geometry is for the Fixed Classic layout, the one RuneLite uses at 765x503: the captured window is that canvas
/// plus a title bar on top, plus (optionally) RuneLite's sidebar/plugin panel to the right. All numbers are in
/// window POINTS; the picture is captured at 2x, so pixel size / 2 = points. Layouts other than Fixed Classic are
/// detected by the canvas height and fall back to "no camera zone" (plain left-drag everywhere, the old behaviour).
public enum OSRSZones {
    /// Height of the fixed canvas in points; used to spot the layout.
    public static let canvasHeight: Double = 503
    /// 3D viewport inside the 765x503 fixed canvas (x 4..516, y 4..338).
    public static let world = (x0: 4.0, y0: 4.0, x1: 516.0, y1: 338.0)
    /// Capture scale: 2 picture pixels per window point.
    public static let capturePixelsPerPoint: Double = 2

    /// Title bar height in points implied by the picture size, or nil when the window is not a Fixed Classic canvas.
    public static func titleBar(videoPixelHeight h: Double) -> Double? {
        // Whatever height is left after removing the canvas must be the title bar.
        let t = h / capturePixelsPerPoint - canvasHeight
        // Accept only a plausible title bar size (10 to 60 points); otherwise this is another layout.
        return (10...60).contains(t) ? t : nil
    }

    /// `nx`, `ny`: touch position as a 0...1 fraction of the video picture; `videoPixels`: picture size in pixels.
    public static func isWorld(nx: Float, ny: Float, videoPixels: (w: Double, h: Double)) -> Bool {
        // Unknown layout: never treat the touch as a camera zone.
        guard let t = titleBar(videoPixelHeight: videoPixels.h) else { return false }
        // Convert the fractions to points; for y, also subtract the title bar so 0 is the canvas top.
        let x = Double(nx) * videoPixels.w / capturePixelsPerPoint
        let y = Double(ny) * videoPixels.h / capturePixelsPerPoint - t
        // Inside the 3D viewport rectangle?
        return x >= world.x0 && x <= world.x1 && y >= world.y0 && y <= world.y1
    }
}
