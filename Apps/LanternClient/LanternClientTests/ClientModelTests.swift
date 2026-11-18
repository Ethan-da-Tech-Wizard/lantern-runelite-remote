// Area protected: ClientModel, the view-model behind the phone app screens, plus the
// real transport's host check and forget behavior. It checks which screen shows, that bad
// codes and bad hosts never reach the network layer, state changes, that input is sent only
// while streaming and exactly once, that typed keys are never described in logs, and that
// forgetting a host also removes the stored peer.
import XCTest
import LanternCore
@testable import LanternClient

// A fake network transport: it records every call so tests can assert what the model asked for,
// and has switches to make pairing fail or the host look invalid.
@MainActor
final class MockTransport: SessionTransport {
    // Callback the model installs to hear about state changes; tests call it to simulate them.
    var onState: ((TransportState) -> Void)?
    var videoSink: VideoSink?
    // Whether this fake is already paired with a host.
    var isPaired = false
    // Every pair request that was made.
    var pairCalls: [(PairingInput, String)] = []
    // Counters for each kind of call.
    var connectCalls = 0, disconnectCalls = 0, forgetCalls = 0, keyframeCalls = 0
    // Every input event that was sent.
    var sent: [InputEvent] = []
    // If set, pairing throws this error.
    var pairError: Error?
    // Whether the host address counts as valid.
    var hostValid = true
    // Record the pair request, fail if told to, otherwise become paired.
    func pair(_ input: PairingInput, host: String) async throws {
        pairCalls.append((input, host)); if let e = pairError { throw e }; isPaired = true
    }
    // Connect only counts the call.
    func connect(host: String) async throws { connectCalls += 1 }
    // Send records the event.
    func send(_ event: InputEvent) { sent.append(event) }
    // Bitrate hints are ignored.
    func setBitrateHint(kbps: Int) {}
    // Count disconnects.
    func disconnect() { disconnectCalls += 1 }
    // Forgetting counts the call and clears the paired flag.
    func forgetHost() { forgetCalls += 1; isPaired = false }
    // Count keyframe requests.
    func requestKeyframe() { keyframeCalls += 1 }
    // Host validity is whatever the test set.
    func validate(host: String) -> Bool { hostValid }
}

@MainActor
// Tests for the client view-model.
final class ClientModelTests: XCTestCase {
    // A simple error type used to simulate a failed pairing.
    struct Boom: Error {}
    // Helper: builds a model and its fake transport, optionally already paired, with a sample host address.
    func make(paired: Bool = false) -> (ClientModel, MockTransport) {
        let t = MockTransport(); t.isPaired = paired
        let m = ClientModel(transport: t); m.hostAddress = "192.168.1.20:7777"
        return (m, t)
    }

