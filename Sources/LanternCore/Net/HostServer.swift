// =====================================================================================
// HostServer.swift
//
// PURPOSE: The "host" side of the encrypted UDP link (the computer that shares its stream).
// It listens on one local network address, lets a new device pair with a short code, lets an
// already-paired device reconnect, then sends video and receives input/control messages.
//
// WHO CALLS IT: the app or command-line host that owns the stream calls start / stop /
// beginPairing / sendVideoFrame / send(control:) and sets the on... callbacks. ClientConnection
// (the other end) talks to it over the network.
//
// KEY IDEAS FOR A BEGINNER:
//  - UDP: send independent packets with no connection. Network.framework's NWListener hands us an
//    NWConnection per remote sender (address + port), which is how we tell senders apart.
//  - Concurrency: ALL mutable state lives on one serial dispatch queue `q` (one task at a time),
//    so we need no locks for it. Public functions hop onto `q` with q.sync / q.async.
//  - Pairing (Noise XX with a pre-shared key): both sides prove they know the pairing code and
//    swap public keys; the host saves the new device's key. Later reconnects use Noise IK, where the
//    client already knows the host key and the host already knows the client key.
//  - Defences: handshake rate limits, a cap on half-finished handshakes, silent drops for
//    unknown senders, anti-replay timestamps, and one client at a time.
// =====================================================================================

import Foundation
// CryptoKit: SHA-256 hashing. Network: NWListener / NWConnection (Apple's networking API).
import CryptoKit
import Network

/// What the host tells the app when a device has just paired.
public struct PairedInfo: Sendable, Equatable {
    /// Display name the other device gave (already cleaned).
    public var name: String
    /// Short fingerprint of the other device's public key.
    public var peerTag: String
    public var sas: String          // compare with the client's SAS
}

/// Encrypted UDP host endpoint. OFF by default: nothing binds until `start` is called.
/// Binds only to the single local address given (wildcards refused). Callbacks run on an internal
/// serial queue; keep them short. Never logs keys, codes or full peer identifiers.
/// How this works: one listener, one optional active session, plus bookkeeping for half-open handshakes and rate limits.
public final class HostServer: @unchecked Sendable {
    /// The single serial queue that owns all mutable state below. Network callbacks are also delivered on it.
    private let q = DispatchQueue(label: "org.twu.lantern.host")
    /// Where this device's long-term key and the list of paired devices are stored.
    private let keyStore: KeyStore
    /// Tuning numbers (timeouts, limits).
    private let cfg: NetConfig
    /// Source of "now"; tests can replace it with a fake clock.
    private let clock: @Sendable () -> Date

    // callbacks (set before start; replaceable at any time)
    /// Each callback sits in a LockedBox so it can be read and replaced safely from any thread.
    private let _onInput = LockedBox<(@Sendable (InputEvent) -> Void)?>(nil)
    private let _onControl = LockedBox<(@Sendable (ControlMessage) -> Void)?>(nil)
    private let _onState = LockedBox<(@Sendable (HostServerState) -> Void)?>(nil)
    private let _onSession = LockedBox<(@Sendable (SessionState) -> Void)?>(nil)
    private let _onPaired = LockedBox<(@Sendable (PairedInfo) -> Void)?>(nil)
    private let _onRelease = LockedBox<(@Sendable ([HeldButton]) -> Void)?>(nil)
    private let _filter = LockedBox<DatagramFilter?>(nil)
    /// Public properties that read/write the boxes above. The app assigns closures here to be told about events.
    public var onInput: (@Sendable (InputEvent) -> Void)? { get { _onInput.get() } set { _onInput.set(newValue) } }
    public var onControl: (@Sendable (ControlMessage) -> Void)? { get { _onControl.get() } set { _onControl.set(newValue) } }
    public var onStateChange: (@Sendable (HostServerState) -> Void)? { get { _onState.get() } set { _onState.set(newValue) } }
    public var onSessionStateChange: (@Sendable (SessionState) -> Void)? { get { _onSession.get() } set { _onSession.set(newValue) } }
    public var onPaired: (@Sendable (PairedInfo) -> Void)? { get { _onPaired.get() } set { _onPaired.set(newValue) } }
    /// Buttons that must be released on disconnect (from HostInputGate.releaseAll).
    public var onHeldButtonsReleased: (@Sendable ([HeldButton]) -> Void)? { get { _onRelease.get() } set { _onRelease.set(newValue) } }
    /// Test/fault-injection hook applied to every outbound datagram.
    public var outboundFilter: DatagramFilter? { get { _filter.get() } set { _filter.set(newValue) } }

