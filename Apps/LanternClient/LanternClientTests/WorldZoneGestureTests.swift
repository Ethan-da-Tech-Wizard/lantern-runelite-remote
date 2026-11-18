// Program: Lantern - WorldZoneGestureTests.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Tests that a one-finger drag on the game world rotates the camera, drags elsewhere stay left-drags, and the related tap, long-press, pinch and camera-drag rules hold.
import XCTest
import LanternCore
@testable import LanternClient

// Tests for GestureLogic with the Fixed Classic world zone (OSRSZones).
final class WorldZoneGestureTests: XCTestCase {
    // Fixed classic window: 1038x531 pt at 2x = 2076x1062 px (765x503 canvas + 28 pt title bar).
    let classic = CGSize(width: 2076, height: 1062)
    // A landscape phone view; the video is letterboxed left and right inside it.
    let bounds = CGRect(x: 0, y: 0, width: 874, height: 402)

    // Helper: turns a canvas point (in window points, below the title bar) into a view point.
    func viewPoint(canvasX: Double, canvasY: Double, videoSize: CGSize) -> CGPoint {
        // The rectangle the video really covers inside the view.
        let r = VideoGeometry.videoRect(videoSize: videoSize, in: bounds)
        // Window point = canvas point plus the 28 pt title bar; window is 1038x531 pt.
        let fx = canvasX / 1038, fy = (canvasY + 28) / 531
        // Scale into the video rectangle.
        return CGPoint(x: r.minX + fx * r.width, y: r.minY + fy * r.height)
    }
    // Helper: a logic object with the given video size.
    func makeLogic(_ size: CGSize) -> GestureLogic { var l = GestureLogic(); l.videoSize = size; return l }

