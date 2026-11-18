// Area protected: the host side of the app (LanternHostKit). It covers window geometry
// (mapping 0 to 1 coordinates to screen points), the input injector's safety rules (only act
// when the target window is in front, focused, not covered, and the point is inside; rate
// limits; no stuck buttons), key text limits, modifier handling, overlay and focus detection,
// H.264 format conversion, the video encoder with synthetic frames, and camera-drag input.
// All input tests use fake environments and a recording sink, so no real mouse or keyboard is touched.
import XCTest
import CoreGraphics
import CoreVideo
import CoreMedia
import LanternCore
@testable import LanternHostKit

// Test helper: a fake window environment. Tests change its fields to simulate the target
// moving, another app being in front, a window covering the target, or focus being elsewhere.
final class FakeEnv: WindowEnvironment, @unchecked Sendable {
    // The target window frame (a little over 800 x 600).
    var frameV: CGRect? = CGRect(x: 100, y: 200, width: 801, height: 601)
    // Which process is in front (42 is the target).
    var front: Int32? = 42
    // Which window is on top at the probed point (7 is the target).
    var top: (id: UInt32, pid: Int32)? = (7, 42)
    // Where the pointer is (inside the window).
    var cursor: CGPoint? = CGPoint(x: 300, y: 300)
    // Which window has keyboard focus (the target).
    var focus: FocusedWindow = .window(7)
    // Each method just reports the matching field above.
    func frame(ofWindow id: UInt32) -> CGRect? { frameV }
    func frontmostPID() -> Int32? { front }
    func topWindow(at point: CGPoint) -> (id: UInt32, pid: Int32)? { top }
    func cursorLocation() -> CGPoint? { cursor }
    func focusedWindow() -> FocusedWindow { focus }
}

// Test helper: a mutable clock value that tests can move by hand.
final class ClockCell: @unchecked Sendable { var v: UInt64; init(_ v: UInt64) { self.v = v } }

// Test helper: a clock that goes forward 100 ms every time it is read, so rate limits never trigger by accident.
final class ClockBox: @unchecked Sendable {
    private let l = NSLock(); private var t: UInt64 = 1000
    func next() -> UInt64 { l.withLock { t += 100; return t } }
}

// Tests for mapping 0 to 1 coordinates onto a window frame.
final class GeometryTests: XCTestCase {
    // Sample frame used by the tests below.
    let f = CGRect(x: 100, y: 200, width: 801, height: 601)
    // Scenario: map the corners and center of the window.
    // Expected: (0,0) is the top-left, (1,1) the bottom-right, (0.5,0.5) the middle, and the far corner is inside.
    // Why it matters: every click depends on this math.
    func testCornersAndCenter() {
        // Top-left corner.
        XCTAssertEqual(WindowGeometry.point(normX: 0, normY: 0, in: f), CGPoint(x: 100, y: 200))
        // Bottom-right corner.
        XCTAssertEqual(WindowGeometry.point(normX: 1, normY: 1, in: f), CGPoint(x: 900, y: 800))
        // Center.
        XCTAssertEqual(WindowGeometry.point(normX: 0.5, normY: 0.5, in: f), CGPoint(x: 500, y: 500))
        // The far corner counts as inside the frame.
        XCTAssertTrue(WindowGeometry.contains(CGPoint(x: 900, y: 800), in: f))
    }
    // Scenario: coordinates outside 0 to 1, not a number, or an empty frame.
    // Expected: no point (nil).
    // Why it matters: bad input must not turn into a click somewhere else.
    func testOutOfRangeDropped() {
        // Slightly negative.
        XCTAssertNil(WindowGeometry.point(normX: -0.01, normY: 0.5, in: f))
        // Slightly over 1.
        XCTAssertNil(WindowGeometry.point(normX: 0.5, normY: 1.01, in: f))
        // Not a number.
        XCTAssertNil(WindowGeometry.point(normX: .nan, normY: 0.5, in: f))
        // Empty frame.
        XCTAssertNil(WindowGeometry.point(normX: 0.5, normY: 0.5, in: .zero))
    }
    // Scenario: convert a point to a screen position and back; match windows by name text.
    // Expected: the round trip returns about the same numbers; matching is case-insensitive over owner and title, and empty or unrelated text does not match.
    // Why it matters: round trip proves the math is reversible, and matching picks the right window.
    func testRoundTripAndMatch() {
        // Act: to a screen point.
        let p = WindowGeometry.point(normX: 0.25, normY: 0.75, in: f)!
        // Act: back to fractions.
        let n = WindowGeometry.normalized(p, in: f)
        // Assert: close to the original.
        XCTAssertEqual(n.x, 0.25, accuracy: 0.001); XCTAssertEqual(n.y, 0.75, accuracy: 0.001)
        // Arrange: a window description with an owner and title.
        let w = WindowInfo(id: 1, ownerName: "RuneLite", ownerPID: 1, title: "RuneLite - Bob", frame: f)
        // Assert: owner text and title text match; empty and unrelated text do not.
        XCTAssertTrue(w.matches("runelite")); XCTAssertTrue(w.matches("bob")); XCTAssertFalse(w.matches("")); XCTAssertFalse(w.matches("chrome"))
    }
    // Scenario: the window moves or resizes.
    // Expected: the same fraction maps to the new frame's corner.
    // Why it matters: clicks must follow the window.
    func testMovedWindowRemaps() {
        // Arrange: a smaller frame at a new place.
        let g = CGRect(x: 0, y: 0, width: 401, height: 301)
        // Assert: (1,1) maps to its bottom-right point.
        XCTAssertEqual(WindowGeometry.point(normX: 1, normY: 1, in: g), CGPoint(x: 400, y: 300))
    }
}

