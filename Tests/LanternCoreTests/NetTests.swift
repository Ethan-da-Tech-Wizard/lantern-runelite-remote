// Program: Lantern - NetTests.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Tests the real network layer: pairing, sessions and reconnecting.
//
// Area protected: the real network layer in LanternCore (HostServer, ClientConnection and
// SecureSession). Tests run over loopback UDP sockets with fast timeouts. They cover: the host
// being off by default and refusing wildcard binds, full pairing and data flow, QR pairing and
// fingerprint checks, lockout after wrong codes, silence for closed pairing and unknown or
// revoked peers, reconnecting, rate limits, replay and tamper handling on the real socket,
// reliable control messages under loss, video fragments with loss, keyframe request limits,
// anti-amplification, the stop and kill switch, and the in-memory secure session.
// The common theme: the host answers only authenticated, well-formed, in-budget peers.
import XCTest
import CryptoKit
import Network
import Darwin
@testable import LanternCore

// Test helper: a thread-safe list that collects values reported from other threads.
private final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { all.count }
}

// Test helper: a thread-safe true/false flag.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool = false) { self.v = v }
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    // take() returns the flag value and clears it, so it reports true only once after being set.
    /// true exactly once after being set
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let r = v; v = false; return r }
}

// Test helper: a thread-safe counter that hands out 1, 2, 3 and so on.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

// Helper: a fast network config (short handshake timeout, quick ticks and retransmit) so tests finish quickly.
private func fastConfig(name: String = "Test") -> NetConfig {
    var c = NetConfig()
    c.deviceName = name
    c.handshakeTimeout = 1.0
    c.tick = 0.02
    c.reliableRetransmit = 0.08
    return c
}

// Helper: polls a condition every 20 ms until it is true or the timeout (4 s by default) passes.
private func eventually(_ timeout: TimeInterval = 4, _ cond: @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
    return cond()
}

// Helper: checks whether nobody holds a loopback UDP port, by trying to bind it.
/// Returns true if a plain UDP bind (no reuse flags) to 127.0.0.1:port succeeds, i.e. nobody holds it.
private func portIsFree(_ port: UInt16) -> Bool {
    // Open a UDP socket; if that fails, report not free.
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return false }
    // Always close the probe socket.
    defer { close(fd) }
    // Describe the loopback address and port.
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    // Try the bind; success means the port is free.
    return withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
}

// Tests for the real networking classes over loopback.
final class NetTests: XCTestCase {
    // The loopback address used by all tests.
    private let lo = "127.0.0.1"

    // Helper: starts a host on a free port and registers cleanup so no listener stays open after the test, even on failure.
    private func makeServer(_ cfg: NetConfig? = nil) async throws -> (HostServer, InMemoryKeyStore, UInt16) {
        // Fresh in-memory key store.
        let ks = InMemoryKeyStore()
        // Create the host server.
        let s = HostServer(keyStore: ks, config: cfg ?? fastConfig(name: "Host"))
        // Start it on port 0 so the system picks a free port.
        let port = try await s.start(bindAddress: lo, port: 0)
        // Assert: a real port was assigned.
        XCTAssertNotEqual(port, 0)
        addTeardownBlock {           // no test may leave a listener open, even on failure/throw
            await s.stop()
            let freed = await eventually { portIsFree(port) }
            XCTAssertTrue(freed, "listener leaked on port \(port)")
        }
        return (s, ks, port)
    }
    // Helper: makes a client (and its key store) pointed at the given port, disconnecting it at the end of the test.
    private func makeClient(_ port: UInt16, _ ks: InMemoryKeyStore = InMemoryKeyStore(), cfg: NetConfig? = nil) -> (ClientConnection, InMemoryKeyStore) {
        let c = ClientConnection(host: lo, port: port, keyStore: ks, config: cfg ?? fastConfig(name: "Phone"))
        addTeardownBlock { c.disconnect() }
        return (c, ks)
    }
    // Helper: sets up a host and a client that have already paired.
    /// Pairs a fresh client; returns everything needed for follow-up tests.
    private func pairedPair() async throws -> (HostServer, InMemoryKeyStore, ClientConnection, InMemoryKeyStore, UInt16) {
        // Start the host.
        let (s, hks, port) = try await makeServer()
        // Open pairing and get the code.
        let code = try s.beginPairing()
        // Make the client.
        let (c, cks) = makeClient(port)
        // Pair using the displayed code.
        _ = try await c.pair(code: code.displayString)
        // Return everything follow-up tests need.
        return (s, hks, c, cks, port)
    }

    // Group: the host is off by default and refuses unsafe bind addresses.
    // MARK: off by default, bind rules

    // Scenario: a new host server, then attempts to start on wildcard or invalid addresses.
    // Expected: not listening, state stopped, no pairing allowed, and each bad address is refused.
    // Why it matters: nothing should be reachable until the user turns it on, and never on all interfaces.
    func testOffByDefaultAndWildcardRefused() async throws {
        // Arrange: a host that was never started.
        let s = HostServer(keyStore: InMemoryKeyStore())
        // Assert: not listening.
        XCTAssertFalse(s.isListening)
        // Assert: stopped state.
        XCTAssertEqual(s.state, .stopped)
        // Assert: pairing cannot begin while off.
        XCTAssertThrowsError(try s.beginPairing())
        // Act: try several bad bind addresses.
        for bad in ["0.0.0.0", "::", "localhost", "", "example.com"] {
            // Fail the test if one was accepted.
            do { _ = try await s.start(bindAddress: bad, port: 0); XCTFail("accepted \(bad)") }
            catch let e as LanternNetError { XCTAssertTrue(e == .wildcardBindRefused || e == .invalidBindAddress, "\(bad): \(e)") }
        }
        // Assert: still not listening.
        XCTAssertFalse(s.isListening)
    }