    // Scenario: one-finger drag starting on the 3D world (canvas 200,150).
    // Expected: camStart, camMove, camEnd; never dragStart.
    // Why it matters: the camera must rotate like the official mobile client.
    func testWorldDragIsCamera() {
        // Arrange.
        var l = makeLogic(classic)
        let a = viewPoint(canvasX: 200, canvasY: 150, videoSize: classic)
        let b = viewPoint(canvasX: 260, canvasY: 170, videoSize: classic)
        // Act and assert: start.
        guard case .camStart? = l.dragBegan(a, bounds: bounds) else { return XCTFail("expected camStart") }
        // Move.
        guard case .camMove? = l.dragMoved(b, bounds: bounds) else { return XCTFail("expected camMove") }
        // End.
        guard case .camEnd? = l.dragEnded(b, bounds: bounds) else { return XCTFail("expected camEnd") }
        // Assert: the state is closed.
        XCTAssertFalse(l.camDragging); XCTAssertFalse(l.dragging)
    }
    // Scenario: world corners just inside the zone (4,4) and (516,338).
    // Expected: both start a camera drag.
    // Why it matters: checks the edges of the world rectangle.
    func testWorldZoneEdgesAreCamera() {
        for (x, y) in [(5.0, 5.0), (515.0, 337.0)] {
            // Fresh logic each time.
            var l = makeLogic(classic)
            // Act.
            let e = l.dragBegan(viewPoint(canvasX: x, canvasY: y, videoSize: classic), bounds: bounds)
            // Assert.
            guard case .camStart? = e else { return XCTFail("expected camStart at \(x),\(y)") }
        }
    }
    // Scenario: drag starting on the inventory column (canvas 650,300).
    // Expected: dragStart, dragMove, dragEnd.
    // Why it matters: dragging items must stay a plain left-drag.
    func testInventoryDragIsLeftDrag() {
        // Arrange.
        var l = makeLogic(classic)
        let a = viewPoint(canvasX: 650, canvasY: 300, videoSize: classic)
        let b = viewPoint(canvasX: 650, canvasY: 330, videoSize: classic)
        // Act and assert each stage.
        guard case .dragStart? = l.dragBegan(a, bounds: bounds) else { return XCTFail("expected dragStart") }
        guard case .dragMove? = l.dragMoved(b, bounds: bounds) else { return XCTFail("expected dragMove") }
        guard case .dragEnd? = l.dragEnded(b, bounds: bounds) else { return XCTFail("expected dragEnd") }
    }
    // Scenario: drag starting on the chat box (canvas y 420).
    // Expected: a left drag, not a camera drag.
    // Why it matters: scrolling chat must not rotate the camera.
    func testChatDragIsLeftDrag() {
        // Arrange.
        var l = makeLogic(classic)
        // Act.
        let e = l.dragBegan(viewPoint(canvasX: 200, canvasY: 420, videoSize: classic), bounds: bounds)
        // Assert.
        guard case .dragStart? = e else { return XCTFail("expected dragStart") }
        XCTAssertFalse(l.camDragging)
    }
    // Scenario: default 16:9 video size (no title bar match), drag at the middle of the picture.
    // Expected: left drag everywhere (old behaviour).
    // Why it matters: unknown layouts must not get a camera zone.
    func testDefaultVideoSizeAlwaysLeftDrag() {
        // Arrange: default size 16x9.
        let size = CGSize(width: 16, height: 9)
        // Act and assert for several points.
        for (fx, fy) in [(0.5, 0.5), (0.2, 0.3), (0.9, 0.9)] {
            var l = makeLogic(size)
            let r = VideoGeometry.videoRect(videoSize: size, in: bounds)
            let p = CGPoint(x: r.minX + fx * r.width, y: r.minY + fy * r.height)
            guard case .dragStart? = l.dragBegan(p, bounds: bounds) else { return XCTFail("expected dragStart") }
            XCTAssertFalse(l.camDragging)
        }
    }
    // Scenario: a tap at the middle of the video.
    // Expected: .tap with about (0.5, 0.5).
    // Why it matters: the host clicks at these fractions.
    func testTapNormalized() {
        // Arrange.
        let l = makeLogic(classic)
        let r = VideoGeometry.videoRect(videoSize: classic, in: bounds)
        // Act: centre, and a quarter across / three quarters down.
        let c = l.tap(CGPoint(x: r.midX, y: r.midY), bounds: bounds)
        let q = l.tap(CGPoint(x: r.minX + r.width * 0.25, y: r.minY + r.height * 0.75), bounds: bounds)
        // Assert.
        guard case let .tap(x, y)? = c else { return XCTFail("expected tap") }
        XCTAssertEqual(x, 0.5, accuracy: 0.001); XCTAssertEqual(y, 0.5, accuracy: 0.001)
        guard case let .tap(x2, y2)? = q else { return XCTFail("expected tap") }
        XCTAssertEqual(x2, 0.25, accuracy: 0.001); XCTAssertEqual(y2, 0.75, accuracy: 0.001)
        // A tap in the black bar (x = 1) is ignored.
        XCTAssertNil(l.tap(CGPoint(x: 1, y: 200), bounds: bounds))
    }
    // Scenario: long press, then try to drag and start a camera drag, then release.
    // Expected: .longPress; drags blocked until longPressEnded.
    // Why it matters: a right-click press must not also drag or rotate.
    func testLongPressBlocksDrags() {
        // Arrange.
        var l = makeLogic(classic)
        let w = viewPoint(canvasX: 200, canvasY: 150, videoSize: classic)
        let i = viewPoint(canvasX: 650, canvasY: 300, videoSize: classic)
        // Act and assert: long press fires.
        guard case .longPress? = l.longPressBegan(w, bounds: bounds) else { return XCTFail("expected longPress") }
        // Blocked while active.
        XCTAssertNil(l.dragBegan(i, bounds: bounds))
        XCTAssertNil(l.dragBegan(w, bounds: bounds))
        XCTAssertNil(l.camBegan(w, bounds: bounds))
        // Released: drags work again.
        l.longPressEnded()
        XCTAssertNotNil(l.dragBegan(i, bounds: bounds))
    }
    // Scenario: pinch scale 1.5, 0.5, and extremes.
    // Expected: +0.5, -0.5, clamped to -1...1.
    // Why it matters: zoom direction and range sent to the Mac.
    func testPinchZoomSignAndClamp() {
        // Arrange.
        let l = makeLogic(classic)
        // Assert spread is positive.
        guard case let .zoom(d1) = l.pinchEnded(scale: 1.5) else { return XCTFail("expected zoom") }
        XCTAssertGreaterThan(d1, 0); XCTAssertEqual(d1, 0.5, accuracy: 0.001)
        // Assert squeeze is negative.
        guard case let .zoom(d2) = l.pinchEnded(scale: 0.5) else { return XCTFail("expected zoom") }
        XCTAssertLessThan(d2, 0); XCTAssertEqual(d2, -0.5, accuracy: 0.001)
        // Assert clamping.
        guard case let .zoom(d3) = l.pinchEnded(scale: 5) else { return XCTFail("expected zoom") }
        XCTAssertEqual(d3, 1)
        guard case let .zoom(d4) = l.pinchEnded(scale: -3) else { return XCTFail("expected zoom") }
        XCTAssertEqual(d4, -1)
    }
    // Scenario: camera drag whose finger ends far outside the video.
    // Expected: camEnd still emitted (clamped) and the drag closes; a second end gives nil.
    // Why it matters: the Mac must always release the middle button.
    func testCamEndClosesEvenOutsideVideo() {
        // Arrange.
        var l = makeLogic(classic)
        _ = l.camBegan(viewPoint(canvasX: 200, canvasY: 150, videoSize: classic), bounds: bounds)
        // Act: end way off the view.
        let e = l.camEnded(CGPoint(x: -500, y: 5000), bounds: bounds)
        // Assert: clamped to the bottom-left corner and closed.
        guard case let .camEnd(x, y)? = e else { return XCTFail("expected camEnd") }
        XCTAssertEqual(x, 0, accuracy: 0.001); XCTAssertEqual(y, 1, accuracy: 0.001)
        XCTAssertFalse(l.camDragging)
        XCTAssertNil(l.camEnded(.zero, bounds: bounds))
    }
    // Scenario: second camBegan while a camera drag is open.
    // Expected: nil, and the original drag is untouched.
    // Why it matters: only one camera drag may be open at once.
    func testSecondCamBeganReturnsNil() {
        // Arrange.
        var l = makeLogic(classic)
        let p = viewPoint(canvasX: 200, canvasY: 150, videoSize: classic)
        // Act and assert.
        XCTAssertNotNil(l.camBegan(p, bounds: bounds))
        XCTAssertNil(l.camBegan(p, bounds: bounds))
        XCTAssertTrue(l.camDragging)
    }
}
