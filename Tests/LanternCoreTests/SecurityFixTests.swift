// ==============================================================================
// Program: SecurityFixTests.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Regression tests verifying remediation of historical security vulnerabilities.
//          Inputs: Targeted attack vectors (replay packets, unauthorized public keys, spoofed frames).
//          Outputs: Assertions demonstrating that attacks are detected and dropped.
//          Design Rationale: Ensures critical security defenses cannot be inadvertently undone during refactoring.
// ==============================================================================
// Area protected: regression tests for security fixes in the network layer. Each group
// guards a past weakness: stale or delayed input must never be injected late (freshness and
// rate limits), junk or repeated pairing attempts must not lock out the real user or flood the
// host (lockout abuse and handshake caps), the host may only bind to private addresses, and peer
// names from the network must be cleaned before being stored or shown.
// Most tests use real loopback sockets with short timeouts, so they run fast and need no internet.
import XCTest
import CryptoKit
import Foundation
@testable import LanternCore

// Test helper: a small thread-safe list for collecting values from other threads.
private final class Got<T: Sendable>: @unchecked Sendable {
    private let l = NSLock(); private var v: [T] = []
    func add(_ x: T) { l.lock(); v.append(x); l.unlock() }
    var all: [T] { l.lock(); defer { l.unlock() }; return v }
}

// Test helper: polls a condition every 20 ms until it is true or the timeout (4 s by default) passes.
private func eventually(_ timeout: TimeInterval = 4, _ cond: @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
    return cond()
}

// Test helper: a raw UDP socket on the loopback address, used to hand-craft handshake packets that a normal client would never send.
/// Raw UDP peer on 127.0.0.1 (its own source port), for crafting handshake messages.
private final class RawPeer {
    let fd: Int32
    let port: UInt16
    // Open a UDP socket aimed at the given host port and set a short 0.4 s receive timeout.
    init(port: UInt16) {
        self.port = port
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var tv = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    // Close the socket when the helper goes away.
    deinit { close(fd) }
    // Send a datagram to the host's loopback port.
    func send(_ d: Data) {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = d.withUnsafeBytes { p in
            withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, p.baseAddress, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
    }
    // Wait for one datagram; returns nil if nothing arrives in time.
    func recv() -> Data? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.recv(fd, &buf, buf.count, 0)
        return n > 0 ? Data(buf.prefix(n)) : nil
    }
}

// Tests for the security fixes, grouped by the problem each one closes.
final class SecurityFixTests: XCTestCase {
    // The loopback address used by all tests.
    private let lo = "127.0.0.1"

    // Helper: a fast network config (short handshake timeout, quick ticks and retransmit) with an optional device name.
    private func cfg(_ name: String = "Host") -> NetConfig {
        var c = NetConfig(); c.deviceName = name; c.handshakeTimeout = 1; c.tick = 0.02; c.reliableRetransmit = 0.08
        return c
    }
    // Helper: starts a host server on a free loopback port with a fresh key store, and stops it when the test ends.
    private func makeServer(_ c: NetConfig? = nil) async throws -> (HostServer, InMemoryKeyStore, UInt16) {
        let ks = InMemoryKeyStore()
        let s = HostServer(keyStore: ks, config: c ?? cfg())
        let port = try await s.start(bindAddress: lo, port: 0)
        addTeardownBlock { await s.stop() }
        return (s, ks, port)
    }

    // Group M1: stale input must not be applied late.
    // MARK: M1 stale input

