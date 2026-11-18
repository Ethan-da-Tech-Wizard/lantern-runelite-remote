// =====================================================================================
// NetSupport.swift
//
// PURPOSE: Small shared building blocks for the encrypted UDP session layer: the error list, the
// session/server state enums, tuning knobs (NetConfig), counters (NetStats), crypto helper values,
// a text sanitiser for peer names, two thread-safe helper classes, the "is this a private address?"
// check used before binding, and the padding rule that stops the host being used for amplification.
//
// WHO CALLS IT: HostServer.swift, ClientConnection.swift and SecureSession.swift (same folder) use
// nearly everything declared here.
//
// KEY IDEAS FOR A BEGINNER:
//  - UDP sends independent little packets ("datagrams"). There is no built-in connection, so this
//    layer builds its own sessions, encryption and retries on top.
//  - Noise is a recipe for two devices to agree on secret keys. A PSK (pre-shared key) is a secret
//    both sides already know (here, derived from the pairing code).
//  - A "peer" is the device on the other end of the link.
// =====================================================================================

import Foundation
// Foundation: Data, Date, UUID, NSLock. CryptoKit: SHA256 and HKDF. Network: IPv4Address, NWEndpoint.
import CryptoKit
import Network

// MARK: Errors, config, small utilities for the UDP session layer.

/// Every error the networking layer can throw. Equatable so tests can compare them; Sendable so they
/// can cross between threads safely.
public enum LanternNetError: Error, Equatable, Sendable {
    /// Bind-address problems: the host refuses to listen on "any" address, on a non-private one, or on text that is not an IP.
    case wildcardBindRefused
    case nonPrivateBindRefused
    case invalidBindAddress
    /// Start-up problems: already running, stopped by the kill switch, or the OS listener failed (message attached).
    case alreadyRunning
    case killSwitchEngaged
    case listenerFailed(String)
    /// Handshake / session problems: timeout, not paired, pairing window closed, host key differs from the QR, session not up yet.
    case timedOut
    case notPaired
    case pairingNotOpen
    case hostKeyMismatch
    case notEstablished
    /// Sending problems: too many unacknowledged messages waiting, or the session is already closed.
    case sendQueueFull
    case closed
    /// Pairing input was not a valid code, the host said no (wrong/expired code), or another operation is already running.
    case invalidPairingInput
    case rejected
    case busy
}

/// Why a session ended. Used for the UI and for tests (Equatable lets them compare reasons).
public enum CloseReason: Sendable, Equatable {
    /// Names are self-explanatory: local close, peer said BYE, nothing heard for too long, reliable message ran out of retries,
    /// kill switch pressed, server stopped, or a new client replaced the old one.
    case localClose, peerBye, idleTimeout, retransmitFailed, killSwitch, serverStopped, replaced
    /// Handshake never completed (timeout, rejection, host key mismatch, transport failure).
    case handshakeFailed
}

/// Session state as seen by either end. Peer is identified only by a short hash prefix.
public enum SessionState: Sendable, Equatable {
    /// The four phases of one session; `established` carries only the short peer tag, never the full key.
    case idle
    /// Waiting for the first handshake message (before a session exists).
    case handshaking
    /// Handshake done; session established; carries the peer tag.
    case established(peerTag: String)
    /// Closed, with the reason.
    case closed(CloseReason)
}

/// What the host server is doing right now, as shown to the app.
public enum HostServerState: Sendable, Equatable {
    /// Not listening at all (the default).
    case stopped
    /// Listening on a port, no pairing window open.
    case listening(port: UInt16)
    /// Listening and a pairing code is currently valid.
    case pairingOpen(port: UInt16)
    /// A client is connected; carries the short peer tag.
    case sessionActive(peerTag: String)
    /// Something broke; carries a short reason text.
    case failed(String)
}

/// One complete decoded video frame handed to the app after the pieces were re-assembled.
public struct VideoFrame: Sendable, Equatable {
    /// The compressed frame bytes (Annex-B format).
    public var data: Data
    /// True if this frame can be decoded on its own (a keyframe).
    public var isKeyframe: Bool
    /// Presentation timestamp in microseconds (when to show the frame).
    public var ptsUs: UInt64
    /// Running number of the frame, used to put fragments together.
    public var frameID: UInt32
}

