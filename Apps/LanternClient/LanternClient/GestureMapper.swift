// GestureMapper.swift
//
// PURPOSE: Turns finger gestures on the video view into InputEvents (tap, long-press, drag,
// camera drag, pinch zoom). The Mac then replays them as mouse clicks, drags and scrolls.
//
// WHO CALLS IT: VideoView (StreamView.swift) owns a GestureMapper and calls `attach(to:)`.
// Each event is passed to the `emit` closure, which ends up in ClientModel.send.
//
// KEY IDEAS (for a beginner):
//   - A "gesture recognizer" (UIKit) is a helper attached to a view. UIKit feeds it the raw
//     finger touches; when the pattern matches (a quick tap, a finger sliding, two fingers
//     pinching) it calls one of our functions with a `state` saying how far along it is:
//     .began (just recognised), .changed (still going), .ended (finger lifted),
//     .cancelled / .failed (interrupted).
//   - A finger position is in view points. The Mac needs a position inside the game picture, so
//     we convert to 0...1 across the video (0,0 = top-left, 1,1 = bottom-right).
//     The video is shown "letterboxed" (black bars keep its shape), so the bars must be ignored.
//   - Touches become mouse events: a tap is sent as a click, a long press as a right-click, a
//     one-finger drag on the game world rotates the camera (middle-button drag), and a drag
//     that starts on an interface widget is a plain left-button drag.
//   - The code is split in two: `VideoGeometry` and `GestureLogic` are plain math/rules that do not
//     touch UIKit (easy to test); `GestureMapper` is the thin UIKit layer wiring recognizers to them.

import UIKit
import AVFoundation
import LanternCore

/// Pure geometry: view point -> 0...1 inside the letterboxed video rect. nil when outside the video.
// A caseless `enum` is used as a namespace: it only groups functions and can never be instantiated.
enum VideoGeometry {
    /// The rectangle inside `bounds` that the video really covers (aspect ratio kept). Zero if any size is empty.
    static func videoRect(videoSize: CGSize, in bounds: CGRect) -> CGRect {
        // Refuse to compute for empty sizes (avoids dividing by zero later).
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        // AVMakeRect fits a rectangle with the video's shape inside the view, centred: the letterbox.
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }
    /// `clamp`: true clamps points outside the rect to the edge (drag move/end); false returns nil.
    static func normalize(_ p: CGPoint, videoSize: CGSize, bounds: CGRect, clamp: Bool) -> (x: Float, y: Float)? {
        // The rectangle the video occupies.
        let r = videoRect(videoSize: videoSize, in: bounds)
        // A zero-sized rectangle means there is nothing to map to.
        guard r.width > 0, r.height > 0 else { return nil }
        // Outside the picture (in the black bars): no result, unless clamping was requested.
        if !clamp && !r.contains(p) { return nil }
        // Position across the video as 0...1; min/max force the value into that range (clamp).
        let x = min(max((p.x - r.minX) / r.width, 0), 1)
        // Same for the vertical position.
        let y = min(max((p.y - r.minY) / r.height, 0), 1)
        // Float is the number type used by the wire format.
        return (Float(x), Float(y))
    }
}

/// Pure gesture rules (no UIKit touches): one gesture -> exactly one event (a drag is one start/move*/end
/// sequence); scroll and zoom are emitted once, at gesture end, as the total. No timers, repeats or queues.
// A plain struct holding the gesture state; `mutating` methods change it, other methods only read it.
struct GestureLogic {
    /// Pixel size of the video; starts as 16:9 until the real size is reported.
    var videoSize = CGSize(width: 16, height: 9)
    /// True between a normal drag's start and end.
    private(set) var dragging = false
    /// True from the moment a long press fires until the finger lifts.
    private(set) var longPressActive = false
    /// True during a camera-rotate drag.
    private(set) var camDragging = false
    /// Last camera-drag position, used to close the drag if the finger ends off the video.
    private var lastCam: (x: Float, y: Float) = (0, 0)
    /// Last normal-drag position, used the same way.
    private var lastDrag: (x: Float, y: Float) = (0, 0)