// Tests for the input injector and its refusal rules.
final class InjectorTests: XCTestCase {
    // Target window used by these tests.
    let win = WindowInfo(id: 7, ownerName: "RuneLite", ownerPID: 42, title: "RuneLite", frame: .zero)
    // A shared clock that always moves forward.
    static let ctr = ClockBox()
    // Helper: builds an injector on a fake environment with a recording sink.
    func make(_ env: FakeEnv) -> (InputInjector, RecordingSink) {
        // A sink that records instead of clicking.
        let s = RecordingSink()
        let i = InputInjector(target: win, environment: env, sink: s, clock: { InjectorTests.ctr.next() })
        return (i, s)
    }
    // Scenario: a tap.
    // Expected: move, mouse down, mouse up at the middle of the window.
    // Why it matters: that is the whole click sequence.
    func testTapIsMoveDownUp() throws {
        // Arrange: a healthy environment.
        let (i, s) = make(FakeEnv())
        // Act: tap the middle.
        try i.apply(.tap(x: 0.5, y: 0.5))
        // Assert: exact three actions at (500, 500).
        XCTAssertEqual(s.actions, [.move(CGPoint(x: 500, y: 500)), .leftDown(CGPoint(x: 500, y: 500)), .leftUp(CGPoint(x: 500, y: 500))])
    }
    // Scenario: a long press.
    // Expected: a right mouse press at the window corner.
    // Why it matters: long press stands in for a right click.
    func testLongPressIsRightClick() throws {
        // Act: long press at the top-left.
        let (i, s) = make(FakeEnv()); try i.apply(.longPress(x: 0, y: 0))
        // Assert: a right-down was recorded at that point.
        XCTAssertTrue(s.actions.contains(.rightDown(CGPoint(x: 100, y: 200))))
    }
    // Scenario: another app is in front.
    // Expected: refused with notFrontmost and nothing recorded.
    // Why it matters: never click into an app the user is not looking at.
    func testRefusesWhenNotFrontmost() {
        // Arrange: pretend another process is in front.
        let e = FakeEnv(); e.front = 99
        // Build the injector.
        let (i, s) = make(e)
        // Act and assert: the tap throws notFrontmost.
        XCTAssertThrowsError(try i.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .notFrontmost) }
        // Assert: nothing recorded.
        XCTAssertTrue(s.actions.isEmpty)
    }
    // Scenario: another window covers the click point.
    // Expected: refused with occludedBy, naming the covering window id; nothing recorded.
    // Why it matters: the click would land on the wrong window.
    func testRefusesWhenOccluded() {
        // Arrange: a different window is on top.
        let e = FakeEnv(); e.top = (8, 50)
        // Build the injector.
        let (i, s) = make(e)
        // Act and assert: the tap throws, and the error names the covering window.
        XCTAssertThrowsError(try i.apply(.tap(x: 0.5, y: 0.5))) {
            guard case .occludedBy(let who)? = $0 as? InjectError else { return XCTFail("expected occludedBy, got \($0)") }
            XCTAssertTrue(who.contains("8"))
        }
        // Assert: nothing recorded.
        XCTAssertTrue(s.actions.isEmpty)
    }
    // Scenario: a tap outside the window, then the window disappears.
    // Expected: outsideWindow, then windowGone; nothing recorded.
    // Why it matters: both cases must refuse.
    func testRefusesOutOfRangeAndGone() {
        // Arrange: environment and injector.
        let e = FakeEnv(); let (i, s) = make(e)
        // Act and assert: a tap with x of 1.5 is outside.
        XCTAssertThrowsError(try i.apply(.tap(x: 1.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .outsideWindow) }
        // Make the window vanish.
        e.frameV = nil
        // Act and assert: the next tap says the window is gone.
        XCTAssertThrowsError(try i.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .windowGone) }
        // Assert: nothing recorded.
        XCTAssertTrue(s.actions.isEmpty)
    }
    // Scenario: scroll and zoom, then a key press while the pointer is outside the window.
    // Expected: scroll and zoom become two scroll actions; the key is refused with outsideWindow and adds nothing.
    // Why it matters: key presses should go only where the pointer is over the game.
    func testScrollAndKeyNeedPointerInWindow() throws {
        // Arrange: environment and injector.
        let e = FakeEnv(); let (i, s) = make(e)
        // Act: scroll and zoom.
        try i.apply(.scroll(dx: 0, dy: 0.5)); try i.apply(.zoom(delta: -1))
        // Assert: two scroll actions with scaled pixel amounts.
        XCTAssertEqual(s.actions, [.scroll(dxPixels: 0, dyPixels: 20), .scroll(dxPixels: 0, dyPixels: -40)])
        // Move the pointer far outside the window.
        e.cursor = CGPoint(x: 5, y: 5)
        // Act and assert: the key is refused.
        XCTAssertThrowsError(try i.apply(.key(text: "a", mods: 0))) { XCTAssertEqual($0 as? InjectError, .outsideWindow) }
        // Assert: still only the two earlier actions.
        XCTAssertEqual(s.actions.count, 2)
    }
    // Scenario: two taps with the clock frozen.
    // Expected: the second is rejected and is not queued.
    // Why it matters: too-fast input is dropped, not replayed later.
    func testRateLimitNoQueue() throws {
        // Arrange: a sink, environment and injector with a frozen clock.
        let s = RecordingSink(); let e = FakeEnv()
        let i = InputInjector(target: win, environment: e, sink: s, clock: { 5000 })
        // Act: the first tap passes.
        try i.apply(.tap(x: 0.5, y: 0.5))
        // Act and assert: the second is rejected.
        XCTAssertThrowsError(try i.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .rejected) }
        // Assert: only the first tap's three actions exist.
        XCTAssertEqual(s.actions.count, 3)   // second tap produced nothing, nothing queued
    }
    // Scenario: start a drag, move, then release all.
    // Expected: the last action is a mouse-up; releasing again adds nothing.
    // Why it matters: stopping must never leave a button held down.
    func testDragAndReleaseAll() throws {
        // Arrange: environment and injector.
        let (i, s) = make(FakeEnv())
        // Act: start and move.
        try i.apply(.dragStart(x: 0.1, y: 0.1)); try i.apply(.dragMove(x: 0.2, y: 0.2))
        // Act: release everything.
        i.releaseAll()
        // Assert: the last action is a mouse-up.
        guard case .leftUp = s.actions.last else { return XCTFail("no mouse-up on releaseAll") }
        // Remember the count and release again.
        let n = s.actions.count; i.releaseAll()
        // Assert: nothing new was added.
        XCTAssertEqual(s.actions.count, n)   // idempotent
    }
    // Scenario: drag move without a drag start.
    // Expected: error, nothing recorded.
    // Why it matters: stray moves must not press buttons.
    func testDragMoveWithoutStartRejected() {
        // Arrange: environment and injector.
        let (i, s) = make(FakeEnv())
        // Act and assert: it throws.
        XCTAssertThrowsError(try i.apply(.dragMove(x: 0.2, y: 0.2)))
        // Assert: nothing recorded.
        XCTAssertTrue(s.actions.isEmpty)
    }
    // M3: focus binding, modifiers, key text, global cap, overlay occlusion
    // Scenario: the target app is in front but a different window of it (or none, or another app) has focus.
    // Expected: key and tap are refused with notFocused; nothing recorded.
    // Why it matters: typing into the wrong window of the same app would be harmful.
    func testRefusesWhenAnotherWindowOfSameAppIsFocused() {
        // Arrange: focus is on window 99.
        let e = FakeEnv(); e.focus = .window(99)
        // Build the injector.
        let (i, s) = make(e)
        // Key refused.
        XCTAssertThrowsError(try i.apply(.key(text: "a", mods: 0))) { XCTAssertEqual($0 as? InjectError, .notFocused) }
        // Tap refused.
        XCTAssertThrowsError(try i.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .notFocused) }
        // No focused window.
        e.focus = .none
        // Tap refused.
        XCTAssertThrowsError(try i.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .notFocused) }
        // Focus elsewhere.
        e.focus = .other
        // Tap refused.
        XCTAssertThrowsError(try i.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .notFocused) }
        // Assert: nothing recorded.
        XCTAssertTrue(s.actions.isEmpty)
    }
    // Scenario: the system cannot tell which window has focus (for example no accessibility access).
    // Expected: refused with focusUnknown; nothing recorded.
    // Why it matters: when unsure, do nothing.
    func testRefusesGracefullyWhenAccessibilityUnavailable() {
        // Arrange: focus is unavailable.
        let e = FakeEnv(); e.focus = .unavailable
        // Build the injector.
        let (i, s) = make(e)
        // Act and assert: refused.
        XCTAssertThrowsError(try i.apply(.tap(x: 0.5, y: 0.5))) { XCTAssertEqual($0 as? InjectError, .focusUnknown) }
        // Assert: nothing recorded.
        XCTAssertTrue(s.actions.isEmpty)
    }
    // Scenario: key presses with modifier bits.
    // Expected: by default the modifiers are removed; with the allow flag, only the four defined modifier bits survive.
    // Why it matters: stray modifier keys could trigger shortcuts.
    func testModifiersStrippedByDefaultAndAllowedByFlag() throws {
        // Arrange: a default injector.
        let (i, s) = make(FakeEnv())
        // Act: key with several modifier bits.
        try i.apply(.key(text: "a", mods: 0x0e))
        // Assert: the modifiers are cleared.
        XCTAssertEqual(s.actions, [.keyText("a", mods: 0)])
        // Arrange: an injector that allows modifiers.
        let s2 = RecordingSink()
        // Build it.
        let j = InputInjector(target: win, environment: FakeEnv(), sink: s2, allowModifiers: true, clock: { InjectorTests.ctr.next() })
        // Act: key with extra bits set.
        try j.apply(.key(text: "a", mods: 0xfa))
        // Assert: only defined bits remain.
        XCTAssertEqual(s2.actions, [.keyText("a", mods: 0x0a)])   // only the four defined bits
    }
    // Scenario: key text of various lengths and with control characters.
    // Expected: 32 characters are fine; 33, empty and escape sequences are refused; a trailing newline is allowed.
    // Why it matters: limits what can be typed in one event.
    func testKeyTextCapAndControlCharacters() {
        // Arrange: a sample frame.
        let f = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 32 characters pass.
        XCTAssertNotNil(InputPlanner.plan(.key(text: String(repeating: "a", count: 32), mods: 0), frame: f))
        // 33 characters fail.
        XCTAssertNil(InputPlanner.plan(.key(text: String(repeating: "a", count: 33), mods: 0), frame: f))
        // Empty fails.
        XCTAssertNil(InputPlanner.plan(.key(text: "", mods: 0), frame: f))
        // Escape sequence fails.
        XCTAssertNil(InputPlanner.plan(.key(text: "a\u{1b}[2J", mods: 0), frame: f))
        // A newline is allowed.
        XCTAssertNotNil(InputPlanner.plan(.key(text: "hi\n", mods: 0), frame: f))
    }
    // Scenario: four different kinds of events within a short time, with a global cap of 3.
    // Expected: three pass and one is rejected; after the window moves on, a new event passes.
    // Why it matters: the cap works across kinds and nothing is replayed.
    func testGlobalCapAcrossClasses() throws {
        // Arrange: a sink and a clock the test controls.
        let s = RecordingSink()
        let t = ClockCell(10_000)
        // Injector with a global cap of 3.
        let i = InputInjector(target: win, environment: FakeEnv(), sink: s, minSpacingMs: 50, globalMax: 3, clock: { t.v })
        // Four events of different kinds.
        let evs: [InputEvent] = [.tap(x: 0.5, y: 0.5), .scroll(dx: 0, dy: 0.1), .zoom(delta: 0.1), .key(text: "a", mods: 0)]
        // Counters.
        var ok = 0, rejected = 0
        // Act: apply each, counting successes and rejections, moving the clock 1 ms each.
        for e in evs { do { try i.apply(e); ok += 1 } catch { rejected += 1 }; t.v += 1 }
        // Assert: 3 accepted, 1 rejected.
        XCTAssertEqual(ok, 3); XCTAssertEqual(rejected, 1)     // every class is within its own limit; the global cap drops the 4th
        // Advance the clock one second.
        t.v += 1000
        // Assert: a new event is accepted and the dropped one is not replayed.
        XCTAssertNoThrow(try i.apply(.key(text: "b", mods: 0)))   // window slides, no queue replays the dropped one
    }
    // Scenario: windows above the target at different layers, invisible ones, and ones elsewhere.
    // Expected: a visible overlay at any layer over the point counts as covering; an invisible one, or one in another place, does not.
    // Why it matters: notification banners and similar overlays must block clicks.
    func testOverlayWindowOnAnyLayerOccludes() {
        // Arrange: the target frame and a point inside it.
        let target = CGRect(x: 100, y: 200, width: 800, height: 600)
        let p = CGPoint(x: 500, y: 500)
        // Helper: builds a window description with an id, layer, opacity and frame.
        func w(_ id: UInt32, layer: Int, alpha: Double = 1, frame: CGRect = target) -> WindowInfo {
            WindowInfo(id: id, ownerName: "x", ownerPID: Int32(id), title: "", frame: frame, layer: layer, alpha: alpha)
        }
        // front-to-back: notification banner (layer 25) above the target (layer 0)
        XCTAssertEqual(SystemWindowEnvironment.topWindow(at: p, in: [w(50, layer: 25), w(7, layer: 0)])?.id, 50)
        XCTAssertEqual(SystemWindowEnvironment.topWindow(at: p, in: [w(51, layer: 3), w(7, layer: 0)])?.id, 51)
        // invisible overlay does not occlude; overlay elsewhere does not occlude; target on top is fine
        XCTAssertEqual(SystemWindowEnvironment.topWindow(at: p, in: [w(52, layer: 25, alpha: 0), w(7, layer: 0)])?.id, 7)
        XCTAssertEqual(SystemWindowEnvironment.topWindow(at: p, in: [w(53, layer: 25, frame: CGRect(x: 0, y: 0, width: 10, height: 10)), w(7, layer: 0)])?.id, 7)
    }
    // Scenario: match the focused window from the accessibility frame and title.
    // Expected: exact match gives that window; a frame off by one pixel still matches; a different title or process gives other.
    // Why it matters: identifies which window truly has focus.
    func testFocusedWindowMatchByFrameAndTitle() {
        // Arrange: the target frame.
        let f = CGRect(x: 100, y: 200, width: 800, height: 600)
        // Arrange: two windows from the same app.
        let ws = [WindowInfo(id: 9, ownerName: "R", ownerPID: 42, title: "Config", frame: CGRect(x: 300, y: 300, width: 300, height: 200)),
                  WindowInfo(id: 7, ownerName: "R", ownerPID: 42, title: "RuneLite", frame: f)]
        // Assert: exact frame and title picks window 7.
        XCTAssertEqual(SystemWindowEnvironment.matchFocused(axFrame: f, axTitle: "RuneLite", pid: 42, windows: ws), .window(7))
        // Assert: a one-pixel difference still picks window 9.
        XCTAssertEqual(SystemWindowEnvironment.matchFocused(axFrame: CGRect(x: 301, y: 299, width: 300, height: 200), axTitle: "Config", pid: 42, windows: ws), .window(9))
        // Assert: unknown title gives other.
        XCTAssertEqual(SystemWindowEnvironment.matchFocused(axFrame: f, axTitle: "Other", pid: 42, windows: ws), .other)
        // Assert: different process gives other.
        XCTAssertEqual(SystemWindowEnvironment.matchFocused(axFrame: f, axTitle: "RuneLite", pid: 43, windows: ws), .other)
    }
    // Scenario: describe a key action as text.
    // Expected: the typed text is not included.
    // Why it matters: typed text must not leak into logs.
    func testKeyDescriptionHidesText() {
        // Assert: the secret text is absent.
        XCTAssertFalse(PlannedAction.keyText("secret", mods: 0).description.contains("secret"))
    }
    // Scenario: convert the modifier bits to system flags.
    // Expected: 9 becomes shift and command.
    // Why it matters: the bit meanings must match the flags used.
    func testModFlags() { XCTAssertEqual(CGEventSink.flags(9), [.maskShift, .maskCommand]) }
}

