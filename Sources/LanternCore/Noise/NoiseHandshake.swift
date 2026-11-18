// =====================================================================================
// NoiseHandshake.swift
//
// PURPOSE
//   Implements the Noise "handshake": a short back-and-forth of messages in which two
//   devices prove who they are and agree on fresh secret keys, without ever sending those
//   secret keys over the network.
//
// WHO CALLS IT
//   - The pairing code (first-time connection, pattern XXpsk3) and the reconnect code
//     (already-paired devices, pattern IK) create a `NoiseHandshake`, pass messages back and
//     forth with writeMessage/readMessage, then call `split()` to get the two ciphers used
//     for the real session (see NoiseCipher.swift).
//
// KEY IDEAS (in plain English)
//   - STATIC KEY: a device's long-term identity key pair (X25519). The public half can be
//     shared; the private half never leaves the device.
//   - EPHEMERAL KEY: a throwaway key pair made fresh for each handshake. Because it is
//     thrown away afterward, old recordings cannot be decrypted later ("forward secrecy").
//   - DIFFIE-HELLMAN (DH): a math trick where my private key + your public key gives the same
//     shared secret as your private key + my public key. Nobody watching can compute it.
//   - The handshake keeps a running "hash" (h) of everything said so far and a "chaining key"
//     (ck) that is stirred with every new secret. If anyone tampers with any message, the
//     two sides end up with different values and decryption fails.
//   - PRE-SHARED KEY (PSK): a secret both sides already know (here derived from the pairing
//     code or QR secret). It proves the other device is the one the user meant to pair with.
//   - PATTERNS: a pattern is just the script of which tokens (e, s, ee, es, se, ss, psk) go
//     into each message. We support two:
//       XXpsk3 - neither side knows the other yet (first pairing), plus a PSK.
//       IK     - the initiator already knows the responder's static public key (reconnect).
// =====================================================================================

import Foundation
import CryptoKit

// MARK: - Patterns and roles

/// Which handshake script is being used.
public enum NoisePattern: Sendable, Equatable {
    /// First-time pairing: both sides send their static keys, and a pre-shared key is mixed in.
    case xxPsk3
    /// Reconnect: the initiator already knows the responder's static public key.
    case ik

    /// The official Noise protocol name. It is hashed into the starting state, so both sides
    /// must use exactly the same name or they will never agree on keys.
    public var protocolName: String {
        switch self {
        case .xxPsk3: return "Noise_XXpsk3_25519_ChaChaPoly_SHA256"
        case .ik: return "Noise_IK_25519_ChaChaPoly_SHA256"
        }
    }
}

/// Which end of the conversation we are: the one who speaks first, or the one who answers.
public enum NoiseRole: Sendable, Equatable { case initiator, responder }

/// The building blocks ("tokens") of a handshake message.
/// e = send an ephemeral public key; s = send our static public key (encrypted);
/// ee/es/se/ss = do a Diffie-Hellman between the named pair of keys and mix the result in;
/// psk = mix in the pre-shared key.
enum NoiseToken { case e, s, ee, es, se, ss, psk }

extension NoisePattern {
    /// Pre-message: responder static is known to initiator (IK).
    var responderStaticIsPremessage: Bool { self == .ik }
    /// Whether this pattern uses a pre-shared key.
    var usesPsk: Bool { self == .xxPsk3 }
    /// Messages in order; message i is written by initiator when i is even.
    var messages: [[NoiseToken]] {
        switch self {
        case .xxPsk3: return [[.e], [.e, .ee, .s, .es], [.s, .se, .psk]]
        case .ik: return [[.e, .es, .s, .ss], [.e, .ee, .se]]
        }
    }
}

// MARK: HKDF (Noise spec 4.3) and SymmetricState (5.2)

/// HKDF = a standard way to turn one secret into several independent-looking secret keys.
enum NoiseHKDF {
    /// HMAC-SHA256: a keyed fingerprint. Same key + same data always gives the same 32 bytes.
    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    /// Produces `outputs` (2 or 3) 32-byte keys from the chaining key and new input secret.
    static func derive(chainingKey: Data, input: Data, outputs: Int) -> [Data] {
        // Step 1 ("extract"): squeeze the input into one temporary key.
        let temp = hmac(chainingKey, input)
        var result: [Data] = []
        var prev = Data()
        // Step 2 ("expand"): each output is an HMAC of the previous output plus a counter byte 1, 2, 3...
        for i in 1...outputs {
            prev = hmac(temp, prev + Data([UInt8(i)]))
            result.append(prev)
        }
        return result
    }
}