    /// Broadcasters feed the AsyncStream versions of the same events (for `for await` loops).
    private let inputBus = Broadcaster<InputEvent>()
    private let stateBus = Broadcaster<HostServerState>()
    /// Each call returns a fresh stream; every stream sees every later event.
    public var inputEvents: AsyncStream<InputEvent> { inputBus.stream() }
    public var stateChanges: AsyncStream<HostServerState> { stateBus.stream() }

    // state, only touched on q
    /// Tiny flag box, shared with the listener's callback so the start continuation resumes only once.
    private final class Once: @unchecked Sendable { var done = false }
    /// A half-finished pairing handshake: Noise state, the exact M1/M2 packets (to answer retransmits identically), creation time, sender IP.
    private struct Pending { var hs: NoiseHandshake; var m1: Data; var m2: Data; var created: Date; var ip: String }
    /// The one live session: its sender key, connection, encrypted session, the client's public key, the last handshake packet and our reply to it (so a repeated handshake gets the same answer), and a gate that checks input.
    private struct Active {
        var key: String; var conn: NWConnection; var session: SecureSession
        var peerPub: Data; var lastInit: Data; var cachedReply: Data; var gate = HostInputGate()
    }
    /// The UDP listener; nil when not listening.
    private var listener: NWListener?
    /// The port actually bound (useful when 0 = "pick any" was requested).
    private var boundPort: UInt16 = 0
    /// Repeating timer that drives retransmits, expiry and clean-up.
    private var timer: DispatchSourceTimer?
    /// Every remote sender we currently hold a connection for, with the time we last heard from it.
    private var conns: [String: (conn: NWConnection, last: Date)] = [:]
    /// Pairing handshakes in progress, keyed by sender.
    private var pending: [String: Pending] = [:]
    /// Rules for the pairing code (lifetime, single use, failure lock).
    private var policy: PairingPolicy
    /// The connected client, if any.
    private var active: Active?
    /// Recent handshake attempt times per source IP (rate limit).
    private var rate: [String: [Date]] = [:]
    /// Recent handshake attempt times across all sources (global rate limit).
    private var globalHandshakes: [Date] = []
    /// How many wrong-code attempts each source IP has used on the current code.
    private var pairFailuresBySource: [String: Int] = [:]
    /// Fingerprints of reconnect handshakes already seen, to refuse replays.
    private var seenIK: [Data: Date] = [:]
    /// True after the kill switch; start() refuses until it is reset.
    private var killed = false
    /// Last state reported to the app, so we only announce changes.
    private var lastPublished: HostServerState = .stopped
    /// Counters for packets dropped outside an active session.
    private var serverStats = NetStats()
    /// Counters carried over from sessions that already ended.
    private var closedStats = NetStats()
    /// Lets stop() wait until the socket is really closed.
    private var stoppedWaiter: CheckedContinuation<Void, Never>?

    /// Create a host. Nothing binds or listens yet: that happens only when `start` is called.
    public init(keyStore: KeyStore, config: NetConfig = NetConfig(), clock: @escaping @Sendable () -> Date = { Date() }) {
        // Store the dependencies.
        self.keyStore = keyStore; self.cfg = config; self.clock = clock
        // Build the pairing policy using the same clock and the configured code lifetime.
        self.policy = PairingPolicy(now: clock, codeLifetime: config.pairingCodeLifetime)
    }

    // MARK: public control

    /// These read-only properties use q.sync so they read state on the owning queue (a consistent snapshot).
    public var isListening: Bool { q.sync { listener != nil } }
    public var killSwitchEngaged: Bool { q.sync { killed } }
    public var port: UInt16 { q.sync { boundPort } }
    public var state: HostServerState { q.sync { computeState() } }
    /// Total counters: server-level ones plus those of ended sessions plus the current session.
    public var stats: NetStats {
        q.sync {
            // Start from the server counters, then add the session counters.
            var s = serverStats
            let parts = [closedStats, active?.session.stats ?? NetStats()]
            for p in parts {
                s.replayDrops += p.replayDrops; s.authDrops += p.authDrops; s.malformedDrops += p.malformedDrops
                s.wrongSessionDrops += p.wrongSessionDrops; s.retransmits += p.retransmits
            }
            return s
        }
    }
    /// The host's own public key (raw bytes), creating the key on first use. Clients pin this key via the QR code.
    public func publicKey() throws -> Data { try keyStore.loadOrCreateDeviceKey().publicKey.rawRepresentation }