    /// A quick tap becomes a click, but only when it lands on the video (not on the black bars).
    func tap(_ p: CGPoint, bounds: CGRect) -> InputEvent? {
        // `.map` turns the optional position into an optional event; nil stays nil.
        VideoGeometry.normalize(p, videoSize: videoSize, bounds: bounds, clamp: false).map { .tap(x: $0.x, y: $0.y) }
    }
    /// A long press becomes a right-click, sent once when the press is recognised.
    mutating func longPressBegan(_ p: CGPoint, bounds: CGRect) -> InputEvent? {
        longPressActive = true     // blocks any drag until the press ends
        // Convert and package; `.map` keeps nil if the press was outside the video.
        return VideoGeometry.normalize(p, videoSize: videoSize, bounds: bounds, clamp: false).map { .longPress(x: $0.x, y: $0.y) }
    }
    /// Called when the long press ends (finger lifted or interrupted), so drags work again.
    mutating func longPressEnded() { longPressActive = false }
    /// One-finger drag. Like the official mobile client: starting on the game world rotates the camera
    /// (middle-button drag on the Mac); starting on an interface widget is a plain left-drag (moves items, scrolls).
    /// Called when a one-finger drag is recognised. `p` is where the finger first touched.
    mutating func dragBegan(_ p: CGPoint, bounds: CGRect) -> InputEvent? {
        // Do not start if a long press, drag or camera drag is already going, or if the finger is off the video.
        guard !longPressActive, !dragging, !camDragging,
              let n = VideoGeometry.normalize(p, videoSize: videoSize, bounds: bounds, clamp: false) else { return nil }
        // Is the start point inside the game-world area (the big 3D view) rather than an interface widget?
        if OSRSZones.isWorld(nx: n.x, ny: n.y, videoPixels: (Double(videoSize.width), Double(videoSize.height))) {
            // World: rotate the camera instead of doing a normal drag.
            return camBegan(p, bounds: bounds)
        }
        // Interface widget: begin a normal left-button drag and remember where it started.
        dragging = true; lastDrag = n
        return .dragStart(x: n.x, y: n.y)
    }
    /// Called each time the finger moves during a drag. Positions outside the video are clamped to its edge.
    mutating func dragMoved(_ p: CGPoint, bounds: CGRect) -> InputEvent? {
        // A camera drag was chosen at the start, so route moves to the camera path.
        if camDragging { return camMoved(p, bounds: bounds) }
        // Ignore moves unless a normal drag is open.
        guard dragging, let n = VideoGeometry.normalize(p, videoSize: videoSize, bounds: bounds, clamp: true) else { return nil }
        // Remember the latest position in case the finger lifts off the video.
        lastDrag = n
        return .dragMove(x: n.x, y: n.y)
    }
    /// Always closes an open drag so the host releases the button; nil if no drag was open.
    // Camera drags finish through the camera path.
    mutating func dragEnded(_ p: CGPoint, bounds: CGRect) -> InputEvent? {
        if camDragging { return camEnded(p, bounds: bounds) }
        // Nothing to close if no drag is open.
        guard dragging else { return nil }
        // Mark the drag closed first so it can only end once.
        dragging = false
        // Use the final position, or the last known one if it cannot be computed.
        let n = VideoGeometry.normalize(p, videoSize: videoSize, bounds: bounds, clamp: true) ?? lastDrag
        return .dragEnd(x: n.x, y: n.y)
    }
    /// Two-finger drag = camera rotate (middle-button drag on the Mac, which is how OSRS rotates the camera).
    /// Starts a camera drag, if nothing else is in progress.
    mutating func camBegan(_ p: CGPoint, bounds: CGRect) -> InputEvent? {
        // Only start if nothing else is in progress and the position can be computed (clamped to the video).
        guard !longPressActive, !dragging, !camDragging,
              let n = VideoGeometry.normalize(p, videoSize: videoSize, bounds: bounds, clamp: true) else { return nil }
        // Remember that we are rotating the camera and where we started.
        camDragging = true; lastCam = n
        return .camStart(x: n.x, y: n.y)
    }
    /// Called as the camera drag moves.
    mutating func camMoved(_ p: CGPoint, bounds: CGRect) -> InputEvent? {
        // Ignore unless a camera drag is open; clamp positions to the video.
        guard camDragging, let n = VideoGeometry.normalize(p, videoSize: videoSize, bounds: bounds, clamp: true) else { return nil }
        // Remember the latest position (used if the finger ends off the video).
        lastCam = n
        return .camMove(x: n.x, y: n.y)
    }
    /// Always closes an open camera drag so the host releases the middle button.
    mutating func camEnded(_ p: CGPoint, bounds: CGRect) -> InputEvent? {
        // Nothing to close if no camera drag is open.
        guard camDragging else { return nil }
        // Close it first so it can only end once.
        camDragging = false
        // Final position, or the last known one.
        let n = VideoGeometry.normalize(p, videoSize: videoSize, bounds: bounds, clamp: true) ?? lastCam
        return .camEnd(x: n.x, y: n.y)
    }
    /// Converts a total two-finger slide into a scroll amount (a fraction of the video size, limited to -1...1). The recognizers below do not call this.
    func scrollEnded(translation t: CGPoint, bounds: CGRect) -> InputEvent? {
        // The video's rectangle, to measure the distance as a fraction of it.
        let r = VideoGeometry.videoRect(videoSize: videoSize, in: bounds)
        // With no valid rectangle there is nothing to produce.
        guard r.width > 0, r.height > 0 else { return nil }
        // Horizontal and vertical fractions, each clamped to the allowed range.
        return .scroll(dx: InputEvent.clampSigned(Float(t.x / r.width)), dy: InputEvent.clampSigned(Float(t.y / r.height)))
    }
    /// Pinch finished: `scale` is 1.0 for no change, so `scale - 1` is the zoom amount (positive = fingers spread, negative = squeezed).
    func pinchEnded(scale: CGFloat) -> InputEvent {
        .zoom(delta: InputEvent.clampSigned(Float(scale - 1)))
    }
}