// Tests for converting video data between formats.
final class AnnexBTests: XCTestCase {
    // Scenario: convert length-prefixed (AVCC) data to start-code (Annex B) form and split it.
    // Expected: correct output bytes, unit types 7 and 5, and bad lengths give nil.
    // Why it matters: the network carries start-code form.
    func testConvertAndSplit() {
        // Arrange: two units with length prefixes.
        let avcc = Data([0,0,0,2, 0x67,1, 0,0,0,3, 0x65,2,3])
        // Act: convert.
        let ab = AnnexB.fromAVCC(avcc)!
        // Assert: start codes replace the lengths.
        XCTAssertEqual(ab, Data([0,0,0,1,0x67,1, 0,0,0,1,0x65,2,3]))
        // Assert: the unit types are 7 and 5.
        XCTAssertEqual(AnnexB.nalUnits(ab).map { AnnexB.nalType($0)! }, [7, 5])
        // Assert: a length longer than the data gives nil.
        XCTAssertNil(AnnexB.fromAVCC(Data([0,0,0,9,1])))
    }
}

// Tests for the H.264 encoder using made-up frames.
final class EncoderTests: XCTestCase {
    // Scenario: encode 45 synthetic frames with a forced keyframe at frame 20.
    // Expected: 45 packets; first and 20th are keyframes; the first has SPS and PPS first; parameter sets only on the first; time stamps are in order.
    // Why it matters: checks encoder output end to end. It is skipped where the hardware encoder is not available.
    func testSyntheticFrames() throws {
        // Frame size.
        let w = 320, h = 240
        // Arrange: create an encoder, or skip the test.
        let enc: H264Encoder
        do { enc = try H264Encoder(width: w, height: h, bitrate: 1_000_000, fps: 30) }
        catch { throw XCTSkip("VideoToolbox unavailable headless: \(error)") }
        // Arrange: a lock and a list to collect packets.
        let lock = NSLock(); nonisolated(unsafe) var pkts: [EncodedPacket] = []
        // Hook: save each packet.
        enc.onPacket = { p in lock.lock(); pkts.append(p); lock.unlock() }
        // Act: feed 45 frames.
        for n in 0..<45 {
            // Make a blank pixel buffer.
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            // Fill it with a changing shade.
            let b = pb!; CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b)!, Int32(n * 5 % 256), CVPixelBufferGetBytesPerRow(b) * h)
            CVPixelBufferUnlockBaseAddress(b, [])
            // At frame 20, ask for a keyframe.
            if n == 20 { enc.forceKeyframe() }
            // Encode the frame.
            try enc.encode(b, pts: CMTime(value: CMTimeValue(n), timescale: 30))
        }
        // Finish so all packets are delivered.
        enc.finish()
        // Take a copy of the packets.
        lock.lock(); let p = pkts; lock.unlock()
        // Assert: one packet per frame.
        XCTAssertEqual(p.count, 45)
        // Assert: the first is a keyframe.
        XCTAssertTrue(p[0].isKey)
        // Assert: the forced one is a keyframe.
        XCTAssertTrue(p[20].isKey, "forced keyframe")
        // Read the unit types of the first packet.
        let types0 = AnnexB.nalUnits(p[0].annexB).compactMap(AnnexB.nalType)
        // Assert: parameter sets come first.
        XCTAssertEqual(Array(types0.prefix(2)), [7, 8])          // SPS PPS first (encoder may add SEI before IDR)
        // Assert: it includes a picture unit.
        XCTAssertTrue(types0.contains(5))
        // Assert: the first packet carries parameter sets.
        XCTAssertNotNil(p[0].paramSets)
        // Assert: the second does not.
        XCTAssertNil(p[1].paramSets)
        // Assert: time stamps never go backwards.
        XCTAssertEqual(p.map(\.ptsUs), p.map(\.ptsUs).sorted(), "pts monotonic => no reordering")
        // Informational: print the encoder type and total bytes.
        print("encoder hardware=\(String(describing: enc.usingHardware)) bytes=\(p.reduce(0) { $0 + $1.annexB.count })")
    }
}