    // Group: pairing.
    // MARK: pairing

    // Scenario: a full pairing with a lowercase code, then data in both directions.
    // Expected: names and keys are stored on each side, the check numbers match, the code is single-use, and input, video and control messages arrive intact.
    // Why it matters: this is the main end-to-end success path.
    func testFullPairingOverLoopbackAndDataFlow() async throws {
        // Arrange: a running host.
        let (s, hks, port) = try await makeServer()
        // Collectors for what the host reports.
        let hostInfo = Collector<PairedInfo>(), inputs = Collector<InputEvent>(), ctrl = Collector<ControlMessage>()
        // Hook: record the pairing info.
        s.onPaired = { hostInfo.add($0) }
        // Hook: record input events.
        s.onInput = { inputs.add($0) }
        // Hook: record control messages.
        s.onControl = { ctrl.add($0) }
        // Open pairing and get the code.
        let code = try s.beginPairing()
        // Assert: the host shows pairing open.
        guard case .pairingOpen = s.state else { return XCTFail("state \(s.state)") }
        // Arrange: a client.
        let (c, cks) = makeClient(port)
        // Collector for video frames the client gets.
        let frames = Collector<VideoFrame>()
        // Hook: record each received frame.
        c.onVideoFrame = { d, k in frames.add(VideoFrame(data: d, isKeyframe: k, ptsUs: 0, frameID: 0)) }
        // Act: pair using a lowercase code and a device name.
        let info = try await c.pair(code: code.displayString.lowercased(), deviceName: "Ethan's phone")
        // Assert: the client learned the host name.
        XCTAssertEqual(info.name, "Host")
        // Assert: the client saved the host (one peer).
        XCTAssertEqual(try cks.peers().count, 1)                                   // client pinned the host
        // Assert: the saved key is the host's real public key.
        XCTAssertEqual(try cks.peers()[0].publicKey, try s.publicKey())
        // Assert: the host saved the client.
        XCTAssertEqual(try hks.peers().count, 1)                                   // host stored the client
        // Assert: its saved name matches what the client sent.
        XCTAssertEqual(try hks.peers()[0].name, "Ethan's phone")
        // Assert: its saved key is the client's key.
        XCTAssertEqual(try hks.peers()[0].publicKey, try cks.loadOrCreateDeviceKey().publicKey.rawRepresentation)
        // Wait for the host's pairing callback.
        let eh = await eventually { hostInfo.count == 1 }
        // Assert: it happened.
        XCTAssertTrue(eh)
        XCTAssertEqual(hostInfo.all[0].sas, info.sas)                               // SAS matches both ends
        // Assert: the host's check number is six digits.
        XCTAssertEqual(hostInfo.all[0].sas.count, 6)
        XCTAssertEqual(s.pairingState, .consumed)                                   // single use
        // Assert: the host has an active session.
        guard case .sessionActive = s.state else { return XCTFail("state \(s.state)") }

        // Part 2: data flows both ways.
        // data flows both ways
        // Act: client sends a tap.
        try c.send(input: .tap(x: 0.25, y: 0.75))
        // Wait for the host to get it.
        let ei = await eventually { inputs.count == 1 }
        // Assert: it arrived.
        XCTAssertTrue(ei)
        // Assert: the values are right (or fail).
        if case .tap(let x, let y)? = inputs.all.first { XCTAssertEqual(x, 0.25, accuracy: 0.001); XCTAssertEqual(y, 0.75, accuracy: 0.001) } else { XCTFail() }
        // Act: host sends a video frame.
        try s.sendVideoFrame(Data(repeating: 7, count: 100), isKeyframe: true, ptsUs: 1)
        // Wait for the client to get it.
        let ev = await eventually { frames.count == 1 }
        // Assert: it arrived.
        XCTAssertTrue(ev)
        // Assert: the data is identical.
        XCTAssertEqual(frames.all[0].data, Data(repeating: 7, count: 100))
        // Act: host sends window info.
        try s.send(control: .windowInfo(width: 800, height: 600))
        // Act: client sends a keyframe request.
        try c.send(control: .requestIDR)
        // Wait for the host to get it.
        let ec = await eventually { ctrl.count == 1 }
        // Assert: it arrived.
        XCTAssertTrue(ec)
        // Assert: it is the keyframe request.
        XCTAssertEqual(ctrl.all.first, .requestIDR)
        // Cleanup: disconnect and stop.
        c.disconnect()
        await s.stop()
    }

    // Scenario: make a short tag for a peer key.
    // Expected: six characters, and it does not show raw key bytes.
    // Why it matters: logs may show the tag, never the key.
    func testPeerTagIsShortHashOnly() throws {
        // Act: tag a key made of repeated 9 bytes.
        let t = peerTag(Data(repeating: 9, count: 32))
        // Assert: six characters.
        XCTAssertEqual(t.count, 6)
        // Assert: the raw bytes are not visible.
        XCTAssertFalse(t.contains("0909"))
    }