/// Noise "SymmetricState": the running secret bookkeeping of the handshake.
/// `ck` is the chaining key (the growing pool of secrets), `h` is the running hash of the
/// transcript, and `cipher` is the current encryption key (none until the first DH happens).
struct NoiseSymmetricState: Sendable {
    /// Chaining key: all DH results are stirred into this.
    private(set) var ck: Data
    /// Transcript hash: a fingerprint of every message so far. Used as associated data so any
    /// change to the conversation breaks decryption.
    private(set) var h: Data
    /// Current cipher; starts keyless.
    private(set) var cipher = NoiseCipherState()

    /// Starts the state from the protocol name.
    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        // Spec rule: a short name is padded with zeros to 32 bytes; a long name is hashed down.
        if name.count <= 32 { h = name + Data(repeating: 0, count: 32 - name.count) }
        else { h = Data(SHA256.hash(data: name)) }
        // The chaining key starts equal to the hash.
        ck = h
    }

    /// Folds more data into the transcript hash.
    mutating func mixHash(_ data: Data) { h = Data(SHA256.hash(data: h + data)) }

    /// Stirs a new secret (like a DH result) into the chaining key and installs a fresh cipher key.
    mutating func mixKey(_ ikm: Data) {
        let o = NoiseHKDF.derive(chainingKey: ck, input: ikm, outputs: 2)
        ck = o[0]                                          // new chaining key
        cipher = NoiseCipherState(key: SymmetricKey(data: o[1]))   // new encryption key (nonce restarts at 0)
    }

    /// Like `mixKey`, but also mixes a middle output into the transcript hash. Used for the PSK.
    mutating func mixKeyAndHash(_ ikm: Data) {
        let o = NoiseHKDF.derive(chainingKey: ck, input: ikm, outputs: 3)
        ck = o[0]
        mixHash(o[1])
        cipher = NoiseCipherState(key: SymmetricKey(data: o[2]))
    }

    /// Encrypts (if a key exists) and then records the result in the transcript hash.
    mutating func encryptAndHash(_ pt: Data) throws -> Data {
        // Before any key exists, data goes out as plain bytes.
        let out = cipher.hasKey ? try cipher.encrypt(pt, ad: h) : pt
        mixHash(out)
        return out
    }

    /// Decrypts (if a key exists) and records the received ciphertext in the transcript hash.
    mutating func decryptAndHash(_ ct: Data) throws -> Data {
        let out = cipher.hasKey ? try cipher.decrypt(ct, ad: h) : ct
        // The hash always covers what was on the wire (the ciphertext), same as the sender did.
        mixHash(ct)
        return out
    }

    /// End of handshake: derive the two final session keys, one for each direction.
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let o = NoiseHKDF.derive(chainingKey: ck, input: Data(), outputs: 2)
        return (NoiseCipherState(key: SymmetricKey(data: o[0])), NoiseCipherState(key: SymmetricKey(data: o[1])))
    }
}

// MARK: Handshake

/// Noise handshake. Not thread-safe; use from one task at a time. Any failure poisons the handshake.
public struct NoiseHandshake: Sendable {
    /// Short names for the X25519 key types so the code below reads easily.
    public typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey
    public typealias PublicKey = Curve25519.KeyAgreement.PublicKey

    /// Noise messages may not exceed 65535 bytes.
    public static let maxMessageLength = 65535

    /// Which script we follow.
    public let pattern: NoisePattern
    /// Whether we speak first (initiator) or answer (responder).
    public let role: NoiseRole
    /// The running secret state (hash, chaining key, cipher).
    private var ss: NoiseSymmetricState
    /// Our static (long-term) private key.
    private let s: PrivateKey
    /// The other side's static public key, once known.
    private var rs: PublicKey?
    /// Our ephemeral (one-time) private key, created when we send our `e` token.
    private var e: PrivateKey?
    /// The other side's ephemeral public key, once received.
    private var re: PublicKey?
    /// The pre-shared key (32 bytes) for XXpsk3, otherwise nil.
    private let psk: Data?
    /// Test-only fixed ephemeral key; nil in production so a random one is made.
    private let ephemeralOverride: PrivateKey?
    /// Which message of the pattern we are on (0, 1, 2...).
    private var index = 0
    /// Set to true after any error; once failed, the handshake can never be used again.
    private var failed = false

