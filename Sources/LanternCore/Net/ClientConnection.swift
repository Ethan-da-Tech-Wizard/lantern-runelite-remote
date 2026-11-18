// ==============================================================================
// Program: ClientConnection.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Client-side UDP connection state machine managing pairing, Noise handshakes, and transport.
//          Inputs: Host IP address, port number, pairing credentials, and outbound input events.
//          Outputs: Encrypted UDP datagram stream and decoded video frames.
//          Design Rationale: Implements non-blocking asynchronous state machine with heartbeat keepalives
//          and automatic reconnection upon WiFi roaming.
// ==============================================================================
// =====================================================================================
// ClientConnection.swift
//
// PURPOSE: The "client" side of the encrypted UDP link (the device that views the stream and sends
// taps/controls). It pairs once with a code or QR payload, can later reconnect to a paired host,
// then receives video and control messages and sends input.
//
// WHO CALLS IT: the app's connection/UI code calls pair(...), connect(...), send(...),
// requestKeyframe() and disconnect(), and reads video/state through the callbacks or AsyncStreams.
// It talks to HostServer (same folder) over the network.
//
// KEY IDEAS (RuneLite Client Connection & Network State Machine):
//  - Remote Streaming Client Pipeline:
//    * Connects to the Mac host over local Wi-Fi UDP.
//    * Streams incoming H.264 video fragments into the video reassembler and forwards completed frames to the display layer.
//    * Transmits touch and keyboard input events over the authenticated ChaCha20-Poly1305 encrypted channel.
//  - UDP Handshake & Reconnection:
//    * Since UDP is connectionless, handshake packets are retried on an exponential backoff timer until acknowledged.
//    * Seamlessly handles IP address changes when the iPhone roams between Wi-Fi access points.
//  - Concurrency Model:
//    * All internal session state is serialized on queue `q`, exposing clean async/await Swift concurrency interfaces.
// =====================================================================================

import Foundation
// CryptoKit: Curve25519 public keys. Network: NWConnection (Apple's networking API).
import CryptoKit
import Network

/// Encrypted UDP client. Pair once with a code/QR (Noise_XXpsk3), then reconnect with Noise_IK.
/// Callbacks run on an internal serial queue. Never logs keys, codes or full peer identifiers.
public final class ClientConnection: @unchecked Sendable {
    /// The underlying Network.framework reason when a connection attempt fails or waits (kept for diagnostics; shown to the user).
    // Filled in when the OS reports the connection failed or is waiting.
    public internal(set) var lastNetworkError: String?
    /// The serial queue that owns all mutable state; network callbacks also run on it.
    private let q = DispatchQueue(label: "org.twu.lantern.client")
    /// Where the host is (address text and UDP port).
    private let host: String
    private let port: UInt16
    /// Stores this device's long-term key and the list of paired hosts.
    private let keyStore: KeyStore
    /// Timing and limit settings.
    private let cfg: NetConfig
    /// Source of "now"; tests can swap in a fake clock.
    private let clock: @Sendable () -> Date

    /// Callbacks live in LockedBoxes so the app may set or replace them from any thread.
    private let _onVideo = LockedBox<(@Sendable (Data, Bool) -> Void)?>(nil)
    private let _onControl = LockedBox<(@Sendable (ControlMessage) -> Void)?>(nil)
    private let _onState = LockedBox<(@Sendable (SessionState) -> Void)?>(nil)
    private let _filter = LockedBox<DatagramFilter?>(nil)
    /// Public properties wrapping those boxes: the app assigns closures here to receive events.
    public var onVideoFrame: (@Sendable (_ frame: Data, _ isKeyframe: Bool) -> Void)? { get { _onVideo.get() } set { _onVideo.set(newValue) } }
    public var onControl: (@Sendable (ControlMessage) -> Void)? { get { _onControl.get() } set { _onControl.set(newValue) } }
    public var onStateChange: (@Sendable (SessionState) -> Void)? { get { _onState.get() } set { _onState.set(newValue) } }
    /// Test/fault-injection hook applied to every outbound datagram (return [] to drop, [d, d] to duplicate).
    public var outboundFilter: DatagramFilter? { get { _filter.get() } set { _filter.set(newValue) } }