// MARK: - UIKit wiring
/// UIKit gestures -> LanternCore InputEvent via GestureLogic. Every event is emitted synchronously from a recognizer callback.
final class GestureMapper: NSObject, UIGestureRecognizerDelegate {
    /// The video size, forwarded to the logic (set when the stream reports its real size).
    var videoSize: CGSize { get { logic.videoSize } set { logic.videoSize = newValue } }
    /// Where finished events are delivered.
    var emit: (InputEvent) -> Void
    /// The rules object; it holds all gesture state.
    private var logic = GestureLogic()
    /// The view the gestures are attached to; weak so the mapper does not keep it alive.
    private weak var view: UIView?
    /// Recognizer kept as a property so other code can check whether a long press is in progress.
    private let longPress = UILongPressGestureRecognizer()

    /// `emit` is called once for each event, synchronously, from inside a recognizer callback.
    init(emit: @escaping (InputEvent) -> Void) { self.emit = emit }

    /// Creates the recognizers and installs them on the view.
    func attach(to v: UIView) {
        // Remember the view; touch positions are measured in its coordinates.
        view = v
        // Tap recognizer: calls `onTap` after a quick touch-and-release.
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        // Long press recognizer: calls `onLong`.
        longPress.addTarget(self, action: #selector(onLong(_:)))
        // The finger must stay down half a second to count as a long press.
        longPress.minimumPressDuration = 0.5
        // Pan recognizer = finger sliding. This one handles exactly one finger (a drag).
        let drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
        // Allow only one finger for this pan.
        drag.minimumNumberOfTouches = 1; drag.maximumNumberOfTouches = 1
        // A second pan recognizer for exactly two fingers (used for camera rotate).
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        // Pinch recognizer: two fingers moving apart or together (zoom).
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        // Make this object each recognizer's delegate (so it can veto them), then add them all to the view.
        // The two-finger pan (`scroll`) is intentionally NOT attached: it competed with pinch so zoom rarely fired,
        // and the camera now rotates with a one-finger drag on the game world (like the official mobile client).
        _ = scroll
        for g in [tap, longPress, drag, pinch] as [UIGestureRecognizer] { g.delegate = self; v.addGestureRecognizer(g) }
    }

    // A delegate hook UIKit asks before it starts a recognizer: returning false stops it.
    // A long press that has fired must not also become a drag.
    /// UIKit asks this before a recognizer begins. We block a one-finger drag if a long press is active.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // Is this the one-finger pan, and is a long press in progress? (The cast is safe because of the `is` check.)
        if g is UIPanGestureRecognizer, (g as! UIPanGestureRecognizer).maximumNumberOfTouches == 1,
           longPress.state == .began || longPress.state == .changed || logic.longPressActive { return false }
        // Otherwise allow it.
        return true
    }
    /// Always answers no: two recognizers are never allowed to run at the same time.
    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { false }

