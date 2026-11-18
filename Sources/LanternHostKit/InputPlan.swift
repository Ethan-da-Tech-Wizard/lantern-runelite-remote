// ==============================================================================
// Program: InputPlan.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Translates high-level phone gesture events into discrete macOS mouse/keyboard action plans.
//          Inputs: Phone input actions (tap, long press, two-finger pan, drag).
//          Outputs: Coordinate-transformed mouse down, move, and up sequence plans.
//          Design Rationale: Decouples high-level input semantics from low-level OS event generation,
//          facilitating unit testing of input logic.
// ==============================================================================
// InputPlan.swift - decides WHAT mouse/keyboard actions an incoming phone event means.
// Who calls it: InputInjector.apply (real use) and lantern-host's inject-test dry run.
// RuneLite Remote Streaming & Touch Control Logic:
//   - An incoming phone event (e.g. tap at normalized coordinates 0.5, 0.5) is planned into discrete,
//     deterministic OS-level actions (mouse move, mouse down, mouse up) targeting the RuneLite game window.
//   - Touch Control Mapping for RuneLite:
//     * One-finger tap: plans to move -> leftDown -> leftUp (standard primary click).
//     * Two-finger tap / long-press: plans to move -> rightDown -> rightUp (OSRS right-click context menu).
//     * One-finger drag in 3D viewport: plans to move -> otherDown -> otherDrag -> otherUp (middle-mouse camera orbit).
//     * Two-finger drag: plans to move -> leftDown -> leftDrag -> leftUp (drag items / inventory interaction).
//     * Pinch gesture: plans to scroll(dx: 0, dy: pixels) (scroll-wheel viewport zoom in/out).
//   - Strict Safety Rules:
//     * Out-of-bounds coordinates (< 0.0 or > 1.0) are completely dropped, never clamped, preventing input drift.
//     * Keystroke length is strictly limited to prevent buffer overflow attacks.

// CoreGraphics: CGPoint/CGRect for screen positions.
import CoreGraphics
// Foundation: String and basic types.
import Foundation
// LanternCore defines InputEvent (what the phone sends) and limits like maxKeyBytes.
import LanternCore

// Each case is one low-level thing to do to the Mac; positional cases carry the screen point.
/// One primitive OS-level action. A single InputEvent plans to a small fixed list (e.g. tap = move, down, up);
/// nothing is repeated, queued or scheduled.
public enum PlannedAction: Equatable, Sendable {
    // Move the pointer without pressing anything.
    case move(CGPoint)
    // Left mouse button: press, release, and move-while-held (drag).
    case leftDown(CGPoint), leftUp(CGPoint), leftDrag(CGPoint)
    // Right mouse button press/release (used for long-press = context menu).
    case rightDown(CGPoint), rightUp(CGPoint)
    // 'Other' = the middle mouse button (used here for camera rotation).
    case otherDown(CGPoint), otherUp(CGPoint), otherDrag(CGPoint)     // middle button (camera)
    // Scroll wheel movement measured in pixels (horizontal dx, vertical dy).
    case scroll(dxPixels: Int32, dyPixels: Int32)
    // Typed text plus modifier bits (shift/ctrl/alt/cmd).
    case keyText(String, mods: UInt8)

    /// Short human-readable text for logs and the dry run. Coordinates are truncated to whole numbers.
    public var description: String {
        // One text format per case. Note the typed text itself is never printed, only its length.
        switch self {
        case .move(let p): return "move(\(Int(p.x)),\(Int(p.y)))"
        case .leftDown(let p): return "leftDown(\(Int(p.x)),\(Int(p.y)))"
        case .leftUp(let p): return "leftUp(\(Int(p.x)),\(Int(p.y)))"
        case .leftDrag(let p): return "leftDrag(\(Int(p.x)),\(Int(p.y)))"
        case .rightDown(let p): return "rightDown(\(Int(p.x)),\(Int(p.y)))"
        case .rightUp(let p): return "rightUp(\(Int(p.x)),\(Int(p.y)))"
        case .otherDown(let p): return "otherDown(\(Int(p.x)),\(Int(p.y)))"
        case .otherUp(let p): return "otherUp(\(Int(p.x)),\(Int(p.y)))"
        case .otherDrag(let p): return "otherDrag(\(Int(p.x)),\(Int(p.y)))"
        case .scroll(let dx, let dy): return "scroll(dx=\(dx),dy=\(dy))"
        case .keyText(let t, let m): return "keyText(\(t.count) chars, mods=\(m))"   // text itself not logged (privacy rules)
        }
    }

    // The screen point this action touches; scroll and key actions have no point.
    /// Screen point this action touches, if it is positional.
    public var point: CGPoint? {
        // Every positional case returns its point; everything else falls to default and returns nil.
        switch self {
        case .move(let p), .leftDown(let p), .leftUp(let p), .leftDrag(let p), .rightDown(let p), .rightUp(let p), .otherDown(let p), .otherUp(let p), .otherDrag(let p): return p
        default: return nil
        }
    }
}