    // Scenario: measure how old an input event is, using the sender's clock stamp and the host clock.
    // Expected: fresh events age about 0, small jitter is small, a 2-second stall gives a large age, and the sender's 32-bit clock wrapping past zero is handled.
    // Why it matters: events held back by a stalled link must not suddenly click things seconds later.
    func testFreshnessDropsOldEventsAndHandlesWraparound() {
        // Arrange: a new freshness tracker.
        var f = InputFreshness()
        // sender clock is 1_000_000 behind the host clock; fresh events age ~0
        // Assert: the first event sets the baseline, age 0.
        XCTAssertEqual(f.age(sentMs: 1_000, nowMs: 1_001_000), 0)
        // Assert: 10 ms of jitter gives age 10.
        XCTAssertEqual(f.age(sentMs: 1_200, nowMs: 1_001_210), 10)          // 10 ms jitter
        // Assert: a 2 s stall gives an age over 250 ms.
        XCTAssertGreaterThan(f.age(sentMs: 1_300, nowMs: 1_003_500), 250)   // 2 s stall then replay
        // 32-bit wrap of the sender clock
        // Arrange: a second tracker, with a sender clock just below the 32-bit maximum.
        var g = InputFreshness()
        let near = UInt32.max - 50
        // Assert: baseline.
        XCTAssertEqual(g.age(sentMs: near, nowMs: 5_000), 0)
        // Assert: after wrapping past zero, the age is still 0.
        XCTAssertEqual(g.age(sentMs: near &+ 100, nowMs: 5_100), 0)         // stamp wrapped past zero
        // Assert: a later stall after wrapping is still detected as old.
        XCTAssertGreaterThan(g.age(sentMs: near &+ 120, nowMs: 5_900), 250)
    }

    // Scenario: a stall delivers old taps, scrolls and drag moves together, then a late drag end and a fresh tap.
    // Expected: the stale ones are dropped and counted (3); the late drag end is still allowed so the held button is released; a fresh tap works.
    // Why it matters: stale input is dropped, but a mouse button must never get stuck down.
    func testGateDropsStaleButStillReleasesDrag() {
        // Arrange: a new gate.
        var g = HostInputGate()
        // Baseline tap is admitted.
        XCTAssertTrue(g.admit(.tap(x: 0.5, y: 0.5), nowMs: 10_000, sentMs: 500))            // baseline
        // A drag start is admitted, so a drag is now in progress.
        XCTAssertTrue(g.admit(.dragStart(x: 0.1, y: 0.1), nowMs: 10_100, sentMs: 600))
        // link stalls 3 s; queued events arrive together, stamped when sent
        // Stale tap is dropped.
        XCTAssertFalse(g.admit(.tap(x: 0.5, y: 0.5), nowMs: 13_200, sentMs: 700))
        // Stale scroll is dropped.
        XCTAssertFalse(g.admit(.scroll(dx: 0, dy: 0.5), nowMs: 13_201, sentMs: 750))
        // Stale drag move is dropped.
        XCTAssertFalse(g.admit(.dragMove(x: 0.2, y: 0.2), nowMs: 13_202, sentMs: 800))
        // Assert: three stale drops were counted.
        XCTAssertEqual(g.staleDropped, 3)
        // a late dragEnd must still release the held button
        // The late drag end is still admitted.
        XCTAssertTrue(g.admit(.dragEnd(x: 0.2, y: 0.2), nowMs: 13_203, sentMs: 850))
        // Assert: nothing is left to release.
        XCTAssertEqual(g.releaseAll(), [])
        // fresh event after the stall is fine
        // A fresh tap is admitted.
        XCTAssertTrue(g.admit(.tap(x: 0.5, y: 0.5), nowMs: 13_400, sentMs: 3_900))
    }

    // Scenario: a global cap of 3 events per second across all kinds, then a release and a later window.
    // Expected: three different events pass, the fourth is dropped, a drag end is never limited, and after the window moves on events pass again.
    // Why it matters: spreading events across kinds must not bypass the flood limit.
    func testGlobalCapDropsAcrossClasses() {
        // Arrange: a limiter with 50 ms spacing and a cap of 3 per second.
        var l = InputRateLimiter(minSpacingMs: 50, globalMax: 3, globalWindowMs: 1000)
        // First event allowed.
        XCTAssertTrue(l.allow(.tap(x: 0, y: 0), nowMs: 1000))
        // Second event (different kind) allowed.
        XCTAssertTrue(l.allow(.scroll(dx: 0, dy: 0), nowMs: 1001))
        // Third event allowed.
        XCTAssertTrue(l.allow(.zoom(delta: 0), nowMs: 1002))
        // Fourth event hits the cap and is dropped.
        XCTAssertFalse(l.allow(.key(text: "a", mods: 0), nowMs: 1003))
        XCTAssertTrue(l.allow(.dragEnd(x: 0, y: 0), nowMs: 1004))        // release is never limited
        // After the window slides, events are allowed again.
        XCTAssertTrue(l.allow(.key(text: "a", mods: 0), nowMs: 2100))    // window slid
    }