    // Scenario: build a model unpaired and paired.
    // Expected: unpaired starts on the pair screen; paired starts on the connected screen.
    // Why it matters: users should not be asked to pair again after pairing.
    func testStartsOnPairOrConnectedByPairedFlag() {
        // Unpaired shows the pair screen.
        XCTAssertEqual(make().0.screen, .pair)
        // Paired shows the connected screen.
        XCTAssertEqual(make(paired: true).0.screen, .connected)
    }
    // Scenario: pair with codes that are too short or malformed.
    // Expected: the transport is never called, a banner explains the problem without echoing the
    // text typed, and the screen stays on pair.
    // Why it matters: invalid input should fail locally and secrets must not show in messages.
    func testInvalidCodeNeverReachesTransport() async {
        // Arrange: an unpaired model.
        let (m, t) = make()
        // Act: a short code; assert no pair call and a banner is shown.
        await m.pair("short"); XCTAssertTrue(t.pairCalls.isEmpty); XCTAssertNotNil(m.banner)
        // Act: a malformed code; assert no pair call.
        await m.pair("LNT1garbage"); XCTAssertTrue(t.pairCalls.isEmpty)
        // Assert: the banner does not repeat the typed text.
        XCTAssertFalse(m.banner?.contains("short") ?? false)
        // Assert: still on the pair screen.
        XCTAssertEqual(m.screen, .pair)
    }
    // Scenario: the host address is invalid but the code is fine.
    // Expected: no pair call, and a banner is shown.
    // Why it matters: do not try the network with a bad address.
    func testBadHostBlocksPairing() async {
        // Arrange: make the fake report the host as invalid.
        let (m, t) = make(); t.hostValid = false
        // Act: pair with a valid-looking code; assert no call and a banner.
        await m.pair("ABCDE-FGHJK"); XCTAssertTrue(t.pairCalls.isEmpty); XCTAssertNotNil(m.banner)
    }
    // Scenario: pair with a good code that has extra spaces and a newline.
    // Expected: one pair call, then one connect call, the connected screen, and no banner.
    // Why it matters: this is the normal success path and pasted codes often carry whitespace.
    func testValidPairThenConnect() async {
        // Arrange: a model and fake.
        let (m, t) = make()
        // Act: pair with a padded code.
        await m.pair("  ABCDE-FGHJK \n")
        // Assert: one pair and one connect call.
        XCTAssertEqual(t.pairCalls.count, 1); XCTAssertEqual(t.connectCalls, 1)
        // Assert: the connected screen shows and there is no banner.
        XCTAssertEqual(m.screen, .connected); XCTAssertNil(m.banner)
    }
    // Scenario: the transport throws during pairing.
    // Expected: stay on the pair screen, never connect, and keep the code out of the banner.
    // Why it matters: failures must be recoverable and must not leak the pairing code.
    func testPairFailureStaysOnPairAndBannerOmitsCode() async {
        // Arrange: make pairing fail.
        let (m, t) = make(); t.pairError = Boom()
        // Act: pair.
        await m.pair("ABCDE-FGHJK")
        // Assert: still on pair and no connect call.
        XCTAssertEqual(m.screen, .pair); XCTAssertEqual(t.connectCalls, 0)
        // Assert: the banner does not contain part of the code.
        XCTAssertFalse(m.banner?.contains("ABCDE") ?? true)
    }
    // Scenario: the transport reports state changes.
    // Expected: the model mirrors each state, and a failure also sets the banner to its message.
    // Why it matters: the UI relies on the model state to show progress and errors.
    func testStateTransitionsAndBannerOnFailure() {
        // Arrange: a model and fake.
        let (m, t) = make()
        // Connecting is mirrored.
        t.onState?(.connecting); XCTAssertEqual(m.state, .connecting)
        // Streaming is mirrored.
        t.onState?(.streaming); XCTAssertEqual(m.state, .streaming)
        // A failure is mirrored and shown in the banner.
        t.onState?(.failed("lost")); XCTAssertEqual(m.state, .failed("lost")); XCTAssertEqual(m.banner, "lost")
        // Idle is mirrored.
        t.onState?(.idle); XCTAssertEqual(m.state, .idle)
    }
    // Scenario: send input before, during and after streaming.
    // Expected: dropped while idle, sent once while streaming (and counted), dropped after a failure.
    // Why it matters: input must not queue up or double-send, and must never go out when not streaming.
    func testSendOnlyWhileStreamingAndExactlyOnce() {
        // Arrange: a model and fake.
        let (m, t) = make()
        // Idle: the tap is dropped.
        m.send(.tap(x: 0.1, y: 0.2)); XCTAssertTrue(t.sent.isEmpty)          // idle: dropped
        // Switch to streaming.
        t.onState?(.streaming)
        // Act: send a tap.
        m.send(.tap(x: 0.1, y: 0.2))
        // Assert: exactly that event was sent and the counter is 1.
        XCTAssertEqual(t.sent, [.tap(x: 0.1, y: 0.2)]); XCTAssertEqual(m.eventCount, 1)
        // After a failure a zoom is not sent, so the total stays 1.
        t.onState?(.failed("x")); m.send(.zoom(delta: 0.1)); XCTAssertEqual(t.sent.count, 1)
    }
    // Scenario: describe a key event for display or logging.
    // Expected: it says only "key", not the typed text.
    // Why it matters: typed text may be secret.
    func testKeyEventsNotDescribed() {
        // Assert: the description hides the text.
        XCTAssertEqual(ClientModel.describe(.key(text: "secret", mods: 0)), "key")
    }
    // Scenario: disconnect, then forget the host.
    // Expected: disconnect calls the transport and returns to pair; forget clears the saved address too.
    // Why it matters: users must be able to fully reset the connection.
    func testDisconnectAndForgetHost() {
        // Arrange: a model that starts paired.
        let (m, t) = make(paired: true)
        // Act: disconnect; assert one transport call and the pair screen.
        m.disconnect(); XCTAssertEqual(t.disconnectCalls, 1); XCTAssertEqual(m.screen, .pair)
        // Act: forget the host.
        m.forgetHost()
        // Assert: forget was called, the address is empty and the screen is pair.
        XCTAssertEqual(t.forgetCalls, 1); XCTAssertEqual(m.hostAddress, ""); XCTAssertEqual(m.screen, .pair)
    }
    // Scenario: the real transport forgets a host.
    // Expected: it is no longer paired and the stored peer is deleted.
    // Why it matters: forgetting must remove the trust record, not just hide it.
    func testNetTransportForgetHostRemovesStoredPeer() throws {
        // Arrange: an in-memory store holding one peer.
        let store = InMemoryKeyStore()
        // Add the stored peer.
        try store.addPeer(PairedPeerRecord(name: "Mac", publicKey: Data(repeating: 7, count: 32), pairedAt: Date()))
        // Create the real transport on that store.
        let t = NetTransport(keyStore: store)
        // Assert: it sees itself as paired.
        XCTAssertTrue(t.isPaired)
        // Act: forget the host.
        t.forgetHost()
        // Assert: not paired and no peers remain.
        XCTAssertFalse(t.isPaired); XCTAssertTrue(try store.peers().isEmpty)
    }
    // Scenario: validate host strings with the real transport.
    // Expected: a host with a valid port passes; empty, missing port, missing host, port 0, too-large port
    // and a non-numeric port are all refused.
    // Why it matters: bad addresses should be caught before connecting.
    func testNetTransportValidatesHost() {
        // Arrange: a real transport with an empty store.
        let t = NetTransport(keyStore: InMemoryKeyStore())
        // A good address passes.
        XCTAssertTrue(t.validate(host: "192.168.1.20:7777"))
        // Each bad address must fail (the address is the failure message).
        for bad in ["", "192.168.1.20", ":7777", "host:0", "host:99999", "host:abc"] { XCTAssertFalse(t.validate(host: bad), bad) }
    }
    // Scenario: ask for a keyframe when there is no connection.
    // Expected: nothing happens and nothing crashes.
    // Why it matters: the UI may ask at any time.
    func testRequestKeyframeWithoutConnectionIsSafe() {
        // Act: request a keyframe on an unconnected transport; the test passes if it returns safely.
        NetTransport(keyStore: InMemoryKeyStore()).requestKeyframe()
    }
}