    /// Broadcasters feed the AsyncStream versions of the same events (for `for await` loops).
    private let videoBus = Broadcaster<VideoFrame>()
    private let stateBus = Broadcaster<SessionState>()
    private let controlBus = Broadcaster<ControlMessage>()
    /// Each call returns a new stream that sees all later events.
    public var videoFrames: AsyncStream<VideoFrame> { videoBus.stream() }
    public var stateChanges: AsyncStream<SessionState> { stateBus.stream() }
    public var controlMessages: AsyncStream<ControlMessage> { controlBus.stream() }

    /// Which step of the connection we are on; the data attached to each case is what that step needs.
    private enum Phase {
        // Nothing in progress.
        case idle
        // First pairing message sent; waiting for the host's reply. `qr` is set when pairing from a QR code (used to check the host key).
        case pairM1(hs: NoiseHandshake, qr: PairingQRPayload?)
        // Third pairing message sent; waiting for the host's first encrypted packet as confirmation. Holds the host key, its name and the short code for humans to compare.
        case pairM3(session: SecureSession, hostPub: Data, hostName: String, sas: String)
        // Reconnect (IK) message sent to an already-paired host; waiting for its reply.
        case ik(hs: NoiseHandshake, hostPub: Data, hostName: String)
        // Handshake done; the encrypted session is in use.
        case established(SecureSession)
    }
    /// Current phase (starts idle).
    private var phase: Phase = .idle
    /// The UDP connection to the host; nil when not connected.
    private var conn: NWConnection?
    /// Repeating timer that drives retransmits and timeouts.
    private var timer: DispatchSourceTimer?
    /// Called exactly once when a pairing/connect attempt finishes (success or failure); resumes the waiting async call.
    private var completion: (@Sendable (Result<PairedInfo?, Error>) -> Void)?
    /// The last handshake packet sent, so it can be re-sent if no answer comes.
    private var lastSent = Data()
    /// When it was last sent.
    private var lastSentAt = Date.distantPast
    /// When we last asked for a keyframe (limits how often we ask).
    private var lastKeyframeRequest = Date.distantPast
    /// When the attempt started (for the handshake timeout).
    private var startedAt = Date()
    /// Name we announce to the host while pairing.
    private var deviceName = "Lantern"
    /// Last state announced, so we only publish changes.
    private var published: SessionState = .idle
    /// Drop counters carried over from finished sessions.
    private var closedStats = NetStats()
    /// Drop counters for packets that arrived during the handshake.
    private var handshakeStats = NetStats()

    /// Create a client for one host address and port. Nothing is sent until pair() or connect() is called.
    public init(host: String, port: UInt16, keyStore: KeyStore, config: NetConfig = NetConfig(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host; self.port = port; self.keyStore = keyStore; self.cfg = config; self.clock = clock
    }

    /// Latest session state (read on the owning queue).
    public var state: SessionState { q.sync { published } }
    /// Drop counters for finished sessions plus the live session (handshake-phase drops are not included).
    public var stats: NetStats {
        q.sync {
            // Start from the counters of sessions that already ended.
            var s = closedStats
            // If a session is live, add its counters.
            if case .established(let sess) = phase {
                s.replayDrops += sess.stats.replayDrops; s.authDrops += sess.stats.authDrops
                s.malformedDrops += sess.stats.malformedDrops; s.wrongSessionDrops += sess.stats.wrongSessionDrops
                s.retransmits += sess.stats.retransmits
            }
            return s
        }
    }

    // MARK: pairing / connecting

    /// Pair with a typed code (dashes/case tolerated). Returns once the host has confirmed.
    @discardableResult
    public func pair(code: String, deviceName: String = "Lantern") async throws -> PairedInfo {
        // Turn the typed text into a pairing code (throws a friendly error if invalid), then run the handshake with it.
        guard let c = try? PairingCode(parsing: code) else { throw LanternNetError.invalidPairingInput }
        return try await beginPairing(credential: c.bytes, qr: nil, name: deviceName)
    }
    /// Pair from a scanned QR payload; also pins the host key against the QR fingerprint.
    @discardableResult
    public func pair(qr: PairingQRPayload, deviceName: String = "Lantern") async throws -> PairedInfo {
        // The QR carries the secret and the host's fingerprint.
        try await beginPairing(credential: qr.secret, qr: qr, name: deviceName)
    }

    /// Reconnect to an already-paired host with Noise_IK. `hostPublicKey` may be omitted if exactly one host is stored.
    public func connect(hostPublicKey: Data? = nil) async throws {
        // Look up the stored host record(s).
        let peers = try keyStore.peers()
        // Choose which host to use: the one given, or the only one stored; otherwise throw notPaired.
        let rec: PairedPeerRecord
        if let k = hostPublicKey { guard let r = peers.first(where: { $0.publicKey == k }) else { throw LanternNetError.notPaired }; rec = r }
        else { guard peers.count == 1, let r = peers.first else { throw LanternNetError.notPaired }; rec = r }
        // Load our own key, then prepare the Noise IK handshake knowing the host's public key in advance.
        let sk = try keyStore.loadOrCreateDeviceKey()
        let hs = try NoiseHandshake(pattern: .ik, role: .initiator, staticKey: sk,
                                    remoteStatic: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rec.publicKey),
                                    prologue: NetCrypto.prologue)
        // Start it on the owning queue and wait for the result (throws on failure).
        _ = try await run { self.phase = .ik(hs: hs, hostPub: rec.publicKey, hostName: rec.name) }
    }