/// Counters of packets we threw away, by reason. Useful for spotting attacks or a bad network.
/// Each counter only ever goes up.
public struct NetStats: Sendable, Equatable {
    /// Packets whose counter we had already seen (an attacker re-sending an old packet, or a duplicate).
    public var replayDrops = 0
    /// Packets that failed decryption/authentication (tampered or encrypted with the wrong key).
    public var authDrops = 0
    /// Packets that could not be parsed as a valid frame at all.
    public var malformedDrops = 0
    /// Packets for a different session id than the current one.
    public var wrongSessionDrops = 0
    public var silentHandshakeDrops = 0   // host only: unknown peer, bad IK, pairing closed
    public var rateLimited = 0            // host only
    public var failedPairings = 0         // host only
    /// How many times we re-sent a reliable message because no ACK arrived.
    public var retransmits = 0
    /// All counters start at zero; `public init` lets other modules create one.
    public init() {}
}

/// Tuning knobs for timing and limits. Defaults are sensible; tests can shorten them.
/// Time values are in seconds.
public struct NetConfig: Sendable {
    /// Name this device announces to its peer during pairing (truncated to 64 bytes elsewhere).
    public var deviceName = "Lantern"
    /// How often to re-send a handshake packet if no answer came (UDP can lose packets).
    public var handshakeRetransmit: TimeInterval = 0.2
    /// Give up on a handshake after this long.
    public var handshakeTimeout: TimeInterval = 3
    /// How long a pairing code stays valid (host side). Default 120 s; clamped to 30...900 s by PairingPolicy.
    public var pairingCodeLifetime: TimeInterval = 120
    /// How long the host remembers a half-finished pairing handshake before forgetting it.
    public var pendingHandshakeTTL: TimeInterval = 10
    /// Rate limits: they stop a flood of handshake attempts from using up host resources.
    public var maxHandshakesPerWindow = 20      // per source IP
    public var maxHandshakesPerSecondGlobal = 100   // all sources together
    public var maxPendingHandshakes = 16        // concurrent unfinished pairing handshakes, all sources
    public var maxPendingPerSource = 2          // ... per source IP
    public var maxPairFailuresPerSource = 3     // authenticated wrong-code failures one source may spend per code (< 5 lock)
    /// Length of the sliding window used by the per-source rate limit above.
    public var handshakeWindow: TimeInterval = 10
    /// How often to send a PING when otherwise quiet, so the other side knows we are alive.
    public var keepaliveInterval: TimeInterval = 2
    /// If we hear nothing for this long, the session is considered dead.
    public var idleTimeout: TimeInterval = 10
    /// How long to wait for an ACK before re-sending a reliable message.
    public var reliableRetransmit: TimeInterval = 0.1
    /// How many send attempts before a reliable message counts as failed.
    public var reliableMaxTries = 30
    /// Maximum reliable messages allowed to wait for an ACK at once.
    public var maxUnacked = 256
    /// Allowed clock difference for the timestamp inside a reconnect handshake; blocks replays of old handshakes.
    public var ikTimestampSkew: TimeInterval = 60
    /// How often the internal timer fires to do retransmits, keepalives and clean-up.
    public var tick: TimeInterval = 0.05
    /// Minimum spacing of decoder-initiated keyframe requests.
    public var keyframeRequestMinInterval: TimeInterval = 0.5
    /// Public initialiser so code outside this module can build a default config.
    public init() {}
}

/// A "tag" is a tiny fingerprint of a public key: SHA-256 hash (one-way), first 3 bytes, printed as 6 hex characters.
/// Short, non-reversible tag for logs/UI. Never log more than this about a peer.
public func peerTag(_ publicKey: Data) -> String {
    SHA256.hash(data: publicKey).prefix(3).map { String(format: "%02x", $0) }.joined()
}