    // Scenario: pair with a QR payload, then with a forged one whose host fingerprint is wrong.
    // Expected: the good one works; the forged one fails with hostKeyMismatch and the client stores nothing.
    // Why it matters: protects against pairing with a fake host.
    func testQRPairingChecksHostFingerprint() async throws {
        // Arrange: a host.
        let (s, _, port) = try await makeServer()
        // Make a valid QR payload.
        let good = try s.beginPairingQR(addressHint: "127.0.0.1:\(port)")
        // Make a client.
        let (c, _) = makeClient(port)
        // Act: pair with the QR payload.
        _ = try await c.pair(qr: good)
        // Disconnect the first client.
        c.disconnect()
        // Wait until the host's session has ended.
        let ended = await eventually { if case .sessionActive = s.state { return false }; return true }
        // Assert: the session ended.
        XCTAssertTrue(ended)
        // a QR whose fingerprint belongs to a different host key must abort
        // Make another valid secret, then forge a payload with a wrong host fingerprint.
        let good2 = try s.beginPairingQR(addressHint: "x")
        // Forged payload.
        let forged = try PairingQRPayload(secret: good2.secret, hostFingerprint: Data(repeating: 1, count: 32), addressHint: "x")
        // Make a second client.
        let (c2, ks2) = makeClient(port)
        do { _ = try await c2.pair(qr: forged); XCTFail("pinned wrong host") }
        catch { XCTAssertEqual(error as? LanternNetError, .hostKeyMismatch) }
        // Assert: the client saved nothing.
        XCTAssertEqual(try ks2.peers().count, 0)
        // Cleanup: stop the host.
        await s.stop()
    }

    // Scenario: five wrong codes in a row, then the correct code.
    // Expected: each wrong attempt times out and counts as a failure, the host locks after five, and then even the right code is ignored.
    // Why it matters: limits guessing of the code.
    func testWrongCodeFiveTimesLocksAndCorrectCodeThenFails() async throws {
        // Arrange: a host whose per-source limit is raised, because all tests use one loopback source.
        var scfg2 = fastConfig(name: "Host"); scfg2.maxPairFailuresPerSource = 5   // single loopback source: lift its budget to reach the lock
        // Start it.
        let (s, hks, port) = try await makeServer(scfg2)
        // Open pairing.
        let code = try s.beginPairing()
        // Pick a wrong code.
        var wrong = PairingCode.generate()
        // Make sure it is different from the real one.
        while wrong.text == code.text { wrong = PairingCode.generate() }
        // A client config with a shorter timeout.
        var cfg = fastConfig(); cfg.handshakeTimeout = 0.6
        // Act: five wrong attempts.
        for i in 1...5 {
            // Make a client.
            let (c, cks) = makeClient(port, cfg: cfg)
            // Act and assert: pairing must fail.
            do { _ = try await c.pair(code: wrong.displayString); XCTFail("paired with wrong code") }
            catch { XCTAssertEqual(error as? LanternNetError, .timedOut) }
            // Assert: the client stored nothing.
            XCTAssertEqual(try cks.peers().count, 0)
            // Wait until the host counted this failure.
            let counted = await eventually { s.stats.failedPairings == i }
            // Assert: the count matched.
            XCTAssertTrue(counted, "attempt \(i): \(s.stats.failedPairings)")
        }
        // Assert: the host is locked.
        XCTAssertEqual(s.pairingState, .locked)
        // Assert: the host is still listening.
        XCTAssertEqual(s.state, .listening(port: port))
        // even the right code is now dead
        // Act: try the correct code on a new client.
        let (c, _) = makeClient(port, cfg: cfg)
        // Fail if it is accepted.
        do { _ = try await c.pair(code: code.displayString); XCTFail("locked code accepted") }
        catch { XCTAssertEqual(error as? LanternNetError, .timedOut) }
        // Assert: nothing was stored.
        XCTAssertEqual(try hks.peers().count, 0)
        // Cleanup.
        await s.stop()
    }

    // Scenario: pair while the host has pairing closed.
    // Expected: the client times out with a precise handshake-failed state, and the host silently drops the attempt.
    // Why it matters: a closed host should look like nothing is there.
    func testPairingClosedMeansSilence() async throws {
        // Arrange: host with pairing never opened.
        let (s, hks, port) = try await makeServer()
        // Short timeout for the client.
        var cfg = fastConfig(); cfg.handshakeTimeout = 0.5
        // Make a client.
        let (c, _) = makeClient(port, cfg: cfg)
        // Act and assert: pairing fails.
        do { _ = try await c.pair(code: PairingCode.generate().text); XCTFail() }
        catch { XCTAssertEqual(error as? LanternNetError, .timedOut) }
        // Assert: the client's state is closed because of the handshake.
        XCTAssertEqual(c.state, .closed(.handshakeFailed))          // not the imprecise idleTimeout
        // Assert: the host counted silent drops.
        XCTAssertGreaterThan(s.stats.silentHandshakeDrops, 0)
        // Assert: nothing stored.
        XCTAssertEqual(try hks.peers().count, 0)
        // Cleanup.
        await s.stop()
    }

    // Group: reconnecting with a known peer.
    // MARK: IK sessions