/// Turns an InputEvent (normalized 0...1 touch data from the phone) into a short, fixed list of PlannedActions.
/// It does no OS calls itself, so it is safe to unit test.
public enum InputPlanner {
    // A scroll value of 1.0 becomes this many pixels.
    /// Wheel pixels for a full-scale (|1.0|) scroll; zoom uses the same axis.
    public static let scrollScale: Float = 40

    // Rules: not empty, within the byte limit, and no control characters except newline, carriage return, tab, backspace.
    // Modifier bits are zeroed unless the host was started with --allow-modifiers; 0x0f keeps only the 4 known modifier bits.
    /// Returns nil for events with out-of-range coordinates (dropped). Scroll/zoom/key return actions with no point.
    /// Keyboard text is typed text only: <= 32 UTF-8 bytes and no control characters except \n \r \t and backspace.
    /// Modifier bits are stripped (the text is typed unmodified) unless `allowModifiers` (host flag `--allow-modifiers`).
    public static func sanitizeKey(_ text: String, mods: UInt8, allowModifiers: Bool) -> (String, UInt8)? {
        // Empty or too-long text is rejected (nil).
        guard !text.isEmpty, text.utf8.count <= InputEvent.maxKeyBytes else { return nil }
        // Check every character: 'control' characters (invisible commands) are only allowed from a small safe list.
        for u in text.unicodeScalars where u.properties.generalCategory == .control {
            // A control character not on the allowed list means we refuse the whole key event.
            if !["\n", "\r", "\t", "\u{8}"].contains(u) { return nil }
        }
        // Accepted: pass text through, keep modifier bits only if allowed.
        return (text, allowModifiers ? mods & 0x0f : 0)
    }

    /// Plans one event against the target window's frame. Returns nil when the event must be dropped (bad coordinates, bad text).
    public static func plan(_ e: InputEvent, frame: CGRect, allowModifiers: Bool = false) -> [PlannedAction]? {
        // Small helper: convert a 0...1 pair to a screen point inside the frame (nil if out of range).
        func pt(_ x: Float, _ y: Float) -> CGPoint? { WindowGeometry.point(normX: x, normY: y, in: frame) }
        // Decide the plan from the kind of event.
        switch e {
        // Tap = move the pointer there, press, release (a normal click).
        case .tap(let x, let y):
            guard let p = pt(x, y) else { return nil }
            return [.move(p), .leftDown(p), .leftUp(p)]
        // Long press = right click (move, right press, right release).
        case .longPress(let x, let y):
            guard let p = pt(x, y) else { return nil }
            return [.move(p), .rightDown(p), .rightUp(p)]
        // Drag begins: move there and hold the left button down (no release yet).
        case .dragStart(let x, let y):
            guard let p = pt(x, y) else { return nil }
            return [.move(p), .leftDown(p)]
        // While dragging, report the new pointer position with the button held.
        case .dragMove(let x, let y):
            guard let p = pt(x, y) else { return nil }
            return [.leftDrag(p)]
        // Drag finished: release the left button at this position.
        case .dragEnd(let x, let y):
            guard let p = pt(x, y) else { return nil }
            return [.leftUp(p)]
        // Camera drag: same idea as a drag but with the middle button.
        case .camStart(let x, let y):
            guard let p = pt(x, y) else { return nil }
            return [.move(p), .otherDown(p)]
        // Middle-button drag movement.
        case .camMove(let x, let y):
            guard let p = pt(x, y) else { return nil }
            return [.otherDrag(p)]
        // Middle-button release.
        case .camEnd(let x, let y):
            guard let p = pt(x, y) else { return nil }
            return [.otherUp(p)]
        // Scroll: both amounts must be real numbers between -1 and 1; then scale them to wheel pixels (rounded to whole numbers).
        case .scroll(let dx, let dy):
            guard !dx.isNaN, !dy.isNaN, abs(dx) <= 1, abs(dy) <= 1 else { return nil }
            return [.scroll(dxPixels: Int32((dx * scrollScale).rounded()), dyPixels: Int32((dy * scrollScale).rounded()))]
        // Zoom is sent as vertical wheel movement (the game zooms with the wheel).
        case .zoom(let d):
            guard !d.isNaN, abs(d) <= 1 else { return nil }
            return [.scroll(dxPixels: 0, dyPixels: Int32((d * scrollScale).rounded()))]
        // Key text: validate it first; refuse (nil) if it fails the rules.
        case .key(let text, let mods):
            guard let (t, m) = sanitizeKey(text, mods: mods, allowModifiers: allowModifiers) else { return nil }
            return [.keyText(t, mods: m)]
        }
    }
}