    /// Bind to exactly `bindAddress` (IPv4/IPv6 literal, not a wildcard). Returns the bound port
    /// (pass 0 for an ephemeral port).
    /// (How it works: validate the address, create the UDP listener, wait until the OS says it is ready or failed.)
    @discardableResult
    public func start(bindAddress: String, port: UInt16) async throws -> UInt16 {
        // Refuse wildcard/public/invalid addresses (throws).
        let host = try BindCheck.parse(bindAddress)
        // Check on the queue that the kill switch is off and we are not already listening.
        try q.sync {
            if killed { throw LanternNetError.killSwitchEngaged }
            if listener != nil { throw LanternNetError.alreadyRunning }
        }
        // Make sure the long-term device key exists before accepting anyone.
        _ = try keyStore.loadOrCreateDeviceKey()
        // UDP parameters; the service class hints to the OS that this is interactive video (low latency).
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        // Pin the listener to exactly the chosen address and port (0 means any free port).
        params.requiredLocalEndpoint = .hostPort(host: host, port: port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any))
        // Create the listener; wrap any OS error in our own error type.
        let l: NWListener
        do { l = try NWListener(using: params) } catch { throw LanternNetError.listenerFailed("\(error)") }
        // `once` stops the continuation being resumed twice, since the state handler can fire repeatedly.
        let once = Once()
        // Bridge callback-style code to async/await: we wait here until the listener is ready or failed.
        let result: UInt16 = try await withCheckedThrowingContinuation { cont in
            q.async {
                // Everything below is set up on the owning queue.
                self.listener = l
                // Each new remote sender produces a connection; `accept` registers it. [weak self] avoids a retain cycle.
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                // React to listener life-cycle changes.
                l.stateUpdateHandler = { [weak self] st in
                    switch st {
                    // Ready: record the port, start the timer, announce the new state and return the port to the caller.
                    case .ready:
                        if !once.done {
                            once.done = true
                            self?.boundPort = l.port?.rawValue ?? port
                            self?.startTimer()
                            self?.publish()
                            cont.resume(returning: l.port?.rawValue ?? port)
                        }
                    // Failed or waiting: report the error to start() if it is still waiting, then shut down.
                    case .failed(let e):
                        if !once.done { once.done = true; cont.resume(throwing: LanternNetError.listenerFailed("\(e)")) }
                        self?.listenerDied("listener failed")
                    case .waiting(let e):
                        if !once.done { once.done = true; cont.resume(throwing: LanternNetError.listenerFailed("\(e)")) }
                        self?.listenerDied("listener waiting")
                    // Cancelled: unblock stop() if it is waiting.
                    case .cancelled:
                        self?.stoppedWaiter?.resume(); self?.stoppedWaiter = nil
                    default: break
                    }
                }
                // Begin listening; all callbacks arrive on `q`.
                l.start(queue: self.q)
            }
        }
        return result
    }

    /// Stop listening, drop all connections, wipe any open pairing code. Returns after the socket is closed.
    public func stop() async {
        // Bridge to async/await again: resume when the socket is closed.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            q.async {
                // Not listening: nothing to stop.
                guard let l = self.listener else { c.resume(); return }
                // Remember who to wake when the listener reports it is cancelled.
                self.stoppedWaiter = c
                // Ask the client to hang up (BYE is sent twice because UDP can lose one).
                self.closeSession(.serverStopped, sendBye: true)
                // brief grace so the BYE datagrams leave the socket before it is torn down
                self.q.asyncAfter(deadline: .now() + 0.05) {
                    // Drop everything and forget the session; then cancel the listener.
                    self.teardown(reason: .serverStopped, sendBye: false)
                    self.listener = nil
                    // Replace the state handler so only the cancelled event is handled from now on.
                    l.stateUpdateHandler = { [weak self] st in
                        if case .cancelled = st { self?.stoppedWaiter?.resume(); self?.stoppedWaiter = nil }
                    }
                    l.cancel()
                    // Announce the stopped state.
                    self.publish()
                }
            }
        }
    }

    /// Immediate hard stop: no BYE, no waiting, refuses `start` until `resetKillSwitch()`.
    public func killSwitch() {
        q.sync {
            // Remember the switch is engaged so `start` is refused.
            killed = true
            // No BYE and no grace period: shut down immediately.
            teardown(reason: .killSwitch, sendBye: false)
            listener?.cancel(); listener = nil
            publish()
        }
    }
    /// Re-allow start() after the kill switch.
    public func resetKillSwitch() { q.sync { killed = false } }

    // MARK: pairing mode

    /// Open pairing mode with a fresh 10-char code (120 s, single use, 5 failures lock).
    public func beginPairing() throws -> PairingCode {
        try q.sync {
            // Pairing needs a running listener.
            guard listener != nil, !killed else { throw LanternNetError.notEstablished }
            // Fresh code: reset per-source failure counts, ask the policy for a code, publish the state change.
            pairFailuresBySource.removeAll(); let c = policy.begin(); publish(); return c
        }
    }
    /// Same as beginPairing but returns a QR payload (host key, address hint and secret) for the other device to scan.
    public func beginPairingQR(addressHint: String) throws -> PairingQRPayload {
        try q.sync {
            guard listener != nil, !killed else { throw LanternNetError.notEstablished }
            // Public key to embed so the scanner can verify it reached the real host.
            let pk = try keyStore.loadOrCreateDeviceKey().publicKey.rawRepresentation
            pairFailuresBySource.removeAll(); let p = policy.beginQR(hostPublicKey: pk, addressHint: addressHint); publish(); return p
        }
    }
    /// Close the pairing window and discard the code.
    public func cancelPairing() { q.sync { policy.cancel(); publish() } }
    /// Current pairing state (open/closed, expiry etc.).
    public var pairingState: PairingState { q.sync { policy.state } }

    // MARK: session I/O

    /// Send one encoded video frame (Annex-B access unit), fragmented, lossy.
    public func sendVideoFrame(_ annexB: Data, isKeyframe: Bool, ptsUs: UInt64) throws {
        // Fragments are sent in small bursts with a short pause between them, and the server queue is released
        // between bursts so incoming taps are never stuck behind a big keyframe. A whole keyframe in one burst
        // overflows Wi-Fi buffers, loses packets and triggers another keyframe (latency review 2026-11-18).
        // Under the queue: make sure a session exists and encrypt/fragment the frame; copy the session back because it is a struct (a value type).
        let (ds, conn): ([Data], NWConnection) = try q.sync {
            guard var a = active else { throw LanternNetError.notEstablished }
            let ds = try a.session.videoFrame(annexB, isKeyframe: isKeyframe, ptsUs: ptsUs)
            active = a
            return (ds, a.conn)
        }
        // Send at most 6 fragments, then pause 0.8 ms.
        let burst = 6
        var i = 0
        while i < ds.count {
            let end = min(i + burst, ds.count)
            // Re-enter the queue for each burst so other work (incoming input) can interleave.
            q.sync { for d in ds[i..<end] { transmit(d, on: conn) } }
            i = end
            // Pause only between bursts, and only if there is more than one burst.
            if i < ds.count && ds.count > burst { usleep(800) }
        }
    }
    /// Reliable control message (windowInfo, bitrate, requestIDR...).
    public func send(control: ControlMessage) throws {
        try q.sync {
            // Needs a live session. The message is queued for reliable delivery (ACK + retransmit) and sent.
            guard var a = active else { throw LanternNetError.notEstablished }
            let d = try a.session.reliable(.control(control), now: clock())
            active = a
            transmit(d, on: a.conn)
        }
    }
    /// Ask the connected client to leave, sending BYE.
    public func disconnectClient() { q.sync { closeSession(.localClose, sendBye: true) } }

    // MARK: internals (on q)

    /// Work out the state from the facts: stopped, session active, pairing open or just listening.
    private func computeState() -> HostServerState {
        guard listener != nil else { return .stopped }
        if let a = active { return .sessionActive(peerTag: peerTag(a.peerPub)) }
        if policy.isActive { return .pairingOpen(port: boundPort) }
        return .listening(port: boundPort)
    }
    /// Tell the app about a state change, but only if it differs from the last one reported.
    private func publish() {
        let s = computeState()
        guard s != lastPublished else { return }
        lastPublished = s
        _onState.get()?(s); stateBus.yield(s)
    }
    /// The OS listener failed: clean up everything and report `failed`.
    private func listenerDied(_ why: String) {
        teardown(reason: .serverStopped, sendBye: false)
        listener?.cancel(); listener = nil
        let s = HostServerState.failed(why); lastPublished = s
        _onState.get()?(s); stateBus.yield(s)
    }

    /// Create a repeating timer on the queue that calls onTick every `tick` seconds.
    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + cfg.tick, repeating: cfg.tick)
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume(); timer = t
    }

    /// Close the session, all connections, and forget every handshake, limit table and the pairing code; stop the timer.
    private func teardown(reason: CloseReason, sendBye: Bool) {
        closeSession(reason, sendBye: sendBye)
        for (_, c) in conns { c.conn.cancel() }
        conns.removeAll(); pending.removeAll(); rate.removeAll(); seenIK.removeAll()
        globalHandshakes.removeAll(); pairFailuresBySource.removeAll()
        policy.cancel()
        timer?.cancel(); timer = nil
    }

    /// A new remote sender appeared (called on q).
    private func accept(_ c: NWConnection) {
        // Handler already runs on q.
        // Identify the sender by its address and port.
        let key = BindCheck.sourceKey(c.endpoint)
        let now = clock()
        // Safety cap: never hold more than 64 connections.
        if conns.count >= 64 {
            // evict the stalest non-session connection
            if let victim = conns.filter({ $0.key != active?.key }).min(by: { $0.value.last < $1.value.last }) {
                victim.value.conn.cancel(); conns[victim.key] = nil
            } else { c.cancel(); return }
        }
        // If this sender already had a connection, close the old one and keep the new one.
        conns[key]?.conn.cancel()
        conns[key] = (c, now)
        // When a connection fails or is cancelled, forget it (only if it is still the registered one).
        c.stateUpdateHandler = { [weak self, weak c] st in
            switch st {
            case .failed, .cancelled:
                guard let self, let c else { return }
                if self.conns[key]?.conn === c { self.conns[key] = nil }
            default: break
            }
        }
        // Start the connection and begin reading datagrams from it.
        c.start(queue: q)
        receiveLoop(key, c)
    }

    /// Read one datagram at a time: the callback handles it, then asks for the next one.
    private func receiveLoop(_ key: String, _ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            guard let self, let c else { return }
            // Non-empty data goes to `handle`.
            if let data, !data.isEmpty { self.handle(data, key: key, conn: c) }
            // Keep looping unless there was an error or this connection was replaced.
            if error == nil, self.conns[key]?.conn === c { self.receiveLoop(key, c) }
        }
    }

    /// Send one datagram. The test filter may drop or duplicate it. `.idempotent` = we do not need a completion result (UDP is fire-and-forget).
    func transmit(_ d: Data, on c: NWConnection) {
        let outs = _filter.get()?(d) ?? [d]
        for o in outs { c.send(content: o, completion: .idempotent) }
    }

    /// Returns true if this handshake attempt is within the rate limits, and records it.
    private func allowHandshake(_ source: String, now: Date) -> Bool {
        // Global budget first (spoofed/many sources cannot exceed it), then the per-source budget.
        // Forget global attempts older than 1 second.
        globalHandshakes.removeAll { now.timeIntervalSince($0) >= 1 }
        guard globalHandshakes.count < cfg.maxHandshakesPerSecondGlobal else { return false }
        // Keep only this source's attempts inside the window.
        var l = (rate[source] ?? []).filter { now.timeIntervalSince($0) < cfg.handshakeWindow }
        guard l.count < cfg.maxHandshakesPerWindow else { rate[source] = l; return false }
        l.append(now); rate[source] = l
        globalHandshakes.append(now)
        return true
    }

    /// Optional diagnostics (host CLI `--debug`): one short line per source per second for any datagram that arrives. No payload.
    /// (Used with `onDebug` below; `lastDebugAt` rate-limits it to one line per sender per second.)
    public var onDebug: (@Sendable (String) -> Void)?
    private var lastDebugAt: [String: Date] = [:]

    /// Entry point for every datagram received. Decides what kind of packet it is and routes it.
    private func handle(_ data: Data, key: String, conn: NWConnection) {
        // Ignore everything unless listening and not killed.
        guard listener != nil, !killed else { return }
        let now = clock()
        if let d = onDebug, now.timeIntervalSince(lastDebugAt[key] ?? .distantPast) >= 1 { lastDebugAt[key] = now; d("datagram from \(key): \(data.count) bytes") }
        // Note when we last heard from this sender (for stale-connection clean-up).
        conns[key]?.last = now
        // A pairing first message may be padded with zeros; strip the padding before parsing.
        let m1 = PairM1Padding.unpad(data)
        // If it is a pairing first message (PAIR_M1)...
        if case .pairM1? = try? FrameCodec.decode(m1) {
            // Same packet as the active session's first handshake: the client repeated it, so repeat our answer.
            if let a = active, a.key == key, a.lastInit == data { transmit(a.cachedReply, on: conn); return }
            // Otherwise check the rate limits; if too busy, reject (a short unauthenticated reply).
            guard allowHandshake(BindCheck.sourceIP(conn.endpoint), now: now) else {
                serverStats.rateLimited += 1
                if let r = try? FrameCodec.encode(.reject) { transmit(r, on: conn) }
                return
            }
            // Within limits: continue the pairing handshake.
            handlePairM1(Data(m1.dropFirst(FrameCodec.headerSize)), raw: data, key: key, conn: conn, now: now)
            return
        }
        // Not M1: try to parse as any other frame; junk is counted and dropped.
        guard let msg = try? FrameCodec.decode(data) else { serverStats.malformedDrops += 1; return }
        // Everything after the fixed header is the message body.
        let body = data.dropFirst(FrameCodec.headerSize)
        let src = BindCheck.sourceIP(conn.endpoint)
        // Route by frame type.
        switch msg {
        case .pairM3:
            // Third pairing message: client proves it knows the code.
            handlePairM3(Data(body), raw: data, key: key, conn: conn, now: now)
        case .ikM1:
            // Reconnect handshake (IK): a repeat gets the same reply; otherwise rate-limit silently.
            if let a = active, a.key == key, a.lastInit == data { transmit(a.cachedReply, on: conn); return }
            guard allowHandshake(src, now: now) else { serverStats.rateLimited += 1; return }   // silent
            handleIK(Data(body), raw: data, key: key, conn: conn, now: now)
        case .data:
            // Encrypted data: only accepted from the current session's sender.
            guard var a = active, a.key == key else { serverStats.wrongSessionDrops += 1; return }
            let r = a.session.receive(data, now: now)
            active = a
            process(r, conn: conn, now: now)
        // Anything else is unexpected at this stage: drop it silently (never reveal anything to strangers).
        default:
            serverStats.silentHandshakeDrops += 1
        }
    }

    private func handlePairM1(_ body: Data, raw: Data, key: String, conn: NWConnection, now: Date) {
        // Needs: no active session and an open pairing code.
        guard active == nil, let cred = policy.activeCredential else { serverStats.silentHandshakeDrops += 1; return }
        // Same M1 again from the same sender: resend the same M2 instead of starting over.
        if let p = pending[key], p.m1 == raw { transmit(p.m2, on: conn); return }   // retransmit
        let ip = BindCheck.sourceIP(conn.endpoint)
        // A source that already burned its authenticated-failure budget is ignored for this code.
        // Too many wrong codes from this IP: ignore it.
        if pairFailuresBySource[ip, default: 0] >= cfg.maxPairFailuresPerSource { serverStats.silentHandshakeDrops += 1; return }
        // Limit how many half-finished handshakes can exist overall and per IP.
        if pending[key] == nil {
            if pending.count >= cfg.maxPendingHandshakes
                || pending.values.filter({ $0.ip == ip }).count >= cfg.maxPendingPerSource {
                serverStats.silentHandshakeDrops += 1; return
            }
        }
        // Build the host side of the Noise XX handshake using the pairing code as the pre-shared key.
        do {
            let sk = try keyStore.loadOrCreateDeviceKey()
            var hs = try NoiseHandshake(pattern: .xxPsk3, role: .responder, staticKey: sk,
                                        psk: NetCrypto.psk(fromCredential: cred), prologue: NetCrypto.prologue)
            // Read the client's M1, then write our reply M2 (carries our device name; Noise encrypts it as needed).
            _ = try hs.readMessage(body)
            let out = Array(try hs.writeMessage(NetCrypto.nameBytes(cfg.deviceName)))
            // Frame the reply: ephemeral key, encrypted static key, encrypted payload.
            let wire = try FrameCodec.encode(.pairM2(e: Array(out[0..<32]), encS: Array(out[32..<80]), encPayload: Array(out[80...])))
            // Anti-amplification: never answer an unauthenticated source with more bytes than it sent.
            guard PairM1Padding.replyAllowed(replyBytes: wire.count, receivedBytes: raw.count) else {
                serverStats.silentHandshakeDrops += 1; return
            }
            // Remember this handshake until M3 arrives (or it times out), then send M2.
            pending[key] = Pending(hs: hs, m1: raw, m2: wire, created: now, ip: ip)
            transmit(wire, on: conn)
        } catch { serverStats.silentHandshakeDrops += 1 }
    }

    /// Third pairing message: verifies the code, stores the new device, starts the session.
    private func handlePairM3(_ body: Data, raw: Data, key: String, conn: NWConnection, now: Date) {
        // Repeated M3 for the session we already created: resend our reply.
        if let a = active, a.key == key, a.lastInit == raw { transmit(a.cachedReply, on: conn); return }
        // Must belong to a handshake in progress.
        guard var p = pending[key] else { serverStats.silentHandshakeDrops += 1; return }
        // Pairing window closed or a session exists: abandon it.
        guard policy.isActive, active == nil else { pending[key] = nil; serverStats.silentHandshakeDrops += 1; return }
        // Try to finish the handshake; this fails if the code was wrong.
        let payload: Data
        do { payload = try p.hs.readMessage(body) }
        catch {
            pending[key] = nil
            // Only a message 3 whose static key authenticated (so the sender really ran this handshake against
            // our ephemeral, from a reachable address) and whose psk-bound payload then failed is a wrong-code
            // attempt. Junk / truncated / replayed M3 never reaches that point and consumes nothing.
            guard p.hs.remoteStaticPublicKey != nil else { serverStats.silentHandshakeDrops += 1; return }
            let n = pairFailuresBySource[p.ip, default: 0]
            guard n < cfg.maxPairFailuresPerSource else { serverStats.silentHandshakeDrops += 1; return }
            pairFailuresBySource[p.ip] = n + 1
            serverStats.failedPairings += 1
            policy.recordFailure()           // 5 counted failures lock the code; one source can supply at most 3
            publish()
            return                            // silent
        }
        // Success: this handshake is done.
        pending[key] = nil
        // Get the client's public key and the two traffic cipher states.
        guard let rs = p.hs.remoteStaticPublicKey?.rawRepresentation, let (send, recv) = try? p.hs.split() else { return }
        // Clean the peer's name before storing or showing it.
        let name = PeerName.sanitize(payload)
        // The code is single use.
        policy.consume()
        // Save the new device in the key store; if that fails, abort.
        do { try keyStore.addPeer(PairedPeerRecord(name: name, publicKey: rs, pairedAt: now)) } catch { return }
        // Short authentication string both screens can show so a human can compare them.
        let sas = SAS.derive(handshakeHash: p.hs.handshakeHash)
        // Create the encrypted session; its id comes from the handshake hash.
        var sess = SecureSession(send: send, receive: recv, sessionID: NetCrypto.sessionID(handshakeHash: p.hs.handshakeHash), config: cfg, now: now)
        // Build the confirmation packet (an encrypted PING) which also proves we derived the same keys.
        guard let confirm = try? sess.unreliable(.control(.ping)) else { return }
        // Activate the session, send confirmation, then tell the app.
        establish(key: key, conn: conn, session: sess, peer: rs, lastInit: raw, reply: confirm)
        transmit(confirm, on: conn)
        let info = PairedInfo(name: name, peerTag: peerTag(rs), sas: sas)
        _onPaired.get()?(info)
    }

    /// Reconnect handshake (Noise IK) for an already-paired device.
    private func handleIK(_ body: Data, raw: Data, key: String, conn: NWConnection, now: Date) {
        /// Small helper that counts a silent drop.
        func drop() { serverStats.silentHandshakeDrops += 1 }
        // Create the handshake and read the client's message; extract its claimed public key.
        guard let sk = try? keyStore.loadOrCreateDeviceKey(),
              var hs = try? NoiseHandshake(pattern: .ik, role: .responder, staticKey: sk, prologue: NetCrypto.prologue),
              let tsData = try? hs.readMessage(body),
              let rs = hs.remoteStaticPublicKey?.rawRepresentation else { drop(); return }
        // Paired devices only.
        guard (try? keyStore.isPaired(publicKey: rs)) == true else { drop(); return }      // unknown peer: silence
        // The timestamp inside must be recent, so old recorded handshakes cannot be replayed.
        guard let ts = NetCrypto.parseTimestamp(tsData), abs(now.timeIntervalSince(ts)) <= cfg.ikTimestampSkew else { drop(); return }
        // Fingerprint of this handshake body, to catch exact repeats.
        let fp = Data(SHA256.hash(data: body))
        // Seen before: replay, drop.
        if seenIK[fp] != nil { drop(); return }
        // Only one client at a time (the same client may reconnect). Constant-time compare avoids leaking timing information.
        if let a = active, !constantTimeEquals(a.peerPub, rs) { drop(); return }            // one client at a time
        // Remember this handshake fingerprint.
        seenIK[fp] = now
        // Write our reply and derive the traffic keys.
        guard let out = try? hs.writeMessage(Data()), out.count == 48,
              let (send, recv) = try? hs.split() else { drop(); return }
        // Frame the reply.
        guard let wire = try? FrameCodec.encode(.ikM2(e: Array(out[0..<32]), encPayload: Array(out[32...]))) else { drop(); return }
        // If the same client reconnects, end the older session first.
        if active != nil { closeSession(.replaced, sendBye: false) }
        // Create the session, activate it, and send the reply.
        let sess = SecureSession(send: send, receive: recv, sessionID: NetCrypto.sessionID(handshakeHash: hs.handshakeHash), config: cfg, now: now)
        establish(key: key, conn: conn, session: sess, peer: rs, lastInit: raw, reply: wire)
        transmit(wire, on: conn)
    }

    /// Make a session active: record it, drop other connections and half-open handshakes, notify the app.
    private func establish(key: String, conn: NWConnection, session: SecureSession, peer: Data, lastInit: Data, reply: Data) {
        active = Active(key: key, conn: conn, session: session, peerPub: peer, lastInit: lastInit, cachedReply: reply)
        // Cancel every other remote connection.
        for (k, c) in conns where k != key { c.conn.cancel(); conns[k] = nil }
        pending.removeAll()
        // Tell the app which peer connected (short tag only).
        let s = SessionState.established(peerTag: peerTag(peer))
        _onSession.get()?(s)
        publish()
    }

    /// Handle what `receive` produced for one datagram.
    private func process(_ r: SecureSession.Result, conn: NWConnection, now: Date) {
        // Send ACKs and other replies.
        for d in r.replies { transmit(d, on: conn) }
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000   // monotonic: input staleness must not follow wall-clock jumps
        // Go through each delivered item.
        for item in r.delivered {
            switch item {
            case .input(let e, let sentMs):
                // Input events pass through the gate, which checks them (for example drops stale ones or tracks held buttons).
                guard var a = active else { continue }
                let ok = a.gate.admit(e, nowMs: nowMs, sentMs: sentMs)
                active = a
                if ok { _onInput.get()?(e); inputBus.yield(e) }
            // Control messages go to the app callback.
            case .control(let c): _onControl.get()?(c)
            // BYE from the client: end the session.
            case .bye: closeSession(.peerBye, sendBye: false)
            // The host does not expect video from the client.
            case .video: break
            }
        }
    }

    /// End the current session (if any), optionally telling the client.
    private func closeSession(_ reason: CloseReason, sendBye: Bool) {
        guard var a = active else { return }
        // BYE is sent twice because UDP can lose packets.
        if sendBye, let b = try? a.session.unreliable(.control(.bye)) {
            transmit(b, on: a.conn); transmit(b, on: a.conn)
        }
        // Ask the gate which buttons are still held so the app can release them.
        let released = a.gate.releaseAll()
        // Keep the session's drop counters before discarding it.
        closedStats.replayDrops += a.session.stats.replayDrops; closedStats.authDrops += a.session.stats.authDrops
        closedStats.malformedDrops += a.session.stats.malformedDrops; closedStats.wrongSessionDrops += a.session.stats.wrongSessionDrops
        closedStats.retransmits += a.session.stats.retransmits
        // Forget the session, then notify listeners.
        active = nil
        _onRelease.get()?(released)
        _onSession.get()?(.closed(reason))
        publish()
    }

    /// Timer tick: expire old state and run the session's own timers.
    private func onTick() {
        let now = clock()
        // Forget half-open handshakes older than the allowed time.
        for (k, p) in pending where now.timeIntervalSince(p.created) > cfg.pendingHandshakeTTL { pending[k] = nil }
        // Forget old reconnect fingerprints (after twice the allowed skew they can no longer pass the timestamp check anyway).
        for (k, t) in seenIK where now.timeIntervalSince(t) > cfg.ikTimestampSkew * 2 { seenIK[k] = nil }
        // Trim old rate-limit entries and remove empty ones.
        for (k, l) in rate { let f = l.filter { now.timeIntervalSince($0) < cfg.handshakeWindow }; rate[k] = f.isEmpty ? nil : f }
        // Close connections idle for over 30 seconds, except the active session's.
        for (k, c) in conns where k != active?.key && now.timeIntervalSince(c.last) > 30 { c.conn.cancel(); conns[k] = nil }
        // Drive the session: retransmits and keepalive; close if retries ran out or the peer went quiet.
        if var a = active {
            let t = a.session.tick(now: now)
            active = a
            for d in t.datagrams { transmit(d, on: a.conn) }
            if t.failed { closeSession(.retransmitFailed, sendBye: false) }
            else if t.idle { closeSession(.idleTimeout, sendBye: false) }
        }
        publish()   // pairing code expiry
    }
}