    // Scenario: pair, leave a mouse button held, disconnect, then reconnect.
    // Expected: the host releases the held button on disconnect, and the paired client reconnects and can send input.
    // Why it matters: a dropped link must not leave the mouse stuck, and reconnecting should not need the code.
    func testReconnectViaIK() async throws {
        // Arrange: a paired host and client.
        let (s, _, c1, cks, port) = try await pairedPair()
        // Collect host input events.
        let inputs = Collector<InputEvent>()
        // Hook.
        s.onInput = { inputs.add($0) }
        // Collect held-button releases.
        let released = Collector<[HeldButton]>()
        // Hook.
        s.onHeldButtonsReleased = { released.add($0) }
        try c1.send(input: .dragStart(x: 0.5, y: 0.5))          // leave a button held
        // Wait for the drag start to arrive.
        let held = await eventually { inputs.count == 1 }
        // Assert: it arrived.
        XCTAssertTrue(held)
        // Act: disconnect.
        c1.disconnect()
        // Wait until the session is gone.
        let gone = await eventually { if case .sessionActive = s.state { return false }; return true }
        // Assert: it ended.
        XCTAssertTrue(gone)
        // Wait for the release report.
        let rel = await eventually { released.count == 1 }
        // Assert: it happened.
        XCTAssertTrue(rel)
        XCTAssertEqual(released.all.first, [.left])              // host releases held mouse button on disconnect
// Arrange: a new client with the saved keys.

        // Make it.
        let c2 = ClientConnection(host: lo, port: port, keyStore: cks, config: fastConfig(name: "Phone"))
        // Act: connect without a code.
        try await c2.connect()
        // Assert: the connection is established.
        guard case .established = c2.state else { return XCTFail("\(c2.state)") }
        // Send a tap.
        try c2.send(input: .tap(x: 0.1, y: 0.1))
        // Wait for the second input.
        let ok = await eventually { inputs.count == 2 }
        // Assert: it arrived.
        XCTAssertTrue(ok)
        // Cleanup.
        c2.disconnect()
        await s.stop()
    }

    // Scenario: a peer is paired, then removed from the host's list, then tries to connect.
    // Expected: it times out and gets no answer.
    // Why it matters: revocation must take effect immediately and silently.
    func testRevokedPeerGetsSilence() async throws {
        // Arrange: a paired pair.
        let (s, hks, c1, cks, port) = try await pairedPair()
        // Disconnect.
        c1.disconnect()
        // Revoke the client's key on the host.
        try hks.revoke(publicKey: try cks.loadOrCreateDeviceKey().publicKey.rawRepresentation)
        // Short timeout.
        var cfg = fastConfig(); cfg.handshakeTimeout = 0.6
        // Act: try to reconnect.
        let c2 = ClientConnection(host: lo, port: port, keyStore: cks, config: cfg)
        do { try await c2.connect(); XCTFail("revoked peer connected") }
        catch { XCTAssertEqual(error as? LanternNetError, .timedOut) }
        // Cleanup.
        await s.stop()
    }

    func testUnknownPeerRejectedSilently() async throws {
        // Scenario: a stranger who knows the host's public key tries to connect, and a client that never paired tries.
        // Expected: the stranger gets no reply at all (timeout) and the host stays listening; the never-paired client fails with notPaired locally.
        // Why it matters: knowing the public key must not be enough.
        let (s, _, port) = try await makeServer()
        // Arrange: a host.
        // attacker knows the host public key (it is not secret) but is not in the allowlist
        // Stranger's key store that holds only the host's public key.
        let aks = InMemoryKeyStore()
        // Add it.
        try aks.addPeer(PairedPeerRecord(name: "h", publicKey: try s.publicKey(), pairedAt: Date()))
        // Short timeout.
        var cfg = fastConfig(); cfg.handshakeTimeout = 0.6
        // Make the stranger client.
        let a = ClientConnection(host: lo, port: port, keyStore: aks, config: cfg)
        do { try await a.connect(); XCTFail("unknown peer got a session") }
        catch { XCTAssertEqual(error as? LanternNetError, .timedOut) }   // no reply of any kind
        // Assert: the host counted silent drops.
        XCTAssertGreaterThan(s.stats.silentHandshakeDrops, 0)
        // Assert: the host is still listening.
        XCTAssertEqual(s.state, .listening(port: port))
        // never paired at all
        // Arrange: a client with no saved host at all.
        let b = ClientConnection(host: lo, port: port, keyStore: InMemoryKeyStore(), config: cfg)
        do { try await b.connect(); XCTFail() } catch { XCTAssertEqual(error as? LanternNetError, .notPaired) }
        // Cleanup.
        await s.stop()
    }

    // Scenario: a host that allows only 3 handshakes per window; a client keeps retrying.
    // Expected: the host counts rate-limited attempts.
    // Why it matters: stops one source from flooding the host with handshakes.
    func testHandshakeRateLimitPerSource() async throws {
        // Arrange: config with a low limit.
        var scfg = fastConfig(name: "Host"); scfg.maxHandshakesPerWindow = 3
        // Start the host.
        let (s, _, port) = try await makeServer(scfg)
        // Key store with the host's public key.
        let aks = InMemoryKeyStore()
        // Add it.
        try aks.addPeer(PairedPeerRecord(name: "h", publicKey: try s.publicKey(), pairedAt: Date()))
        // Short timeout.
        var cfg = fastConfig(); cfg.handshakeTimeout = 0.7
        // First client.
        let a = ClientConnection(host: lo, port: port, keyStore: aks, config: cfg)
        _ = try? await a.connect()      // retransmits every 200 ms for 0.7 s -> exceeds 3 within window
        // Second client.
        let b = ClientConnection(host: lo, port: port, keyStore: aks, config: cfg)
        _ = try? await b.connect()
        // Assert: some attempts were rate limited.
        XCTAssertGreaterThan(s.stats.rateLimited, 0)
        // Cleanup.
        await s.stop()
    }