    /// - Parameters:
    ///   - staticKey: our long-term X25519 key.
    ///   - remoteStatic: required for IK initiator (responder's static); ignored/forbidden otherwise.
    ///   - psk: 32 bytes, required for XXpsk3.
    public init(pattern: NoisePattern, role: NoiseRole, staticKey: PrivateKey,
                remoteStatic: PublicKey? = nil, psk: Data? = nil, prologue: Data = Data()) throws {
        // Public entry point: forwards to the full initializer with no injected ephemeral key.
        try self.init(pattern: pattern, role: role, staticKey: staticKey, remoteStatic: remoteStatic,
                      psk: psk, prologue: prologue, ephemeral: nil)
    }

    /// Test-only entry point: inject a fixed ephemeral key (used for known-answer vectors).
    init(pattern: NoisePattern, role: NoiseRole, staticKey: PrivateKey, remoteStatic: PublicKey?,
         psk: Data?, prologue: Data, ephemeral: PrivateKey?) throws {
        // Validate the configuration against what the pattern needs.
        if pattern.usesPsk {
            // XXpsk3 must have a 32-byte pre-shared key.
            guard let psk, psk.count == 32 else { throw NoiseError.invalidConfiguration("psk must be 32 bytes") }
        } else if psk != nil { throw NoiseError.invalidConfiguration("psk not used by pattern") }
        // IK initiator must already know who it is calling.
        if pattern == .ik && role == .initiator && remoteStatic == nil {
            throw NoiseError.invalidConfiguration("IK initiator needs remoteStatic")
        }
        // XX learns the other side's key during the handshake, so none may be supplied up front.
        if pattern == .xxPsk3 && remoteStatic != nil {
            throw NoiseError.invalidConfiguration("XX has no remote static pre-message")
        }
        // Store the simple fields.
        self.pattern = pattern; self.role = role; self.s = staticKey
        self.psk = psk; self.ephemeralOverride = ephemeral
        // Start the transcript from the protocol name, then mix in the optional prologue
        // (extra context both sides must agree on).
        var st = NoiseSymmetricState(protocolName: pattern.protocolName)
        st.mixHash(prologue)
        // IK "pre-message": the responder's public static key is hashed in before any message,
        // by both sides, so both start with the same transcript.
        if pattern.responderStaticIsPremessage {
            if role == .initiator { self.rs = remoteStatic; st.mixHash(remoteStatic!.rawRepresentation) }
            else { st.mixHash(staticKey.publicKey.rawRepresentation) }
        }
        self.ss = st
    }

    /// True when every message of the script has been sent/received without error.
    public var isComplete: Bool { index >= pattern.messages.count && !failed }
    /// The final transcript hash; both sides get the same value if nothing was tampered with.
    /// (It is used for the short authentication string.)
    public var handshakeHash: Data { ss.h }
    /// The other side's static public key (known after the handshake reveals it).
    public var remoteStaticPublicKey: PublicKey? { rs }

    /// Messages alternate: the initiator writes the even-numbered ones, the responder the odd ones.
    private var myTurnToWrite: Bool { (index % 2 == 0) == (role == .initiator) }

    /// Performs one Diffie-Hellman and returns the shared secret bytes.
    private func dh(_ priv: PrivateKey?, _ pub: PublicKey?) throws -> Data {
        // Both keys must exist by this point in the script.
        guard let priv, let pub else { throw NoiseError.wrongState("missing key for DH") }
        let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
        return secret.withUnsafeBytes { Data($0) }
    }

    /// Resolve DH token to (local private, remote public).
    /// Token names are written from the initiator's view (first letter = initiator's key), so the
    /// responder must swap which of its keys it uses.
    private func dhPair(_ t: NoiseToken) -> (PrivateKey?, PublicKey?) {
        let init_ = role == .initiator
        switch t {
        case .ee: return (e, re)                           // ephemeral with ephemeral
        case .ss: return (s, rs)                           // static with static
        case .es: return init_ ? (e, rs) : (s, re)         // initiator ephemeral x responder static
        case .se: return init_ ? (s, re) : (e, rs)         // initiator static x responder ephemeral
        default: return (nil, nil)
        }
    }