    // Scenario: put a time stamp in an input message, send it through a secure session, and retransmit.
    // Expected: the stamp survives decoding; messages with no stamp read as 0; delivered input carries its stamp; unreliable input leaves nothing to retransmit; a retransmitted reliable message keeps its original stamp.
    // Why it matters: freshness checks rely on the original time, not the resend time.
    func testStampRoundTripAndSessionDelivery() throws {
        // Encode a tap with a stamp.
        let enc = try ChannelMessage.encode(.input(.tap(x: 0.5, y: 0.5)), seq: 3, flags: 0, sentMs: 0xDEAD_BEEF)
        // Assert: the stamp decodes back.
        XCTAssertEqual(try ChannelMessage.decodeStamped(enc).sentMs, 0xDEAD_BEEF)
        // Assert: an unstamped control message decodes with stamp 0.
        XCTAssertEqual(try ChannelMessage.decodeStamped(try ChannelMessage.encode(.control(.ping), seq: 1)).sentMs, 0)
        // Arrange: two linked cipher states and two session ends (a sends, b receives).
        let k1 = NoiseCipherState(key: SymmetricKey(size: .bits256)), k2 = NoiseCipherState(key: SymmetricKey(size: .bits256))
        // A fixed 'now' so time is under test control.
        let now = Date()
        var a = SecureSession(send: k1, receive: k2, sessionID: 9, config: NetConfig(), now: now)
        var b = SecureSession(send: k2, receive: k1, sessionID: 9, config: NetConfig(), now: now)
        // Act: a sends an unreliable tap stamped 1234.
        let u = try a.unreliable(.input(.tap(x: 0.1, y: 0.2)), sentMs: 1234)
        // b receives it.
        let r = b.receive(u, now: now)
        // Assert: one message delivered.
        XCTAssertEqual(r.delivered.count, 1)
        // Assert: it is a tap with the right x value and stamp.
        if case .input(.tap(let x, _), let ms)? = r.delivered.first { XCTAssertEqual(x, 0.1, accuracy: 0.001); XCTAssertEqual(ms, 1234) } else { XCTFail() }
        // Assert: nothing is waiting for acknowledgment.
        XCTAssertEqual(a.unackedCount, 0)                                   // nothing to retransmit or replay later
        // Assert: five seconds later the only datagram is the keepalive ping.
        XCTAssertEqual(a.tick(now: now.addingTimeInterval(5)).datagrams.filter { _ in true }.count, 1)   // only the keepalive ping
        // a retransmitted reliable message keeps its ORIGINAL stamp
        // Act: send a reliable drag end stamped 77.
        let rel = try a.reliable(.input(.dragEnd(x: 0.1, y: 0.2)), now: now, sentMs: 77)
        _ = rel
        // Act: tick shortly after, which resends it.
        let again = a.tick(now: now.addingTimeInterval(0.2)).datagrams
        // Collect the stamps b sees.
        var stamps: [UInt32] = []
        // Receive each resent datagram and record the stamp.
        for d in again { for case .input(_, let ms) in b.receive(d, now: now).delivered { stamps.append(ms) } }
        // Assert: the resend carries the original stamp 77.
        XCTAssertEqual(stamps, [77])
    }

