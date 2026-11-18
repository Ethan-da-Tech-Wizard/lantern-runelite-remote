// Program: Lantern - AutoFocusTests.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Tests auto-focus and the window-cover check.
//
// Area protected: the input injector's focus handling (auto-focus) and the window
// occlusion check. These tests make sure taps are only injected when the target app is
// in front (or was successfully brought to the front), and that a full-screen
// Dock overlay is not mistaken for a window covering the game.
// All tests use fake environments, so no real windows or input are touched.
import XCTest
@testable import LanternHostKit
@testable import LanternCore

/// Environment whose frontmost app changes only when the injector asks to activate it.
// This is a fake: it counts how many times activation was requested, and can be set so
// that activation does nothing (to simulate the switch failing).
final class ActivatingEnv: WindowEnvironment, @unchecked Sendable {
    // Process id of the frontmost app; starts as some other app (99), not the target.
    var front: Int32? = 99          // another app is frontmost
    // How many times the injector asked to bring an app forward.
    var activations = 0
    // When true, activating an app really makes it frontmost; set false to simulate a failure.
    var worksOnActivate = true
    // Fixed window frame, slightly over 800 x 600, so tap coordinates have a known target.
    func frame(ofWindow id: UInt32) -> CGRect? { CGRect(x: 100, y: 200, width: 801, height: 601) }
    // Report whichever app is currently in front.
    func frontmostPID() -> Int32? { front }
    // Report that the target window (id 7, owner 42) is on top at any point.
    func topWindow(at point: CGPoint) -> (id: UInt32, pid: Int32)? { (7, 42) }
    // Report a cursor position inside the window.
    func cursorLocation() -> CGPoint? { CGPoint(x: 300, y: 300) }
    // Focused window is the target window only once the target app is in front.
    func focusedWindow() -> FocusedWindow { front == 42 ? .window(7) : .window(1) }
    // Record the activation request; only change the frontmost app if allowed to.
    func activateApp(pid: Int32) { activations += 1; if worksOnActivate { front = pid } }
}

// Tests for the auto-focus option of InputInjector.
final class AutoFocusTests: XCTestCase {
    // The target window used by every test: an app with process id 42.
    let win = WindowInfo(id: 7, ownerName: "RuneLite", ownerPID: 42, title: "RuneLite", frame: .zero)

    // Scenario: another app is in front and auto-focus is off (the default).
    // Expected: the tap is refused with notFrontmost, the app is never activated, and
    // nothing is sent to the input sink.
    // Why it matters: by default the tool must never steal focus or click into the wrong app.
    func testDefaultStillRefusesWhenNotFrontmost() {
        // Arrange: a fake environment and a recording sink, then an injector without auto-focus.
        let env = ActivatingEnv(); let sink = RecordingSink()
        // Create the injector under test (auto-focus is not requested).
        let inj = InputInjector(target: win, environment: env, sink: sink)
        // Act and assert: tapping throws the notFrontmost error.
        XCTAssertThrowsError(try inj.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .notFrontmost) }
        // Assert: no activation happened and no input actions were recorded.
        XCTAssertEqual(env.activations, 0); XCTAssertTrue(sink.actions.isEmpty)
    }
    // Scenario: auto-focus is on and the switch works.
    // Expected: the app is brought forward exactly once and then the tap goes through.
    // Why it matters: this is the whole purpose of the auto-focus option.
    func testAutoFocusBringsAppForwardThenInjects() throws {
        // Arrange: fake environment and sink.
        let env = ActivatingEnv(); let sink = RecordingSink()
        // Create the injector with auto-focus turned on.
        let inj = InputInjector(target: win, environment: env, sink: sink, autoFocus: true)
        // Act: tap the middle of the window.
        try inj.apply(.tap(x: 0.5, y: 0.5))
        // Assert: one activation request and some actions were sent to the sink.
        XCTAssertEqual(env.activations, 1); XCTAssertFalse(sink.actions.isEmpty)
    }
    // Scenario: auto-focus is on but activation does nothing, so the target never gets focus.
    // Expected: the tap is refused with focusNotAcquired (naming the front and target
    // processes) and nothing is sent.
    // Why it matters: the injector must verify focus really changed instead of trusting the request.
    func testAutoFocusStillRefusesIfSwitchDoesNotHappen() {
        // Arrange: make activation fail.
        let env = ActivatingEnv(); env.worksOnActivate = false; let sink = RecordingSink()
        // Create the injector with auto-focus turned on.
        let inj = InputInjector(target: win, environment: env, sink: sink, autoFocus: true)
        // Act and assert: tapping throws focusNotAcquired with front 99 and target 42.
        XCTAssertThrowsError(try inj.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .focusNotAcquired(front: 99, target: 42)) }
        // Assert: nothing was injected.
        XCTAssertTrue(sink.actions.isEmpty)
    }
    // Scenario: auto-focus is on, but the tap is outside the window (x of 1.5).
    // Expected: the tap is still refused and nothing is injected.
    // Why it matters: auto-focus must only solve the focus problem, never skip the other safety checks.
    func testAutoFocusDoesNotBypassOtherChecks() {
        // Arrange: fake environment and sink.
        let env = ActivatingEnv(); let sink = RecordingSink()
        // Create the injector with auto-focus turned on.
        let inj = InputInjector(target: win, environment: env, sink: sink, autoFocus: true)
        // Act and assert: a tap at x of 1.5 (outside the window) throws an error.
        XCTAssertThrowsError(try inj.apply(.tap(x: 1.5, y: 0.5)))   // outside the window: still refused after the switch
        // Assert: nothing was injected.
        XCTAssertTrue(sink.actions.isEmpty)
    }
}

// Tests for how the window lookup treats the Dock when it covers the screen.
final class DockOverlayTests: XCTestCase {
    // Scenario: a full-screen Dock-owned window sits at a higher layer than the game window.
    // Expected: it is ignored as an occluder (the game is the top window at the point),
    // but a small Dock bar that really covers the probed point is still counted.
    // Why it matters: otherwise the game would always look covered and input would be refused.
    func testFullScreenDockOverlayIsNotAnOccluder() {
        // Arrange: the game window (id 5) in the middle of the screen.
        let game = WindowInfo(id: 5, ownerName: "RuneLite", ownerPID: 42, title: "RuneLite", frame: CGRect(x: 100, y: 100, width: 800, height: 500), layer: 0, alpha: 1)
        // Arrange: a full-screen Dock overlay (id 7) on a higher layer.
        let dock = WindowInfo(id: 7, ownerName: "Dock", ownerPID: 1, title: "", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 20, alpha: 1)
        // Assert: at a point over the game, the top window is the game (id 5), not the Dock.
        XCTAssertEqual(SystemWindowEnvironment.topWindow(at: CGPoint(x: 300, y: 300), in: [dock, game])?.id, 5)
        // Arrange: a small Dock bar (id 8) that sits low on the screen.
        let bar = WindowInfo(id: 8, ownerName: "Dock", ownerPID: 1, title: "", frame: CGRect(x: 200, y: 800, width: 600, height: 80), layer: 20, alpha: 1)
        // Assert: at a point over that bar, the top window is the bar (id 8), so real covers still count.
        XCTAssertEqual(SystemWindowEnvironment.topWindow(at: CGPoint(x: 300, y: 820), in: [bar, game])?.id, 8)
    }
}
