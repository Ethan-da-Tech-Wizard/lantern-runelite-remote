// Area protected: HostSession end to end over a real loopback connection. It checks that
// no capture runs before a client connects, that video frames flow to the client, that one
// tap becomes exactly one click on the host, and that the kill switch shuts everything down.
// No screen-recording permission is needed because the frame source is synthetic.
import XCTest
import CoreGraphics
@testable import LanternHostKit
import LanternCore

// Test helper: a fake frame source that produces fake "video" frames on a timer
// and counts how often it was started, stopped, or asked for a keyframe.
private final class SyntheticSource: FrameSource, @unchecked Sendable {
    // A lock protects the fields below because the timer runs on another thread.
    private let l = NSLock()
    private var _f: (@Sendable (Data, Bool, UInt64) -> Void)?
    private var _e: (@Sendable (String) -> Void)?
    private var timer: DispatchSourceTimer?
    private var n: UInt64 = 0
    // Counters the tests can read.
    private(set) var starts = 0, stops = 0, keyReqs = 0
    // Callbacks the session installs; reads and writes go through the lock.
    var onFrame: (@Sendable (Data, Bool, UInt64) -> Void)? { get { l.withLock { _f } } set { l.withLock { _f = newValue } } }
    var onEnded: (@Sendable (String) -> Void)? { get { l.withLock { _e } } set { l.withLock { _e = newValue } } }
    // Start: count the start, then make a timer that fires every 30 ms.
    func start() async throws {
        l.withLock { starts += 1 }
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now(), repeating: .milliseconds(30))
        // On each tick: bump the frame number and send a 3000-byte frame; only frame 1 is marked a keyframe.
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let i = self.l.withLock { self.n += 1; return self.n }
            self.onFrame?(Data(repeating: UInt8(i & 0xff), count: 3000), i == 1, i * 33_000)
        }
        l.withLock { timer = t }
        t.resume()
    }
    // Stop: count the stop and cancel the timer.
    func stop() async { l.withLock { stops += 1; timer?.cancel(); timer = nil } }
    // A keyframe request is just counted.
    func requestKeyframe() { l.withLock { keyReqs += 1 } }
    // Bitrate changes are ignored by this fake.
    func setBitrate(bps: Int) {}
    // Running means the timer exists.
    var running: Bool { l.withLock { timer != nil } }
}

// Test helper: a fake window environment that always says the target window is in front
// and on top, with the cursor in the middle of it.
private struct SessEnv: WindowEnvironment {
    let frame: CGRect, pid: Int32, id: UInt32
    func frame(ofWindow id: UInt32) -> CGRect? { id == self.id ? frame : nil }
    func frontmostPID() -> Int32? { pid }
    func topWindow(at point: CGPoint) -> (id: UInt32, pid: Int32)? { (id, pid) }
    func cursorLocation() -> CGPoint? { CGPoint(x: frame.midX, y: frame.midY) }
    func focusedWindow() -> FocusedWindow { .window(id) }
}

// Test helper: a tiny thread-safe list that collects values from other threads.
private final class Box<T: Sendable>: @unchecked Sendable {
    private let l = NSLock(); private var v: [T] = []
    func add(_ x: T) { l.withLock { v.append(x) } }
    var all: [T] { l.withLock { v } }
}

// Test helper: polls a condition every 20 ms until it is true or the time limit (5 s by default)
// passes. It lets tests wait for async results without a fixed long sleep.
private func eventually(_ t: TimeInterval = 5, _ c: @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(t)
    while Date() < end { if c() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
    return c()
}

// Tests for the host session lifecycle.
final class SessionTests: XCTestCase {
    // Scenario: pair a client over loopback, stream video, send one tap, then use the kill switch.
    // Expected: capture is off until a client connects, at least 3 frames including a keyframe
    // arrive, the tap is applied exactly once (one mouse down, one mouse up, none refused), and
    // shutdown stops capture and the server and engages the kill switch.
    // Why it matters: this is the main promise of the host: on-demand capture, no duplicate input,
    // and a reliable off switch.
    func testLoopbackVideoAndSingleTapNoScreenPermission() async throws {
        // Arrange: a fake target window, a recording input sink and an injector bound to the fake environment.
        let win = WindowInfo(id: 42, ownerName: "Fake", ownerPID: 777, title: "t", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        let sink = RecordingSink()
        let injector = InputInjector(target: win, environment: SessEnv(frame: win.frame, pid: 777, id: 42), sink: sink)
        // Arrange: the synthetic frame source.
        let src = SyntheticSource()
        // Arrange: a network config with fast timing, then a host server and session on a free loopback port.
        var cfg = NetConfig(); cfg.deviceName = "Host"; cfg.tick = 0.02; cfg.handshakeTimeout = 1
        let server = HostServer(keyStore: InMemoryKeyStore(), config: cfg)
        let session = HostSession(server: server, source: src, injector: injector)
        // Start listening on port 0 (the system picks a free port) and open a pairing window.
        let port = try await server.start(bindAddress: "127.0.0.1", port: 0)
        let code = try server.beginPairing()

        // Arrange the client: same settings with a different device name, its own in-memory key store.
        var ccfg = cfg; ccfg.deviceName = "Phone"
        let client = ClientConnection(host: "127.0.0.1", port: port, keyStore: InMemoryKeyStore(), config: ccfg)
        // Collect the keyframe flags of received frames.
        let frames = Box<Bool>()
        // Each received frame must be 3000 bytes; record whether it was a keyframe.
        client.onVideoFrame = { d, k in XCTAssertEqual(d.count, 3000); frames.add(k) }
        // Assert: before pairing, capture is not running.
        XCTAssertFalse(src.running, "capture must not run before a client is connected")
        // Act: pair using the displayed code.
        _ = try await client.pair(code: code.displayString)

        // Wait until at least 3 frames arrived.
        let gotVideo = await eventually { frames.all.count >= 3 }
        // Assert: frames arrived.
        XCTAssertTrue(gotVideo, "video frames did not arrive")
        // Assert: capture is now running.
        XCTAssertTrue(src.running)
        // Assert: at least one frame was a keyframe.
        XCTAssertTrue(frames.all.contains(true), "no keyframe seen")

        // Act: send a single tap in the middle of the window.
        try client.send(input: .tap(x: 0.5, y: 0.5))
        // Wait until the sink has recorded the tap's actions.
        let gotTap = await eventually { sink.actions.count >= 3 }
        // Assert: the tap produced actions.
        XCTAssertTrue(gotTap)
        try await Task.sleep(nanoseconds: 600_000_000)       // allow any duplicate/retransmit to show up
        // Assert: the session counted exactly one applied input.
        XCTAssertEqual(session.snapshot.inputApplied, 1, "tap must be applied exactly once")
        // Assert: no input was refused.
        XCTAssertEqual(session.snapshot.inputRefused, 0)
        // Assert: exactly one mouse-down was recorded.
        XCTAssertEqual(sink.actions.filter { if case .leftDown = $0 { return true } else { return false } }.count, 1)
        // Assert: exactly one mouse-up was recorded.
        XCTAssertEqual(sink.actions.filter { if case .leftUp = $0 { return true } else { return false } }.count, 1)

        // Kill switch: capture stops, server stops.
        // Act: run the shutdown (kill switch).
        await session.shutdown()
        // Assert: capture stopped.
        XCTAssertFalse(src.running)
        // Assert: the server is no longer listening.
        XCTAssertFalse(server.isListening)
        // Assert: the kill switch flag is set.
        XCTAssertTrue(server.killSwitchEngaged)
        // Cleanup: close the client side.
        client.disconnect()
    }
}