    // Scenario: end to end, a client sends fresh events, then events stamped 2 s old, then fresh again.
    // Expected: the host receives only the two fresh taps (0.1 and 0.3); the stale ones are never injected.
    // Why it matters: proves the stale-input protection works over a real connection.
    func testStalledClientEventsAreNeverInjectedLate() async throws {
        // Arrange: a host server and a pairing code.
        let (s, hks, port) = try await makeServer()
        let code = try s.beginPairing()
        // Arrange: a client; disconnect it when the test ends.
        let c = ClientConnection(host: lo, port: port, keyStore: InMemoryKeyStore(), config: cfg("Phone"))
        addTeardownBlock { c.disconnect() }
        // Act: pair.
        _ = try await c.pair(code: code.displayString)
        // Assert: the host stored one peer.
        XCTAssertEqual(try hks.peers().count, 1)
        // Collect events the host receives.
        let got = Got<InputEvent>()
        // Hook: record every input event the host gets.
        s.onInput = { got.add($0) }
        // Unused time reference.
        let base = DispatchTime.now().uptimeNanoseconds / 1_000_000
        // Phase 1: events stamped with the current time.
        // phase 1: fresh stamps
        c.inputClockMs = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
        // Send a fresh tap.
        try c.send(input: .tap(x: 0.1, y: 0.1))
        // Wait for the host to get it.
        let first = await eventually { got.all.count == 1 }
        // Assert: it arrived.
        XCTAssertTrue(first)
        // phase 2: events stamped 2 s in the past (what a stalled-then-replayed queue looks like)
        c.inputClockMs = { DispatchTime.now().uptimeNanoseconds / 1_000_000 &- 2_000 }
        // Short pause so events are separate.
        try await Task.sleep(nanoseconds: 120_000_000)
        // Send a stale tap.
        try c.send(input: .tap(x: 0.2, y: 0.2))
        try await Task.sleep(nanoseconds: 120_000_000)
        // Send a stale scroll.
        try c.send(input: .scroll(dx: 0, dy: 0.5))
        // Phase 3: fresh stamps again.
        // phase 3: fresh again
        c.inputClockMs = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
        try await Task.sleep(nanoseconds: 120_000_000)
        // Send a fresh tap.
        try c.send(input: .tap(x: 0.3, y: 0.3))
        // Wait until the host has two events.
        let third = await eventually { got.all.count >= 2 }
        // Assert: reached two.
        XCTAssertTrue(third)
        // Wait a little longer in case a stale event shows up late.
        try await Task.sleep(nanoseconds: 300_000_000)
        // Gather the tap x values.
        let xs: [Float] = got.all.compactMap { if case .tap(let x, _) = $0 { return x }; return nil }
        // Assert: exactly two events arrived in total.
        XCTAssertEqual(got.all.count, 2)
        // Assert: both were taps.
        XCTAssertEqual(xs.count, 2)
        // Assert: they are the first and third taps.
        if xs.count == 2 { XCTAssertEqual(xs[0], 0.1, accuracy: 0.001); XCTAssertEqual(xs[1], 0.3, accuracy: 0.001) }
        _ = base
    }

    // Group M2: abuse of pairing attempts must not lock out the real user.
    // MARK: M2 pairing lockout abuse

    // Helper: builds the first pairing message as a client would, optionally using a given code, and pads it to the required size. Returns the handshake state and the bytes to send.
    private func m1(_ code: PairingCode?, key: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey())
        throws -> (NoiseHandshake, Data) {
        // Derive the pre-shared key from the code (or use a dummy when no code is given).
        let psk = code.map { NetCrypto.psk(fromCredential: $0.bytes) } ?? Data(repeating: 7, count: 32)
        // Start an initiator handshake.
        var hs = try NoiseHandshake(pattern: .xxPsk3, role: .initiator, staticKey: key, psk: psk, prologue: NetCrypto.prologue)
        // Write message 1 and wrap it in a frame.
        let w = try FrameCodec.encode(.pairM1(eAndTag: Array(try hs.writeMessage(Data()))))
        // Return the state and the padded message.
        return (hs, PairM1Padding.pad(w))
    }

    // Scenario: eight raw peers send a valid first message, then a junk third message.
    // Expected: the host replies to the first message, ignores the junk, counts no failed pairings, keeps the code with 0 failures, and the real user can still pair.
    // Why it matters: junk without proof of the code must not use up the limited attempts.
    func testJunkMessage3NeverConsumesAttempts() async throws {
        // Arrange: a host and a code.
        let (s, _, port) = try await makeServer()
        let code = try s.beginPairing()
        // Act: repeat from eight different sources.
        for _ in 0..<8 {
            // A new raw peer each time.
            let p = RawPeer(port: port)
            // Build a valid first message.
            let (_, wire) = try m1(code)
            // Send it.
            p.send(wire)
            // Assert: the host answers with message 2.
            XCTAssertNotNil(p.recv())                                       // M2
            // Build a junk third message of the right size.
            let junk = try FrameCodec.encode(.pairM3(encS: Array(repeating: 0xAA, count: 48),
                                                     encPayload: Array((0..<40).map { UInt8($0) })))
            // Send the junk.
            p.send(junk)
        }
        // Give the host time to process.
        try await Task.sleep(nanoseconds: 200_000_000)
        // Assert: no failed pairings were counted.
        XCTAssertEqual(s.stats.failedPairings, 0)
        // Assert: the code is still shown with zero failures.
        XCTAssertEqual(s.pairingState, .codeShown(expiresAt: { if case .codeShown(let e, _) = s.pairingState { return e }; return Date() }(), failures: 0))
        // Assert-by-action: a real client can still pair.
        // the real user can still pair afterwards
        // Arrange the real client.
        let c = ClientConnection(host: lo, port: port, keyStore: InMemoryKeyStore(), config: cfg("Phone"))
        addTeardownBlock { c.disconnect() }
        // Act: pair successfully.
        _ = try await c.pair(code: code.displayString)
    }