    /// Builds the next outgoing handshake message (our turn only) and returns its bytes.
    public mutating func writeMessage(_ payload: Data = Data()) throws -> Data {
        // Refuse to continue after a failure, out of turn, or past the end of the script.
        guard !failed else { throw NoiseError.wrongState("handshake failed") }
        guard index < pattern.messages.count, myTurnToWrite else { throw NoiseError.wrongState("not our turn") }
        do {
            var out = Data()
            // Walk the tokens this message is made of, in order.
            for t in pattern.messages[index] {
                switch t {
                case .e:
                    // Make (or use the injected) ephemeral key pair and send its public half in clear.
                    let k = ephemeralOverride ?? PrivateKey()
                    e = k
                    let pub = k.publicKey.rawRepresentation
                    out += pub; ss.mixHash(pub)
                    // PSK patterns also stir the ephemeral public key into the key schedule.
                    if pattern.usesPsk { ss.mixKey(pub) }
                case .s:
                    // Send our static public key, encrypted if a key exists by now.
                    out += try ss.encryptAndHash(s.publicKey.rawRepresentation)
                case .psk:
                    // Stir the pre-shared secret in (proves both sides know the pairing code/secret).
                    ss.mixKeyAndHash(psk!)
                default:
                    // ee / es / se / ss: do the DH and stir the shared secret into the keys.
                    let (a, b) = dhPair(t)
                    ss.mixKey(try dh(a, b))
                }
            }
            // Finally add the (usually encrypted) payload bytes.
            out += try ss.encryptAndHash(payload)
            guard out.count <= Self.maxMessageLength else { throw NoiseError.messageTooLong }
            // Move to the next message of the script.
            index += 1
            return out
        } catch { failed = true; throw error }   // any error permanently poisons the handshake
    }

    /// Processes an incoming handshake message (the other side's turn) and returns its payload.
    public mutating func readMessage(_ message: Data) throws -> Data {
        guard !failed else { throw NoiseError.wrongState("handshake failed") }
        guard index < pattern.messages.count, !myTurnToWrite else { throw NoiseError.wrongState("not our turn") }
        guard message.count <= Self.maxMessageLength else { failed = true; throw NoiseError.messageTooLong }
        do {
            // Work on a copy so we can peel bytes off the front as we parse.
            var buf = Data(message)   // re-base indices
            /// Removes and returns the first `n` bytes, or fails if the message is too short.
            func take(_ n: Int) throws -> Data {
                guard buf.count >= n else { throw NoiseError.malformedMessage }
                let d = buf.prefix(n); buf = buf.dropFirst(n); return Data(d)
            }
            // Mirror the sender: process the same tokens in the same order.
            for t in pattern.messages[index] {
                switch t {
                case .e:
                    // 32 bytes: the other side's ephemeral public key.
                    let raw = try take(32)
                    re = try PublicKey(rawRepresentation: raw)
                    ss.mixHash(raw)
                    if pattern.usesPsk { ss.mixKey(raw) }
                case .s:
                    // Static key: 32 bytes in clear, or 48 (32 + 16-byte tag) once encryption is on.
                    let raw = try take(ss.cipher.hasKey ? 48 : 32)
                    rs = try PublicKey(rawRepresentation: try ss.decryptAndHash(raw))
                case .psk:
                    ss.mixKeyAndHash(psk!)
                default:
                    // DH tokens, same as when writing.
                    let (a, b) = dhPair(t)
                    ss.mixKey(try dh(a, b))
                }
            }
            // Whatever is left is the payload; decrypting it also verifies the whole handshake so far.
            let payload = try ss.decryptAndHash(buf)
            index += 1
            return payload
        } catch { failed = true; throw error }
    }

    /// Returns (send, receive) cipher states for our role. Only valid once complete.
    public func split() throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard isComplete else { throw NoiseError.wrongState("handshake not complete") }
        let (c1, c2) = ss.split()
        // The first key is initiator->responder, the second is responder->initiator,
        // so the responder swaps them to get "send" and "receive" right.
        return role == .initiator ? (c1, c2) : (c2, c1)
    }
}
