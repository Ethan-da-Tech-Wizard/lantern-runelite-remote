// Program: Lantern - GeometryAndGestureTests.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Tests how touches map onto the video and the gesture rules.
//
// Area protected: how touches on the phone map onto the video (VideoGeometry) and how
// gestures turn into input events (GestureLogic). It checks letterbox math, coordinate
// normalizing, clamping, and rules like one tap is one event, long press blocks drag,
// drags start and end once, and scroll and pinch are sent once at the end.
// Wrong math here would make taps land in the wrong place on the host.
import XCTest
import LanternCore
@testable import LanternClient

// Tests for video geometry and gesture logic.
final class GeometryAndGestureTests: XCTestCase {
    // Sample video size.
    let video = CGSize(width: 1600, height: 900)           // 16:9
    // Sample view bounds.
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 800) // portrait: letterboxed top/bottom, video rect 400x225 centered

    // Scenario: fit a 16:9 video in a portrait view.
    // Expected: the video is 400 x 225 and starts at y 287.5 (centered); an empty video or empty bounds gives an empty rect.
    // Why it matters: touches must be measured against the picture, not the black bars.
    func testVideoRectLetterbox() {
        // Act: compute the video rect.
        let r = VideoGeometry.videoRect(videoSize: video, in: bounds)
        // Assert: width and height.
        XCTAssertEqual(r.width, 400, accuracy: 0.01); XCTAssertEqual(r.height, 225, accuracy: 0.01)
        // Assert: top edge is centered vertically.
        XCTAssertEqual(r.minY, 287.5, accuracy: 0.01)
        // Assert: empty video size gives zero rect.
        XCTAssertEqual(VideoGeometry.videoRect(videoSize: .zero, in: bounds), .zero)
        // Assert: empty bounds gives zero rect.
        XCTAssertEqual(VideoGeometry.videoRect(videoSize: video, in: .zero), .zero)
    }
    // Scenario: convert touch points into 0 to 1 video coordinates.
    // Expected: the view center maps to (0.5, 0.5) and the top-left of the picture to (0, 0).
    // Why it matters: the host uses these fractions to find the click position.
    func testNormalizeInsideAndCorners() throws {
        // Act: the center of the view.
        let c = try XCTUnwrap(VideoGeometry.normalize(CGPoint(x: 200, y: 400), videoSize: video, bounds: bounds, clamp: false))
        // Assert: x and y are one half.
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-4); XCTAssertEqual(c.y, 0.5, accuracy: 1e-4)
        // Act: the top-left corner of the video area.
        let tl = try XCTUnwrap(VideoGeometry.normalize(CGPoint(x: 0, y: 287.5), videoSize: video, bounds: bounds, clamp: false))
        // Assert: x and y are zero.
        XCTAssertEqual(tl.x, 0, accuracy: 1e-4); XCTAssertEqual(tl.y, 0, accuracy: 1e-4)
    }
    // Scenario: points outside the picture, with clamping off and on.
    // Expected: without clamping they give nil; with clamping they are pinned to the edge; an empty video still gives nil.
    // Why it matters: a tap on a black bar must not click the game, but a drag that leaves the picture should stay on its edge.
    func testOutsideRectIsNilUnlessClamped() throws {
        // Without clamping: a point on the top bar is nil.
        XCTAssertNil(VideoGeometry.normalize(CGPoint(x: 200, y: 100), videoSize: video, bounds: bounds, clamp: false))  // letterbox bar
        // Without clamping: a point left of the view is nil.
        XCTAssertNil(VideoGeometry.normalize(CGPoint(x: -5, y: 400), videoSize: video, bounds: bounds, clamp: false))
        // With clamping: the same bar point maps to the top edge.
        let c = try XCTUnwrap(VideoGeometry.normalize(CGPoint(x: 200, y: 100), videoSize: video, bounds: bounds, clamp: true))
        // Assert: y is zero.
        XCTAssertEqual(c.y, 0, accuracy: 1e-4)
        // With clamping: a far-away point maps to the bottom-right corner.
        let d = try XCTUnwrap(VideoGeometry.normalize(CGPoint(x: 9999, y: 9999), videoSize: video, bounds: bounds, clamp: true))
        // Assert: x and y are one.
        XCTAssertEqual(d.x, 1); XCTAssertEqual(d.y, 1)
        // With an empty video there is nothing to map to, so nil.
        XCTAssertNil(VideoGeometry.normalize(.zero, videoSize: .zero, bounds: bounds, clamp: true))
    }

    // Helper: a gesture logic already told the video size.
    private func logic() -> GestureLogic { var l = GestureLogic(); l.videoSize = video; return l }
    // The center point of the view, used by many tests.
    let mid = CGPoint(x: 200, y: 400)

    // Scenario: a tap inside and outside the picture.
    // Expected: inside gives one tap event at the center; outside gives nothing.
    // Why it matters: one touch must be one click, and bars must be ignored.
    func testTapIsOneEventAndOutsideIsNone() {
        // Arrange: a gesture logic.
        let l = logic()
        // Assert: tap in the middle gives a center tap.
        XCTAssertEqual(l.tap(mid, bounds: bounds), .tap(x: 0.5, y: 0.5))
        // Assert: tap on the bar gives nothing.
        XCTAssertNil(l.tap(CGPoint(x: 200, y: 10), bounds: bounds))
    }
    // Scenario: a long press, then drag callbacks during it.
    // Expected: the long press gives an event; drag begin, move and end are ignored; after the long press ends, a drag may start.
    // Why it matters: one finger must never be both a long press and a drag.
    func testLongPressBlocksDragUntilEnd() {
        // Arrange: a gesture logic.
        var l = logic()
        // Act: long press begins; assert event at center.
        XCTAssertEqual(l.longPressBegan(mid, bounds: bounds), .longPress(x: 0.5, y: 0.5))
        // Drag start is blocked.
        XCTAssertNil(l.dragBegan(mid, bounds: bounds))            // cannot also start a drag
        // Drag move is blocked.
        XCTAssertNil(l.dragMoved(mid, bounds: bounds))
        // Drag end is blocked.
        XCTAssertNil(l.dragEnded(mid, bounds: bounds))            // no stray dragEnd
        // Act: the long press ends.
        l.longPressEnded()
        // Assert: a drag can now begin.
        XCTAssertNotNil(l.dragBegan(mid, bounds: bounds))
    }
    // Scenario: a full drag with odd inputs.
    // Expected: move or end without start gives nothing; start outside gives nothing; start works once;
    // moves and ends are clamped into 0 to 1; the end happens exactly once and dragging stops.
    // Why it matters: the host expects a clean start, move and end, never extras.
    func testDragSequenceAndClamping() {
        // Arrange: a gesture logic.
        var l = logic()
        // Move without a start gives nothing.
        XCTAssertNil(l.dragMoved(mid, bounds: bounds))            // move without start: nothing
        // Start outside the picture gives nothing.
        XCTAssertNil(l.dragBegan(CGPoint(x: 200, y: 10), bounds: bounds))   // start outside: no drag
        // Start inside gives a drag start.
        XCTAssertEqual(l.dragBegan(mid, bounds: bounds), .dragStart(x: 0.5, y: 0.5))
        // A second start is ignored.
        XCTAssertNil(l.dragBegan(mid, bounds: bounds))            // no second start
        // A move far off the right edge is clamped to x of 1.
        XCTAssertEqual(l.dragMoved(CGPoint(x: 5000, y: 400), bounds: bounds), .dragMove(x: 1, y: 0.5))
        // An end off the left and bottom is clamped to (0, 1).
        XCTAssertEqual(l.dragEnded(CGPoint(x: -50, y: 9000), bounds: bounds), .dragEnd(x: 0, y: 1))
        // A second end is ignored.
        XCTAssertNil(l.dragEnded(mid, bounds: bounds))            // exactly one end
        // Assert: dragging is over.
        XCTAssertFalse(l.dragging)
    }
    // Scenario: a scroll gesture ends with a very large movement.
    // Expected: one scroll event whose values are scaled to the view and clamped; empty bounds give nothing.
    // Why it matters: scroll is sent once at the end and must not be wild.
    func testScrollOnceAtEndWithClampedTotal() throws {
        // Arrange: a gesture logic.
        let l = logic()
        // Act: end a scroll with a big upward movement.
        let e = try XCTUnwrap(l.scrollEnded(translation: CGPoint(x: 100, y: -9999), bounds: bounds))
        // Check that the event is a scroll, otherwise fail.
        guard case .scroll(let dx, let dy) = e else { return XCTFail("not scroll") }
        // Assert: horizontal part is a quarter of the view; vertical is clamped to minus one.
        XCTAssertEqual(dx, 0.25, accuracy: 1e-4); XCTAssertEqual(dy, -1)
        // Assert: empty bounds give nothing.
        XCTAssertNil(GestureLogic().scrollEnded(translation: CGPoint(x: 1, y: 1), bounds: .zero))
    }
    // Scenario: pinch ends with different scales.
    // Expected: scale 1.5 gives zoom 0.5; huge scale is clamped to 1; not-a-number gives 0.
    // Why it matters: zoom is sent once at the end and must be a sane number.
    func testPinchOnceAtEnd() {
        // Arrange: a gesture logic.
        let l = logic()
        // Normal pinch outward.
        XCTAssertEqual(l.pinchEnded(scale: 1.5), .zoom(delta: 0.5))
        // Huge pinch is clamped.
        XCTAssertEqual(l.pinchEnded(scale: 10), .zoom(delta: 1))
        // Invalid value becomes no zoom.
        XCTAssertEqual(l.pinchEnded(scale: .nan), .zoom(delta: 0))
    }
}