/// Crypto helper values and conversions shared by host and client. An enum with only static members is
/// used as a namespace (it can never be instantiated).
enum NetCrypto {
    /// Mixed into the Noise handshake so both sides must agree on the protocol name and version, or the handshake fails.
    static let prologue = Data("twu-stream-v1".utf8) + Data([FrameCodec.version])
    /// Turn the pairing credential (the code's bytes) into a 32-byte pre-shared key using HKDF, a standard
    /// "key stretcher": same input gives the same output, and the salt keeps this key separate from other uses.
    static func psk(fromCredential c: Data) -> Data {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: c),
                                       salt: Data("twu-stream-pair-v1".utf8), info: Data(), outputByteCount: 32)
        return k.withUnsafeBytes { Data($0) }
    }
    /// The session id is the first 4 bytes of the handshake hash (a value both sides computed identically),
    /// combined big-endian into one 32-bit number. It labels packets as belonging to this session.
    static func sessionID(handshakeHash h: Data) -> UInt32 {
        h.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    /// Encode a date as milliseconds since 1970 in 8 bytes, never negative. Sent inside the reconnect handshake.
    static func timestampPayload(_ date: Date) -> Data {
        var w = FrameWriter(); w.u64(UInt64(max(0, date.timeIntervalSince1970 * 1000))); return Data(w.bytes)
    }
    /// Reverse of the above. Returns nil if there were not enough bytes.
    static func parseTimestamp(_ d: Data) -> Date? {
        var r = FrameReader(Array(d)); guard let v = try? r.u64() else { return nil }
        return Date(timeIntervalSince1970: Double(v) / 1000)
    }
    /// Device name as UTF-8 bytes, cut at 64 bytes so a name cannot make a handshake packet too large.
    static func nameBytes(_ s: String) -> Data { Data(s.utf8.prefix(64)) }
}

/// Why this exists: names come from another device, so we never trust them as-is. This cleans them before display.
/// Peer-supplied device names are untrusted text: strip control, format (bidi overrides), separator,
/// private-use and unassigned scalars plus replacement characters from a truncated UTF-8 tail.
enum PeerName {
    /// Namespace for the name-cleaning function (an enum with only static members).
    /// Maximum number of raw bytes of a name we will even look at.
    static let maxBytes = 64
    /// Steps: cut to 64 bytes, decode as UTF-8 text, drop dangerous characters, trim spaces, use a fallback if empty.
    static func sanitize(_ raw: Data) -> String {
        let decoded = String(decoding: raw.prefix(maxBytes), as: UTF8.self)
        var out = String.UnicodeScalarView()
        for u in decoded.unicodeScalars {
            // U+FFFD is the "could not decode" mark; a cut-off multi-byte character at the end produces one, so skip it.
            if u == "\u{FFFD}" { continue }
            // Each Unicode scalar has a category. Skip invisible/control ones (could hide or reorder text on screen).
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: continue
            // Everything else is kept as-is.
            default: out.append(u)
            }
        }
        // Remove spaces at both ends; an empty result becomes a harmless placeholder.
        let t = String(out).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Unnamed device" : t
    }
}

/// A box that holds one value behind a lock so two threads cannot touch it at once.
/// `@unchecked Sendable` means "trust me, I did the locking myself".
/// Lock-protected value box (callbacks, hooks).
final class LockedBox<T>: @unchecked Sendable {
    /// NSLock: only one thread at a time may hold it. Others wait their turn.
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    /// `defer` runs the unlock when the function exits, so we never forget to unlock.
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

/// One producer, many listeners: each call to stream() gives a new AsyncStream (read with `for await`);
/// yield() sends a value to all of them.
/// Fan-out for AsyncStream consumers.
final class Broadcaster<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    /// Active listeners keyed by a unique id so each can be removed when it stops listening.
    private var conts: [UUID: AsyncStream<T>.Continuation] = [:]
    func stream() -> AsyncStream<T> {
        let id = UUID()
        // Register this listener under the lock, and arrange for it to be removed when the consumer goes away.
        return AsyncStream { c in
            lock.lock(); conts[id] = c; lock.unlock()
            c.onTermination = { [weak self] _ in self?.lock.lock(); self?.conts[id] = nil; self?.lock.unlock() }
        }
    }
    /// Copy the list under the lock, then send outside it so a slow consumer cannot block others.
    func yield(_ x: T) {
        lock.lock(); let cs = Array(conts.values); lock.unlock()
        for c in cs { c.yield(x) }
    }
    /// Close every stream and forget them all.
    func finish() {
        lock.lock(); let cs = Array(conts.values); conts.removeAll(); lock.unlock()
        for c in cs { c.finish() }
    }
}

/// A DatagramFilter receives each packet and returns the packets that should really be sent.
/// Datagram hook for tests and fault injection: return [] to drop, [d] to pass, [d, d] to duplicate.
public typealias DatagramFilter = @Sendable (Data) -> [Data]