    // Group: datagram integrity on the real socket.
    // MARK: datagram integrity on the real socket

    // Scenario: every datagram the client sends is sent twice.
    // Expected: the host delivers each of 5 inputs exactly once and counts the duplicates as replay drops.
    // Why it matters: a network attacker repeating packets must not repeat actions.
    func testReplayedDatagramsDroppedOverLoopback() async throws {
        // Arrange: a paired pair.
        let (s, _, c, _, _) = try await pairedPair()
        // Collect host input.
        let inputs = Collector<InputEvent>()
        // Hook.
        s.onInput = { inputs.add($0) }
        c.outboundFilter = { [$0, $0] }                       // every datagram sent twice (network replay)
        // Act: send five key events.
        for i in 0..<5 {
            // Send one.
            try c.send(input: .key(text: "k\(i)", mods: 0))
            // Pause to stay under the host's rate limit.
            try await Task.sleep(nanoseconds: 70_000_000)      // respect the 50 ms host input limit
        }
        // Wait for 5 events and at least 5 replay drops.
        let ok = await eventually { inputs.count == 5 && s.stats.replayDrops >= 5 }   // duplicates seen and dropped
        // Assert: reached.
        XCTAssertTrue(ok)
        XCTAssertEqual(inputs.count, 5)                       // exactly once each
        XCTAssertGreaterThanOrEqual(s.stats.replayDrops, 5)
        // Cleanup.
        c.disconnect(); await s.stop()
    }

    // Scenario: the first sent copy is damaged in transit; then damage stops.
    // Expected: the damaged copy is dropped and counted as an authentication failure; the resend then gets through once.
    // Why it matters: tampering is detected and reliable messages still arrive.
    func testTamperedDatagramsDroppedThenRetransmitDelivers() async throws {
        // Arrange: a paired pair.
        let (s, _, c, _, _) = try await pairedPair()
        // Collect control messages.
        let inputs = Collector<ControlMessage>()
        s.onControl = { inputs.add($0) }   // control is reliable; INPUT is deliberately unreliable now (stale-input fix)
        // Flag that says whether to damage packets.
        let tamper = Flag(true)
        // Hook: damage every outgoing packet while the flag is on.
        c.outboundFilter = { d in
            // Pass packets through unchanged once the flag is off.
            guard tamper.value else { return [d] }
            var b = d; b[b.count - 20] ^= 0x01                 // flip a ciphertext bit
            // Return the damaged copy.
            return [b]
        }
        // Act: send a control message.
        try c.send(control: .requestIDR)
        // Wait for the host to notice an authentication failure.
        let seen = await eventually { s.stats.authDrops >= 1 }
        // Assert: it did.
        XCTAssertTrue(seen)
        XCTAssertEqual(inputs.count, 0)                       // tampered copy never delivered
        tamper.value = false                                  // retransmission (fresh counter) now gets through
        // Wait for the resend to arrive.
        let ok = await eventually { inputs.count == 1 }
        // Assert: it arrived.
        XCTAssertTrue(ok)
        let dup = await eventually(0.5) { inputs.count > 1 }                  // deadline poll for any duplicate
        // Assert: no duplicate appeared.
        XCTAssertFalse(dup)
        // Assert: delivered once.
        XCTAssertEqual(inputs.count, 1)
        // Cleanup.
        c.disconnect(); await s.stop()
    }