// Tests for camera (middle-button) drag input.
final class CameraDragTests: XCTestCase {
    // Scenario: plan camera drag actions and run them through the gate.
    // Expected: start gives two actions ending in a middle-button press; move gives a middle-button drag; the gate blocks a move without a start, blocks clicks and other drags during the camera drag, allows fast camera moves, and release gives the middle button.
    // Why it matters: the camera uses the middle button and must never leave it stuck.
    func testCamDragPlansMiddleButtonAndIsGated() {
        // Arrange: a sample frame.
        let f = CGRect(x: 100, y: 100, width: 800, height: 500)
        // Assert: camStart plans two actions.
        XCTAssertEqual(InputPlanner.plan(.camStart(x: 0.5, y: 0.5), frame: f)?.count, 2)
        // Assert: the last one is a middle-button press.
        if case .otherDown? = InputPlanner.plan(.camStart(x: 0.5, y: 0.5), frame: f)?.last {} else { XCTFail("camStart must press the middle button") }
        // Assert: camMove starts with a middle-button drag.
        if case .otherDrag? = InputPlanner.plan(.camMove(x: 0.6, y: 0.5), frame: f)?.first {} else { XCTFail("camMove must drag the middle button") }
        // Arrange: a new gate.
        var g = HostInputGate()
        // Blocked.
        XCTAssertFalse(g.admit(.camMove(x: 0.5, y: 0.5), nowMs: 0))          // move without start
        // Allowed.
        XCTAssertTrue(g.admit(.camStart(x: 0.5, y: 0.5), nowMs: 100))
        // Blocked: no clicks mid-drag.
        XCTAssertFalse(g.admit(.tap(x: 0.5, y: 0.5), nowMs: 400))            // no clicks mid camera drag
        // Blocked: one held button at a time.
        XCTAssertFalse(g.admit(.dragStart(x: 0.5, y: 0.5), nowMs: 500))      // one held button at a time
        // Allowed.
        XCTAssertTrue(g.admit(.camMove(x: 0.5, y: 0.5), nowMs: 600))
        // Allowed: camera moves may be closer in time.
        XCTAssertTrue(g.admit(.camMove(x: 0.55, y: 0.5), nowMs: 625))        // 25 ms later: faster than other classes allow
        // Assert: release gives the middle button.
        XCTAssertEqual(g.releaseAll(), [.middle])
    }
}