/// Checks that a listen address is allowed. The host must bind to one specific private address,
/// so the stream is never exposed to the open internet by accident.
enum BindCheck {
    /// Accepts only a specific IPv4/IPv6 literal. Wildcards and hostnames are refused.
    /// Throws a specific error if the text is a wildcard, a public address, or not an IP at all.
    static func parse(_ s: String) throws -> NWEndpoint.Host {
        if let v4 = IPv4Address(s) {
            // 0.0.0.0 means "every network interface", which we refuse.
            if v4 == IPv4Address.any || v4.rawValue == Data([0, 0, 0, 0]) { throw LanternNetError.wildcardBindRefused }
            // Must fall in a private range (checked below).
            guard isPrivateV4(Array(v4.rawValue)) else { throw LanternNetError.nonPrivateBindRefused }
            return .ipv4(v4)
        }
        // Otherwise try IPv6, with the same two checks.
        if let v6 = IPv6Address(s) {
            if v6 == IPv6Address.any { throw LanternNetError.wildcardBindRefused }
            guard isPrivateV6(Array(v6.rawValue)) else { throw LanternNetError.nonPrivateBindRefused }
            return .ipv6(v6)
        }
        // Not an IP literal at all (for example a hostname): refuse.
        throw LanternNetError.invalidBindAddress
    }
    /// "Private" means only reachable inside a home/office network, not from the internet.
    /// RFC1918 (10/8, 172.16/12, 192.168/16), 127/8 (tests, loopback), 169.254/16 link-local.
    static func isPrivateV4(_ b: [UInt8]) -> Bool {
        // A valid IPv4 address is exactly 4 bytes.
        guard b.count == 4 else { return false }
        // Compare against each private range.
        return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }
    /// ::1, fe80::/10 link-local, fc00::/7 unique-local, and IPv4-mapped addresses whose IPv4 part is private.
    static func isPrivateV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        // ::1 is the IPv6 loopback address ("this computer").
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
        // fe80::/10 : first byte 0xfe and top two bits of second byte are 10.
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }
        // fc00::/7 : first byte is 0xfc or 0xfd.
        if (b[0] & 0xfe) == 0xfc { return true }
        // IPv4 address written inside an IPv6 one (::ffff:a.b.c.d): judge it by its IPv4 part.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPrivateV4(Array(b[12..<16])) }
        return false
    }
    /// Text form of the full endpoint (address and port). Identifies one remote sender.
    static func sourceKey(_ e: NWEndpoint) -> String { "\(e)" }
    /// Text form of just the address, with no port. Used for per-source rate limits.
    static func sourceIP(_ e: NWEndpoint) -> String {
        if case .hostPort(let h, _) = e { return "\(h)" }
        return "\(e)"
    }
}

/// "Amplification" attack: a forger fakes a sender address and makes us reply with bigger packets to a victim.
/// Rule here: never reply with more bytes than we received.
/// Anti-amplification for unauthenticated sources: PAIR_M2 (up to 164 B) is larger than the bare
/// PAIR_M1 (52 B), so the client pads PAIR_M1 with zeros to `paddedSize` and the host never sends an
/// unauthenticated reply larger than the datagram it received (`replyAllowed`).
enum PairM1Padding {
    /// 176 bytes, enough room for the biggest reply, so the request is always at least as big as the answer.
    static let paddedSize = 176   // >= header(4)+e(32)+encS(48)+name(64)+tag(16) = 164
    /// Append zero bytes until the packet is paddedSize long (never shrinks it).
    static func pad(_ wire: Data) -> Data { wire + Data(repeating: 0, count: max(0, paddedSize - wire.count)) }
    /// The unpadded PAIR_M1 frame if `d` starts like one (padding is ignored), else `d` unchanged.
    /// Header size + M1 body size is the real frame length; anything beyond it is padding.
    static func unpad(_ d: Data) -> Data {
        // If the packet is longer than a real M1 and its type byte says M1, cut off the padding.
        let n = FrameCodec.headerSize + FrameCodec.pairM1Size
        guard d.count > n, d[d.startIndex + 3] == WireType.pairM1.rawValue else { return d }
        return Data(d.prefix(n))
    }
    /// A reply is allowed only if it is no bigger than what was received.
    static func replyAllowed(replyBytes: Int, receivedBytes: Int) -> Bool { replyBytes <= receivedBytes }
}


/// Friendly messages for a few errors; everything else uses a generic text with the case name.
extension LanternNetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timedOut: return "No answer from the Mac within 3 seconds. Check the code, the address, that the phone is on the same Wi-Fi as the Mac, and Settings > Privacy & Security > Local Network > Lantern."
        case .hostKeyMismatch: return "The Mac's key does not match the QR code. Do not continue."
        case .rejected: return "The Mac rejected the code (wrong or expired). Get a new code."
        default: return "Lantern network error: \(self)"
        }
    }
}