    /// Tap recognizer callback.
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        // Act only when the tap is complete, and only if it landed on the video.
        guard g.state == .ended, let v = view, let e = logic.tap(g.location(in: v), bounds: v.bounds) else { return }
        // Send the click event.
        emit(e)
    }
    /// Long-press callback. It is called with several states over the life of one press.
    @objc private func onLong(_ g: UILongPressGestureRecognizer) {
        // Without a view there is nothing to convert.
        guard let v = view else { return }
        // React to the stage the press is in.
        switch g.state {
        case .began: if let e = logic.longPressBegan(g.location(in: v), bounds: v.bounds) { emit(e) }   // once per press
        // The press ended or was interrupted: release the lock so drags are allowed again.
        case .ended, .cancelled, .failed: logic.longPressEnded()
        // Other states need no action.
        default: break
        }
    }
    /// One-finger drag callback (a long drag produces many calls).
    @objc private func onDrag(_ g: UIPanGestureRecognizer) {
        // Without a view there is nothing to convert.
        guard let v = view else { return }
        // Where the finger is now, in the view's coordinates.
        let p = g.location(in: v)
        // React to the stage the drag is in.
        switch g.state {
        // Drag recognised.
        case .began:
            // the pan reports its position after the touch slop; the drag really started where the finger first landed
            // How far the finger has already moved since it first touched.
            let t = g.translation(in: v)
            // Subtract that to get the original touch-down point.
            let start = CGPoint(x: p.x - t.x, y: p.y - t.y)
            // Report the start, then immediately the current position so no movement is lost.
            if let e = logic.dragBegan(start, bounds: v.bounds) { emit(e) }
            if let e = logic.dragMoved(p, bounds: v.bounds) { emit(e) }
        // Finger moved: send the new position.
        case .changed: if let e = logic.dragMoved(p, bounds: v.bounds) { emit(e) }
        // Finger lifted or interrupted: always close the drag so the Mac releases the mouse button.
        case .ended, .cancelled, .failed: if let e = logic.dragEnded(p, bounds: v.bounds) { emit(e) }
        // Other states need no action.
        default: break
        }
    }
    /// Two-finger drag callback: used to rotate the camera (a middle-button drag on the Mac).
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        // Without a view there is nothing to convert.
        guard let v = view else { return }
        // Use the midpoint of the two fingers as the position.
        let p = g.location(in: v)      // centroid of the two fingers
        // React to the stage the gesture is in.
        switch g.state {
        // Start of the camera drag.
        case .began: if let e = logic.camBegan(p, bounds: v.bounds) { emit(e) }
        // Fingers moved: send the new position.
        case .changed: if let e = logic.camMoved(p, bounds: v.bounds) { emit(e) }
        // Fingers lifted or interrupted: close the camera drag so the Mac releases the middle button.
        case .ended, .cancelled, .failed: if let e = logic.camEnded(p, bounds: v.bounds) { emit(e) }
        // Other states need no action.
        default: break
        }
    }
    /// Pinch callback: sends a single zoom event when the pinch finishes.
    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        // Ignore everything until the pinch has ended.
        guard g.state == .ended else { return }
        // Send the total zoom amount of the whole pinch.
        emit(logic.pinchEnded(scale: g.scale))
    }
}