    // Scenario: one source sends proper handshakes with a wrong code, six times.
    // Expected: the host answers only 3 times (per-source limit), counts 3 failures, the pairing stays open with 3 failures, and the per-source limit is below the global lockout limit.
    // Why it matters: one attacker must not be able to lock the code for everybody.
    func testAuthenticatedWrongCodeCountsButOneSourceCannotLock() async throws {
        // Arrange: a host and a code.
        let (s, _, port) = try await makeServer()
        let code = try s.beginPairing()
        // Pick a wrong code that differs from the real one.
        var wrong = PairingCode.generate()
        while wrong.text == code.text { wrong = PairingCode.generate() }
        // Count of replies from the host.
        var replies = 0
        // Act: six attempts.
        for _ in 0..<6 {
            // A new raw peer each time.
            let p = RawPeer(port: port)
            // Build message 1 with the wrong code.
            var (hs, wire) = try m1(wrong)
            // Send it.
            p.send(wire)
            // Wait for message 2; no answer means the source is out of budget.
            guard let m2 = p.recv() else { continue }                       // silent once the source budget is spent
            // Count the reply.
            replies += 1
            // Read message 2.
            _ = try hs.readMessage(Data(m2.dropFirst(FrameCodec.headerSize)))
            // Write message 3, which is authenticated but with the wrong code.
            let m3 = try hs.writeMessage(Data("x".utf8))
            // Send message 3.
            p.send(try FrameCodec.encode(.pairM3(encS: Array(m3[0..<48]), encPayload: Array(m3[48...]))))
            // Short pause between attempts.
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        // Assert: three replies (the per-source maximum).
        XCTAssertEqual(replies, 3)                                          // maxPairFailuresPerSource
        // Assert: three failures counted.
        XCTAssertEqual(s.stats.failedPairings, 3)
        // Assert: the code is still shown with 3 failures (not locked or closed).
        if case .codeShown(_, let f) = s.pairingState { XCTAssertEqual(f, 3) } else { XCTFail("locked or closed: \(s.pairingState)") }
        // Assert: the global lockout limit is at most 5.
        XCTAssertLessThan(PairingPolicy.maxFailures, 5 + 1)
        // Assert: the per-source limit is lower than the global limit.
        XCTAssertLessThan(NetConfig().maxPairFailuresPerSource, PairingPolicy.maxFailures)
    }

    // Scenario: send many first messages from different sources, then repeat under a low global rate.
    // Expected: only 2 get answers when pending handshakes are capped per source; with a global rate of 3 per second, only 3 of 6 are answered and the rest get a short reject.
    // Why it matters: bounds memory and CPU an attacker can use.
    func testPendingHandshakeCapsPerSourceAndGlobalRate() async throws {
        // Arrange: a host and a code.
        let (s, _, port) = try await makeServer()
        let code = try s.beginPairing()
        // Count of answered peers.
        var got = 0
        // Keep peers alive so their ports stay used.
        var peers: [RawPeer] = []
        // Act: four peers each send message 1.
        for _ in 0..<4 {
            // Create and keep the peer.
            let p = RawPeer(port: port); peers.append(p)
            // Send message 1.
            p.send(try m1(code).1)
            // Count a reply.
            if p.recv() != nil { got += 1 }
        }
        // Assert: only two were answered.
        XCTAssertEqual(got, 2)                                              // per-source pending cap
        // Stop the first server.
        await s.stop()

        // Arrange: a second server with a global rate of 3 and a high per-source cap.
        var c = cfg(); c.maxHandshakesPerSecondGlobal = 3; c.maxPendingPerSource = 50
        // Start it.
        let (s2, _, port2) = try await makeServer(c)
        // Open pairing.
        let code2 = try s2.beginPairing()
        // Count of full answers.
        var got2 = 0
        // Act: six peers each send message 1.
        for _ in 0..<6 {
            // Create and keep the peer.
            let p = RawPeer(port: port2); peers.append(p)
            // Send message 1.
            p.send(try m1(code2).1)
            // Count only replies longer than a 4-byte reject.
            if (p.recv()?.count ?? 0) > 4 { got2 += 1 }   // rate-limited sources get the 4-byte REJECT
        }
        // Assert: three full answers (the global budget).
        XCTAssertEqual(got2, 3)                                             // global handshake budget
    }

    // Group: bind address and device name cleaning.
    // MARK: bind and name hygiene

    // Scenario: parse many bind addresses.
    // Expected: private, loopback and link-local addresses (v4 and v6) are accepted; public and look-alike ranges are refused with nonPrivateBindRefused; the server refuses to start on a public address and does not listen.
    // Why it matters: the host must not be reachable from the open internet.
    func testBindAddressMustBePrivate() async throws {
        // Addresses that must be accepted.
        for ok in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.5", "127.0.0.1", "169.254.1.1",
                   "::1", "fe80::1", "fd00::1", "::ffff:192.168.1.2"] {
            // Assert: each good address parses.
            XCTAssertNoThrow(try BindCheck.parse(ok), ok)
        }
        // Addresses that must be refused, including ranges just outside the private blocks.
        for bad in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "100.64.0.1", "192.169.0.1", "11.0.0.1", "2001:4860::1", "::ffff:8.8.8.8"] {
            // Assert: each throws the nonPrivateBindRefused error.
            XCTAssertThrowsError(try BindCheck.parse(bad), bad) { XCTAssertEqual($0 as? LanternNetError, .nonPrivateBindRefused, bad) }
        }
        // Arrange: a server.
        let s = HostServer(keyStore: InMemoryKeyStore())
        // Act: try to start on a public address; fail the test if it works. Assert: the catch below expects the nonPrivateBindRefused error.
        do { _ = try await s.start(bindAddress: "8.8.8.8", port: 0); XCTFail("bound a public address") }
        catch { XCTAssertEqual(error as? LanternNetError, .nonPrivateBindRefused) }
        // Assert: the server is not listening.
        XCTAssertFalse(s.isListening)
    }