    /// Shared by both pair() versions.
    private func beginPairing(credential: Data, qr: PairingQRPayload?, name: String) async throws -> PairedInfo {
        // Our long-term key.
        let sk = try keyStore.loadOrCreateDeviceKey()
        // Noise XX handshake using the pairing code (turned into a pre-shared key) so only someone who knows the code can complete it.
        let hs = try NoiseHandshake(pattern: .xxPsk3, role: .initiator, staticKey: sk,
                                    psk: NetCrypto.psk(fromCredential: credential), prologue: NetCrypto.prologue)
        // Remember our name, switch to the first pairing phase, and wait for the handshake to finish.
        let info = try await run { self.deviceName = name; self.phase = .pairM1(hs: hs, qr: qr) }
        // pair always expects host info back.
        guard let info else { throw LanternNetError.closed }
        return info
    }

    /// Common start for pairing and reconnecting: check we are idle, run `setup`, open the UDP socket, start the timer, and wait until the handshake completes.
    private func run(_ setup: @escaping @Sendable () -> Void) async throws -> PairedInfo? {
        // Only start if nothing is in progress or established; otherwise throw busy.
        let ok: Bool = q.sync { if case .idle = phase { return true }; if case .established = phase { return false }; return false }
        guard ok else { throw LanternNetError.busy }
        // Bridge callback-style code to async/await: the call suspends here until `completion` is invoked.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PairedInfo?, Error>) in
            q.async {
                // Run the caller's setup (sets the phase).
                setup()
                // Save the callback to resume the waiter later.
                self.completion = { cont.resume(with: $0) }
                // Note the start time for the timeout.
                self.startedAt = self.clock()
                // Tell the app we are handshaking.
                self.setState(.handshaking)
                // Open a UDP connection to the host.
                let c = NWConnection(host: NWEndpoint.Host(self.host), port: NWEndpoint.Port(rawValue: self.port) ?? .any, using: .udp)
                self.conn = c
                // React to network state changes; ignore ones for an old connection.
                c.stateUpdateHandler = { [weak self, weak c] st in
                    guard let self, let c, self.conn === c else { return }
                    switch st {
                    // Ready: send the first handshake packet.
                    case .ready: self.sendInitial()
                    // Failed or waiting: record the OS reason, then report a timeout error.
                    case .failed(let e): self.lastNetworkError = "failed: \(e)"; self.fail(LanternNetError.timedOut)
                    case .waiting(let e): self.lastNetworkError = "waiting: \(e)"; self.fail(LanternNetError.timedOut)
                    default: break
                    }
                }
                // Start the connection; begin reading and start the timer.
                c.start(queue: self.q)
                self.receiveLoop(c)
                self.startTimer()
            }
        }
    }

    // MARK: session I/O

    /// Send an input event (tap or drag) to the host. Throws if there is no established session.
    public func send(input e: InputEvent) throws {
        try q.sync {
            guard case .established(var s) = phase, let c = conn else { throw LanternNetError.notEstablished }
            // Unreliable and stamped: a stalled link must never replay old taps (docs/03 rule 3). Only dragEnd
            // (which releases a held button and is harmless when late) stays reliable.
            // 32-bit send-time stamp taken from the monotonic clock; the host uses it to ignore stale input.
            let stamp = UInt32(truncatingIfNeeded: inputClockMs())
            // d = the encrypted datagram to send.
            let d: Data
            // dragEnd is reliable (ACK + retransmit); everything else is sent once.
            if case .dragEnd = e { d = try s.reliable(.input(e), now: clock(), sentMs: stamp) }
            else { d = try s.unreliable(.input(e), sentMs: stamp) }
            // Store the updated session (a struct is copied) and transmit.
            phase = .established(s); transmit(d, on: c)
        }
    }
    /// Sender monotonic clock (ms) stamped on INPUT. Settable for tests; set before connecting.
    public var inputClockMs: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
    /// Send a control message reliably (ACK + retransmit). Throws if not established.
    public func send(control m: ControlMessage) throws {
        try q.sync {
            guard case .established(var s) = phase, let c = conn else { throw LanternNetError.notEstablished }
            let d = try s.reliable(.control(m), now: clock()); phase = .established(s); transmit(d, on: c)
        }
    }
    /// Ask the host for a keyframe (REQUEST_IDR, delivered to the host's `onControl`). For decoders that
    /// lost sync. Rate-limited to `NetConfig.keyframeRequestMinInterval`. Returns true if sent, false if
    /// not established or suppressed by the limiter.
    @discardableResult
    public func requestKeyframe() -> Bool { q.sync { sendKeyframeRequest(now: clock()) } }

    /// Returns false unless established, the minimum interval has passed and the message could be built.
    private func sendKeyframeRequest(now: Date) -> Bool {
        guard case .established(var s) = phase, let c = conn,
              now.timeIntervalSince(lastKeyframeRequest) >= cfg.keyframeRequestMinInterval,
              let d = try? s.reliable(.control(.requestIDR), now: now) else { return false }
        // Record the time and send.
        lastKeyframeRequest = now
        phase = .established(s); transmit(d, on: c)
        return true
    }

    /// Send BYE and close.
    /// Tell the host goodbye (twice, since UDP can lose one), then close locally.
    public func disconnect() {
        q.sync {
            if case .established(var s) = phase, let c = conn, let b = try? s.unreliable(.control(.bye)) {
                transmit(b, on: c); transmit(b, on: c)
            }
            finish(.localClose)
        }
    }

    // MARK: internals (on q)

    /// Announce a state change only when it differs from the last one.
    private func setState(_ s: SessionState) {
        guard s != published else { return }
        published = s
        _onState.get()?(s); stateBus.yield(s)
    }

    /// Send a datagram through the test filter (if any); the filter may drop or duplicate it.
    private func transmit(_ d: Data, on c: NWConnection) {
        let outs = _filter.get()?(d) ?? [d]
        for o in outs { c.send(content: o, completion: .idempotent) }
    }

    /// Send a handshake packet and remember it (and when) for re-sending.
    private func sendHandshake(_ d: Data) {
        lastSent = d; lastSentAt = clock()
        if let c = conn { transmit(d, on: c) }
    }

    /// Send the first handshake message for the current phase.
    private func sendInitial() {
        switch phase {
        // Pairing: write Noise message 1 (48 bytes expected), frame it, pad it with zeros so the host's reply is never bigger than the request, send.
        case .pairM1(var hs, let qr):
            guard let out = try? hs.writeMessage(Data()), out.count == 48 else { fail(LanternNetError.closed); return }
            phase = .pairM1(hs: hs, qr: qr)
            guard let w = try? FrameCodec.encode(.pairM1(eAndTag: Array(out))) else { fail(LanternNetError.closed); return }
            sendHandshake(PairM1Padding.pad(w))
        // Reconnect: write the IK message carrying a timestamp (104 bytes expected) so the host can reject replays.
        case .ik(var hs, let pub, let name):
            guard let out = try? hs.writeMessage(NetCrypto.timestampPayload(clock())), out.count == 104,
                  let w = try? FrameCodec.encode(.ikM1(e: Array(out[0..<32]), encS: Array(out[32..<80]), encTs: Array(out[80...]))) else { fail(LanternNetError.closed); return }
            phase = .ik(hs: hs, hostPub: pub, hostName: name); sendHandshake(w)
        // Other phases send nothing.
        default: break
        }
    }

    /// Read one datagram at a time; handle it, then ask for the next.
    private func receiveLoop(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            // Ignore callbacks from an old connection.
            guard let self, let c, self.conn === c else { return }
            // Non-empty data goes to `handle`.
            if let data, !data.isEmpty { self.handle(data, conn: c) }
            // Keep reading unless there was an error.
            if error == nil { self.receiveLoop(c) }
        }
    }

    /// Process one incoming datagram according to the current phase.
    private func handle(_ data: Data, conn c: NWConnection) {
        let now = clock()
        // Not a valid frame: count and ignore.
        guard let msg = try? FrameCodec.decode(data) else { handshakeStats.malformedDrops += 1; return }
        // The part after the fixed header.
        let body = Data(data.dropFirst(FrameCodec.headerSize))
        // Decide by (current phase, message type) pairs.
        switch (phase, msg) {
        // Pairing step 2: the host answered our first message.
        case (.pairM1(var hs, let qr), .pairM2):
            // Read it; this also reveals the host's public key.
            guard let payload = try? hs.readMessage(body), let rs = hs.remoteStaticPublicKey?.rawRepresentation else { return }
            // If we scanned a QR, the host key must match its fingerprint; a mismatch means a different (possibly fake) host.
            if let qr, !qr.matchesHostKey(rs) { fail(LanternNetError.hostKeyMismatch); return }
            // Write pairing message 3 (carrying our name) and derive the session keys.
            guard let out = try? hs.writeMessage(NetCrypto.nameBytes(deviceName)), out.count >= 48 + 16,
                  let w = try? FrameCodec.encode(.pairM3(encS: Array(out[0..<48]), encPayload: Array(out[48...]))),
                  let (send, recv) = try? hs.split() else { fail(LanternNetError.closed); return }
            // Create the encrypted session; keep it ready until the host confirms.
            let sess = SecureSession(send: send, receive: recv, sessionID: NetCrypto.sessionID(handshakeHash: hs.handshakeHash), config: cfg, now: now)
            // Remember who we paired with and the short code both screens can show.
            phase = .pairM3(session: sess, hostPub: rs, hostName: String(decoding: payload.prefix(64), as: UTF8.self),
                            sas: SAS.derive(handshakeHash: hs.handshakeHash))
            // Send message 3.
            sendHandshake(w)
        // The host rejected us because it is rate-limiting handshakes. A wrong or expired code gets no reply, so it surfaces as timedOut.
        case (.pairM1, .reject), (.pairM3, .reject):
            fail(LanternNetError.rejected)
        // Pairing step 3: first encrypted packet from the host confirms success.
        case (.pairM3(var sess, let hostPub, let hostName, let sas), .data):
            // Decrypt/check it with the new session.
            let r = sess.receive(data, now: now)
            // If it failed checks, keep waiting.
            guard r.drop == nil else { phase = .pairM3(session: sess, hostPub: hostPub, hostName: hostName, sas: sas); return }
            // Save the host as a paired device.
            do { try keyStore.addPeer(PairedPeerRecord(name: hostName, publicKey: hostPub, pairedAt: now)) }
            catch { fail(error); return }
            // Now fully connected.
            phase = .established(sess)
            // Announce established and finish the waiting pair() call.
            established(hostPub: hostPub, info: PairedInfo(name: hostName, peerTag: peerTag(hostPub), sas: sas))
            // Process any messages that came with it.
            afterReceive(r, conn: c, now: now)
        // Reconnect: the host answered our IK message.
        case (.ik(var hs, let hostPub, _), .ikM2):
            // Finish the handshake and derive keys; if it does not verify, ignore it.
            guard (try? hs.readMessage(body)) != nil, let (send, recv) = try? hs.split() else { return }
            let sess = SecureSession(send: send, receive: recv, sessionID: NetCrypto.sessionID(handshakeHash: hs.handshakeHash), config: cfg, now: now)
            // Connected.
            phase = .established(sess)
            established(hostPub: hostPub, info: nil)
        // Normal traffic once connected.
        case (.established(var sess), .data):
            let r = sess.receive(data, now: now)
            phase = .established(sess)
            afterReceive(r, conn: c, now: now)
        // Anything else does not fit the current phase: count it.
        default:
            handshakeStats.malformedDrops += 1
        }
    }

    /// Announce the connected state and resume the waiting pair()/connect() call (`info` is nil for reconnects).
    private func established(hostPub: Data, info: PairedInfo?) {
        setState(.established(peerTag: peerTag(hostPub)))
        let cb = completion; completion = nil
        cb?(.success(info))
    }

    /// Deal with what `receive` produced: send replies, hand video/control up, react to BYE.
    private func afterReceive(_ r: SecureSession.Result, conn c: NWConnection, now: Date) {
        // Send ACKs etc.
        for d in r.replies { transmit(d, on: c) }
        for item in r.delivered {
            switch item {
            // Video: give it to the callback and the stream.
            case .video(let f): _onVideo.get()?(f.data, f.isKeyframe); videoBus.yield(f)
            // Control: same.
            case .control(let m): _onControl.get()?(m); controlBus.yield(m)
            // Host said goodbye: close.
            case .bye: finish(.peerBye); return
            // Input events are ignored on the client side (nothing to do with them here).
            case .input: break
            }
        }
        // If video re-assembly saw a gap, ask the host for a fresh keyframe.
        if r.wantKeyframe { _ = sendKeyframeRequest(now: now) }
    }

    /// Create a repeating timer on the queue that calls onTick every `tick` seconds.
    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + cfg.tick, repeating: cfg.tick)
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume(); timer = t
    }

    /// Timer tick: handshake timeout/retransmit, or session keepalive/retransmit.
    private func onTick() {
        let now = clock()
        switch phase {
        // Nothing to do.
        case .idle: break
        case .pairM1, .pairM3, .ik:
            // Handshake phases: give up after the timeout.
            if now.timeIntervalSince(startedAt) > cfg.handshakeTimeout { fail(LanternNetError.timedOut); return }
            // Otherwise re-send the last handshake packet if it is time (UDP may have lost it).
            if now.timeIntervalSince(lastSentAt) >= cfg.handshakeRetransmit, !lastSent.isEmpty { sendHandshake(lastSent) }
        // Established: let the session do its retransmits/keepalives and check for failure or silence.
        case .established(var s):
            let t = s.tick(now: now)
            phase = .established(s)
            if let c = conn { for d in t.datagrams { transmit(d, on: c) } }
            if t.failed { finish(.retransmitFailed) } else if t.idle { finish(.idleTimeout) }
        }
    }

    /// Handshake or setup failed: end the attempt, mark closed, tell the waiting caller.
    private func fail(_ e: Error) {
        let cb = completion; completion = nil
        resetTransport()
        setState(.closed(.handshakeFailed))
        cb?(.failure(e))
    }

    /// Connection ended after being up (or in progress): save counters, reset, announce closed, resolve any waiting caller with an error.
    private func finish(_ r: CloseReason) {
        if case .established(let s) = phase {
            closedStats.replayDrops += s.stats.replayDrops; closedStats.authDrops += s.stats.authDrops
            closedStats.malformedDrops += s.stats.malformedDrops; closedStats.wrongSessionDrops += s.stats.wrongSessionDrops
            closedStats.retransmits += s.stats.retransmits
        }
        let cb = completion; completion = nil
        resetTransport()
        setState(.closed(r))
        cb?(.failure(LanternNetError.closed))
    }

    /// Stop the timer, forget the connection and phase, and cancel the socket after a short delay.
    private func resetTransport() {
        timer?.cancel(); timer = nil
        let c = conn; conn = nil
        phase = .idle; lastSent = Data()
        // grace so a just-sent BYE leaves the socket
        if let c { q.asyncAfter(deadline: .now() + 0.05) { c.cancel() } }
    }
}