    // Scenario: the client drops every second outgoing datagram while sending 8 control messages.
    // Expected: all 8 arrive, in order, with no duplicates, and the client retransmitted.
    // Why it matters: control messages are reliable even on a lossy link.
    func testControlReliableUnderHeavyLoss() async throws {
        // Arrange: a paired pair.
        let (s, _, c, _, _) = try await pairedPair()
        // Collect control messages.
        let ctrl = Collector<ControlMessage>()
        // Hook.
        s.onControl = { ctrl.add($0) }
        // A counter to alternate.
        let n = Tally()
        c.outboundFilter = { d in n.next() % 2 == 0 ? [] : [d] }   // drop every second datagram
        // Act: send eight bitrate messages.
        for i in 0..<8 {
            try c.send(control: .bitrate(UInt32(1000 + i)))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        // Wait up to 8 seconds for all of them.
        let ok = await eventually(8) { ctrl.count == 8 }
        // Assert: all arrived.
        XCTAssertTrue(ok, "got \(ctrl.count)")
        XCTAssertEqual(ctrl.all, (0..<8).map { .bitrate(UInt32(1000 + $0)) })   // in order, no duplicates
        // Assert: retransmits happened.
        XCTAssertGreaterThan(c.stats.retransmits, 0)
        // Cleanup.
        c.disconnect(); await s.stop()
    }

    // Group: video.
    // MARK: video

    // Scenario: send a large frame cleanly, then a frame with one fragment lost, then a later frame.
    // Expected: the big frame arrives intact; the damaged frame is skipped; the next frame is intact; the client asks for a keyframe.
    // Why it matters: shows that video loss is recovered, not stuck.
    func testVideoRoundTripAcrossFragmentsWithLoss() async throws {
        // Arrange: a paired pair.
        let (s, _, c, _, _) = try await pairedPair()
        // Collectors.
        let frames = Collector<VideoFrame>(), ctrl = Collector<ControlMessage>()
        // Hook: record received frames.
        c.onVideoFrame = { d, k in frames.add(VideoFrame(data: d, isKeyframe: k, ptsUs: 0, frameID: 0)) }
        // Hook: record control messages.
        s.onControl = { ctrl.add($0) }
        // A flag that makes the host drop one large datagram.
        let drop = Flag(false)
        // Host drops one large datagram when the flag is taken.
        s.outboundFilter = { d in drop.take() && d.count > 1000 ? [] : [d] }
        var rng = SystemRandomNumberGenerator()
        // A 20,000-byte random frame.
        let big = Data((0..<20_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        // Assert: it splits into more than 10 fragments.
        XCTAssertGreaterThan(try VideoFragmenter.fragment(frameID: 0, ptsUs: 0, isKeyframe: true, annexB: big).count, 10)

        // Act: send it with no loss.
        try s.sendVideoFrame(big, isKeyframe: true, ptsUs: 100)                   // lossless: many fragments
        // Wait for it.
        let first = await eventually { frames.count == 1 }
        // Assert: it arrived.
        XCTAssertTrue(first)
        // Assert: identical data.
        XCTAssertEqual(frames.all[0].data, big)
        // Assert: marked as keyframe.
        XCTAssertTrue(frames.all[0].isKeyframe)

        // A smaller frame that will lose a fragment.
        let mid = Data((0..<5_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        // Turn on the loss.
        drop.value = true                                                          // lose exactly one fragment of frame 1
        // Act: send the damaged frame.
        try s.sendVideoFrame(mid, isKeyframe: false, ptsUs: 200)
        // A later frame.
        let tail = Data((0..<3_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        // Act: send it.
        try s.sendVideoFrame(tail, isKeyframe: false, ptsUs: 300)
        // Wait for the second delivered frame.
        let second = await eventually { frames.count == 2 }
        // Assert: it arrived.
        XCTAssertTrue(second)
        XCTAssertEqual(frames.all[1].data, tail)                                   // damaged frame skipped, next frame intact
        // Assert: the damaged frame was never delivered.
        XCTAssertFalse(frames.all.contains { $0.data == mid })
        let idr = await eventually { ctrl.all.contains(.requestIDR) }              // client asked for a keyframe
        // Assert: the client asked for a keyframe.
        XCTAssertTrue(idr)
        // Cleanup.
        c.disconnect(); await s.stop()
    }

    // Group: keyframe requests.
    // MARK: keyframe requests

    // Scenario: ask for keyframes repeatedly.
    // Expected: refused before connecting; one request goes through; further requests inside the interval are refused and only one reaches the host; after the interval another is allowed.
    // Why it matters: stops a keyframe request flood, since keyframes are expensive.
    func testRequestKeyframeReachesHostAndIsRateLimited() async throws {
        // Arrange: client config with a 0.4 s minimum gap.
        var ccfg = fastConfig(name: "Phone"); ccfg.keyframeRequestMinInterval = 0.4
        // Start a host.
        let (s, _, port) = try await makeServer()
        // Collect control messages.
        let ctrl = Collector<ControlMessage>()
        // Hook.
        s.onControl = { ctrl.add($0) }
        // Make the client.
        let (c, _) = makeClient(port, cfg: ccfg)
        XCTAssertFalse(c.requestKeyframe())                          // not established yet
        // Act: pair.
        _ = try await c.pair(code: try s.beginPairing().displayString)
        // Assert: the first request is accepted.
        XCTAssertTrue(c.requestKeyframe())
        XCTAssertFalse(c.requestKeyframe())                          // inside the limiter window
        XCTAssertFalse(c.requestKeyframe())
        // Wait for the host to receive exactly one.
        let got = await eventually { ctrl.all.filter { $0 == .requestIDR }.count == 1 }
        // Assert: it did.
        XCTAssertTrue(got)
        // Check no extra one shows up.
        let extra = await eventually(0.3) { ctrl.all.filter { $0 == .requestIDR }.count > 1 }
        // Assert: none did.
        XCTAssertFalse(extra)
        let again = await eventually(2) { c.requestKeyframe() }      // allowed again after the interval
        // Assert: allowed again.
        XCTAssertTrue(again)
        // Wait for the host's second request.
        let two = await eventually { ctrl.all.filter { $0 == .requestIDR }.count == 2 }
        // Assert: it arrived.
        XCTAssertTrue(two)
    }

    // Group: anti-amplification (the host never sends more than it receives to unproven senders).
    // MARK: anti-amplification

    /// Raw UDP probe: sends `payload` to 127.0.0.1:port, returns the size of the first reply or nil after `wait`.
    // Helper: sends one raw datagram and returns the size of the first reply, or nil if none arrives in time.
    private func probe(port: UInt16, payload: Data, wait: TimeInterval = 0.4) -> Int? {
        // Open a socket.
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        // Always close it.
        defer { close(fd) }
        // Set the receive timeout.
        var tv = timeval(tv_sec: 0, tv_usec: Int32(wait * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Describe the destination.
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        // Send the payload.
        let sent = payload.withUnsafeBytes { p in
            withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, p.baseAddress, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        // If it was not sent in full, report no reply.
        guard sent == payload.count else { return nil }
        // Wait for a reply.
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? n : nil
    }

    // Scenario: send unauthenticated datagrams to the host: too-small first message, padded first message, garbage, and a wrong-type message.
    // Expected: a bare 52-byte first message gets no reply (the reply would be bigger); a padded one gets a reply no larger than the request; garbage and wrong types get nothing.
    // Why it matters: stops the host from being used to amplify traffic at a spoofed address.
    func testUnauthenticatedReplyNeverLargerThanRequest() async throws {
        // Arrange: a host with a long device name, making the reply as large as it can be.
        var scfg = fastConfig(name: "Host"); scfg.deviceName = String(repeating: "H", count: 64)   // worst-case M2
        // Start it.
        let (s, _, port) = try await makeServer(scfg)
        // Open pairing.
        let code = try s.beginPairing()
        // Helper: builds a first message the way a client would.
        func m1() throws -> Data {
            var hs = try NoiseHandshake(pattern: .xxPsk3, role: .initiator, staticKey: Curve25519.KeyAgreement.PrivateKey(),
                                        psk: NetCrypto.psk(fromCredential: code.bytes), prologue: NetCrypto.prologue)
            return try FrameCodec.encode(.pairM1(eAndTag: Array(try hs.writeMessage(Data()))))
        }
        // Build a bare (unpadded) first message.
        let bare = try m1()
        // Assert: it is 52 bytes.
        XCTAssertEqual(bare.count, 52)
        // bare 52-byte M1: the reply would be larger, so the host must stay silent
        // Assert: no reply.
        XCTAssertNil(probe(port: port, payload: bare))
        // padded M1 (what ClientConnection sends): reply allowed and never larger than the request
        // Build a padded first message.
        let padded = PairM1Padding.pad(try m1())
        // Send and measure the reply.
        let reply = probe(port: port, payload: padded)
        // Assert: there is a reply.
        XCTAssertNotNil(reply)
        // Assert: it is not bigger than the request.
        XCTAssertLessThanOrEqual(reply ?? .max, padded.count)
        // garbage and wrong-type datagrams get no reply at all
        // Assert: garbage gets no reply.
        XCTAssertNil(probe(port: port, payload: Data(repeating: 0xAB, count: 300)))
        // Assert: a wrong-type message (a third message with no session) gets no reply.
        XCTAssertNil(probe(port: port, payload: Data([FrameCodec.magic0, FrameCodec.magic1, FrameCodec.version, WireType.pairM3.rawValue]) + Data(repeating: 1, count: 100)))
        // Assert: the size rule allows equal size.
        XCTAssertTrue(PairM1Padding.replyAllowed(replyBytes: 52, receivedBytes: 52))
        // Assert: the size rule refuses a bigger reply.
        XCTAssertFalse(PairM1Padding.replyAllowed(replyBytes: 53, receivedBytes: 52))
    }

    // Group: stop and kill switch.
    // MARK: stop / kill switch

    // Scenario: stop the host while a client is connected.
    // Expected: the port is freed, the host is stopped and not listening, the client is told the peer said goodbye, new connections get no answer, and the host can be started again.
    // Why it matters: stopping must really close the door.
    func testStopClosesListener() async throws {
        // Arrange: a paired pair.
        let (s, _, c, cks, port) = try await pairedPair()
        // Assert: the host holds the port while running.
        XCTAssertFalse(portIsFree(port), "listener should hold the port while running")
        // Collect client state changes.
        let states = Collector<SessionState>()
        // Hook.
        c.onStateChange = { states.add($0) }
        // Act: stop the host.
        await s.stop()
        // Assert: not listening.
        XCTAssertFalse(s.isListening)
        // Assert: stopped.
        XCTAssertEqual(s.state, .stopped)
        // Wait for the port to be released.
        let freed = await eventually { portIsFree(port) }
        // Assert: released.
        XCTAssertTrue(freed, "port still bound after stop()")
        let bye = await eventually { states.all.contains(.closed(.peerBye)) }       // peer was told BYE
        // Assert: the client saw a goodbye.
        XCTAssertTrue(bye)
        // Short timeout.
        var cfg = fastConfig(); cfg.handshakeTimeout = 0.5
        // A new client tries to connect.
        let c2 = ClientConnection(host: lo, port: port, keyStore: cks, config: cfg)
        do { try await c2.connect(); XCTFail("stopped server answered") }
        catch { XCTAssertEqual(error as? LanternNetError, .timedOut) }
        // can be started again explicitly
        // Act: start again.
        let p2 = try await s.start(bindAddress: lo, port: 0)
        // Assert: a port was assigned.
        XCTAssertNotEqual(p2, 0)
        // Cleanup.
        await s.stop()
    }

    // Scenario: use the kill switch while a client is connected, then try to start, then reset.
    // Expected: the host stops and frees the port, the switch is engaged, start fails with killSwitchEngaged, and after a reset it can start again.
    // Why it matters: an emergency stop must hold until deliberately cleared.
    func testKillSwitch() async throws {
        // Arrange: a paired pair.
        let (s, _, c, _, port) = try await pairedPair()
        // Act: engage the kill switch.
        s.killSwitch()
        // Assert: not listening.
        XCTAssertFalse(s.isListening)
        // Assert: engaged.
        XCTAssertTrue(s.killSwitchEngaged)
        // Assert: stopped.
        XCTAssertEqual(s.state, .stopped)
        // Wait for the port to be freed.
        let freed = await eventually { portIsFree(port) }
        // Assert: freed.
        XCTAssertTrue(freed)
        do { _ = try await s.start(bindAddress: lo, port: 0); XCTFail() }
        catch { XCTAssertEqual(error as? LanternNetError, .killSwitchEngaged) }
        // Act: clear the kill switch.
        s.resetKillSwitch()
        // Start works again.
        _ = try await s.start(bindAddress: lo, port: 0)
        // Cleanup.
        await s.stop()
        c.disconnect()
    }

    // Group: SecureSession in memory (no sockets): reliability, replay and tamper handling.
    // MARK: SecureSession (in memory): reliability, replay, tamper

    // Helper: builds two linked secure session ends (a and b) with matching keys.
    private func sessionPair() -> (SecureSession, SecureSession) {
        // Two linked cipher states.
        let k1 = NoiseCipherState(key: SymmetricKey(size: .bits256)), k2 = NoiseCipherState(key: SymmetricKey(size: .bits256))
        // A fixed time.
        let now = Date()
        return (SecureSession(send: k1, receive: k2, sessionID: 42, config: NetConfig(), now: now),
                SecureSession(send: k2, receive: k1, sessionID: 42, config: NetConfig(), now: now))
    }

    // Scenario: send a reliable message and try a tampered copy, a repeat, a short copy and a wrong session id.
    // Expected: damaged is dropped as auth; the real one is delivered; the repeat is dropped as replay; a short one as malformed; a changed session id as wrongSession.
    // Why it matters: each drop reason must be classified and nothing bad is delivered.
    func testSessionReplayAndTamper() throws {
        // Arrange: two session ends.
        var (a, b) = sessionPair()
        // Fixed time.
        let now = Date()
        // Act: a creates a reliable message.
        let d = try a.reliable(.input(.tap(x: 0.5, y: 0.5)), now: now)
        // Damage a copy.
        var t = d; t[t.count - 1] ^= 0x80
        // Assert: the damaged copy is dropped as auth.
        XCTAssertEqual(b.receive(t, now: now).drop, .auth)
        // Receive the real one.
        let ok = b.receive(d, now: now)
        // Assert: no drop and one delivered message.
        XCTAssertNil(ok.drop); XCTAssertEqual(ok.delivered.count, 1)
        // Assert: receiving it again is a replay.
        XCTAssertEqual(b.receive(d, now: now).drop, .replay)
        // Assert: a truncated copy is malformed.
        XCTAssertEqual(b.receive(d.prefix(10), now: now).drop, .malformed)
        // Change a byte of the session id.
        var wrongSID = d; wrongSID[7] ^= 1
        // Assert: wrong session.
        XCTAssertEqual(b.receive(wrongSID, now: now).drop, .wrongSession)
    }

    // Scenario: three reliable messages where the first is lost and the others arrive early; then a retransmit.
    // Expected: nothing is delivered until the first arrives, then all three are delivered in order; a late duplicate is acknowledged but not redelivered; after the acks, nothing is left to retransmit.
    // Why it matters: reliable means ordered and exactly once.
    func testSessionReliableOrderingAndDedup() throws {
        // Arrange: two session ends.
        var (a, b) = sessionPair()
        // Start time.
        let t0 = Date()
        // Three messages a, b, c.
        let m0 = try a.reliable(.input(.key(text: "a", mods: 0)), now: t0)
        let m1 = try a.reliable(.input(.key(text: "b", mods: 0)), now: t0)
        let m2 = try a.reliable(.input(.key(text: "c", mods: 0)), now: t0)
        // The first is lost, and the second and third arrive first.
        // m0 lost; m2 then m1 arrive first: nothing delivered until m0 shows up, then in order
        // Assert: the third is held back.
        XCTAssertEqual(b.receive(m2, now: t0).delivered.count, 0)
        // Assert: the second is held back.
        XCTAssertEqual(b.receive(m1, now: t0).delivered.count, 0)
        // sender retransmits after the timeout (fresh counters)
        // Move time forward past the retransmit timeout.
        let t1 = t0.addingTimeInterval(0.2)
        // Act: the sender ticks and resends.
        let re = a.tick(now: t1)
        // Assert: all three unacknowledged messages are resent.
        XCTAssertEqual(re.datagrams.count, 3)                        // 3 unacked, each re-sealed with a fresh counter
        // Collect delivered events and acknowledgments.
        var got: [InputEvent] = [], acks: [Data] = []
        // Act: receive each resent datagram.
        for d in re.datagrams {
            // Record delivered events and replies.
            let r = b.receive(d, now: t1); got += r.delivered.compactMap { if case .input(let e, _) = $0 { return e }; return nil }; acks += r.replies
        }
        // Assert: all three are delivered in order.
        XCTAssertEqual(got, [.key(text: "a", mods: 0), .key(text: "b", mods: 0), .key(text: "c", mods: 0)])
        // a late original duplicate of m0 is acked again but never redelivered
        // Act: receive an old duplicate of the first message.
        let dup = b.receive(m0, now: t1)
        // Assert: not redelivered, but acknowledged again.
        XCTAssertEqual(dup.delivered.count, 0); XCTAssertEqual(dup.replies.count, 1)
        // Send the acknowledgments back to the sender.
        for ack in acks { _ = a.receive(ack, now: t1) }
        // Assert: nothing remains unacknowledged.
        XCTAssertEqual(a.unackedCount, 0)
        // Assert: no more retransmits.
        XCTAssertEqual(a.tick(now: t1.addingTimeInterval(1)).datagrams.count, 0)   // nothing left to retransmit
    }
}