    // Scenario: clean device names that came from the network.
    // Expected: control characters and escape sequences are removed; direction and invisible characters are removed; empty or control-only names become a placeholder; a cut inside a multibyte character leaves no broken character; a stored name after real pairing is clean.
    // Why it matters: names are shown to the user and could carry tricks such as hidden text or terminal escapes.
    func testPeerNameSanitised() async throws {
        // Control characters and escape are removed.
        XCTAssertEqual(PeerName.sanitize(Data("Ph\u{1b}[31mone\u{7}\n".utf8)), "Ph[31mone")
        // Direction and invisible characters are removed.
        XCTAssertEqual(PeerName.sanitize(Data("a\u{202e}b\u{200b}c\u{2028}d".utf8)), "abcd")
        // Empty data gives the placeholder.
        XCTAssertEqual(PeerName.sanitize(Data()), "Unnamed device")
        // Only control characters gives the placeholder.
        XCTAssertEqual(PeerName.sanitize(Data("\u{1}\u{2}".utf8)), "Unnamed device")
        // 64-byte cut in the middle of a multibyte character leaves no replacement character
        // Arrange: a 64-byte cut that ends in the middle of an accented letter.
        let cut = Data((String(repeating: "a", count: 63) + "é").utf8.prefix(64))
        // Assert: no replacement character appears.
        XCTAssertFalse(PeerName.sanitize(cut).contains("\u{FFFD}"))
        // end to end: the stored record is clean
        // Arrange: a host and pairing code.
        let (s, hks, port) = try await makeServer()
        let code = try s.beginPairing()
        // Arrange a client; disconnect when done.
        let c = ClientConnection(host: lo, port: port, keyStore: InMemoryKeyStore(), config: cfg("Phone"))
        addTeardownBlock { c.disconnect() }
        // Act: pair with a dirty device name.
        _ = try await c.pair(code: code.displayString, deviceName: "Ph\u{1b}[2Jone\u{202e}")
        // Assert: the stored name is the cleaned version.
        XCTAssertEqual(try hks.peers().first?.name, "Ph[2Jone")
    }
}
