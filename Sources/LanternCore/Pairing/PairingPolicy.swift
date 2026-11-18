// =====================================================================================
// PairingPolicy.swift
//
// PURPOSE
//   The rules for how long a pairing code lives and how many wrong guesses are allowed.
//   Think of it as a small state machine (a flowchart in code) that guards the pairing door.
//
// WHO CALLS IT
//   The host side of the app (owned by one actor that serialises access) calls `begin` or
//   `beginQR` when the user taps "Pair new device", then `attempt`/`recordFailure`/`consume`
//   as pairing handshakes arrive.
//
// KEY IDEAS (in plain English)
//   - SINGLE USE: once a code works, it is wiped and cannot be used again.
//   - EXPIRY: a code stops working after a time limit.
//   - LOCKOUT: after 5 wrong tries the code is destroyed, so an attacker cannot just keep
//     guessing (a 50-bit code is huge, but limiting guesses makes brute force hopeless).
//   - INJECTED CLOCK: `now` is a function we are given, so tests can pretend time passes.
// =====================================================================================

import Foundation

// MARK: - States and results

/// Where the pairing attempt currently is.
public enum PairingState: Sendable, Equatable {
    /// No code has been started.
    case idle
    /// A code is live until `expiresAt`; `failures` wrong tries so far.
    case codeShown(expiresAt: Date, failures: Int)
    /// The code was used successfully.
    case consumed
    /// The time limit passed.
    case expired
    /// Too many wrong tries.
    case locked
}

/// The answer to one pairing attempt.
public enum PairingAttemptResult: Sendable, Equatable {
    /// Correct secret; code is now used up.
    case accepted
    /// Wrong secret; `remaining` tries are left before lockout.
    case rejected(remaining: Int)
    /// Too late.
    case expired
    /// Too many failures.
    case locked
    /// There is no active code to try against.
    case notActive
}

// MARK: - Policy

/// idle -> codeShown -> consumed | expired | locked. Single use, 120 s TTL, 5 failures lock.
/// Value type; the owner (an actor on the host) serialises access.
public struct PairingPolicy: Sendable {
    public static let ttl: TimeInterval = 120   // default lifetime of a code; a host may choose a longer one (see init)
    /// The lifetime actually used by this instance (clamped in init).
    public let codeLifetime: TimeInterval
    /// Wrong tries allowed before the code is locked out.
    public static let maxFailures = 5

    /// Clock function (replaceable in tests).
    private let now: @Sendable () -> Date
    /// The secret bytes that must be matched; nil once wiped.
    private var credential: Data?
    /// When the current code stops working.
    private var expiresAt: Date?
    /// How many wrong tries so far.
    private var failures = 0
    /// Set when the attempt has ended (consumed, expired or locked); overrides everything else.
    private var terminal: PairingState?

    /// Creates a policy. The lifetime is forced into the range 30...900 seconds.
    public init(now: @escaping @Sendable () -> Date = { Date() }, codeLifetime: TimeInterval = PairingPolicy.ttl) { self.now = now; self.codeLifetime = min(max(codeLifetime, 30), 900) }

    /// The current state, worked out from the stored fields and the clock.
    public var state: PairingState {
        // A finished attempt stays finished.
        if let t = terminal { return t }
        // No expiry time means nothing was ever started.
        guard let exp = expiresAt else { return .idle }
        // Past the deadline: expired.
        if now() >= exp { return .expired }
        return .codeShown(expiresAt: exp, failures: failures)
    }

    /// True while a code can still be attempted.
    public var isActive: Bool { if case .codeShown = state { return true } else { return false } }

    /// Start a new text-code attempt (user pressed "Pair new device"). Replaces any previous code.
    @discardableResult
    public mutating func begin() -> PairingCode {
        // Make a random code and arm the policy with its bytes.
        let c = PairingCode.generate()
        arm(c.bytes)
        return c
    }

    /// Start a QR attempt; the secret is the credential.
    @discardableResult
    public mutating func beginQR(hostPublicKey: Data, addressHint: String) -> PairingQRPayload {
        let p = PairingQRPayload.generate(hostPublicKey: hostPublicKey, addressHint: addressHint)
        arm(p.secret)
        return p
    }

    /// Credential bytes for psk derivation, only while active.
    public var activeCredential: Data? { isActive ? credential : nil }

    /// Abandons the current attempt and returns to idle.
    public mutating func cancel() { reset() }

    /// Direct attempt with a typed code. Malformed input counts as a failure.
    public mutating func attempt(code: String) -> PairingAttemptResult {
        // If the text cannot be parsed, compare an empty candidate so it fails and is counted.
        guard let parsed = try? PairingCode(parsing: code) else { return attempt(candidate: Data()) }
        return attempt(candidate: parsed.bytes)
    }

    /// Compare candidate credential (constant time). Success consumes the code.
    public mutating func attempt(candidate: Data) -> PairingAttemptResult {
        // First check whether an attempt is even possible right now.
        switch state {
        case .idle, .consumed: return .notActive
        case .expired: wipe(.expired); return .expired
        case .locked: return .locked
        case .codeShown: break
        }
        // Compare in constant time; on a match, burn the code so it cannot be reused.
        if let cred = credential, constantTimeEquals(cred, candidate) {
            wipe(.consumed)
            return .accepted
        }
        // Otherwise count it as a wrong try.
        return recordFailure()
    }

    /// For flows where the Noise msg3 authentication failed (any source). Counts toward lockout.
    @discardableResult
    public mutating func recordFailure() -> PairingAttemptResult {
        // Same availability check as `attempt`.
        switch state {
        case .idle, .consumed: return .notActive
        case .expired: wipe(.expired); return .expired
        case .locked: return .locked
        case .codeShown: break
        }
        failures += 1
        // Hit the limit: destroy the secret and lock.
        if failures >= Self.maxFailures { wipe(.locked); return .locked }
        return .rejected(remaining: Self.maxFailures - failures)
    }

    /// Mark the code used after an externally verified successful handshake.
    public mutating func consume() { if isActive { wipe(.consumed) } }

    /// Starts a fresh attempt with the given secret: new deadline, zero failures, not finished.
    private mutating func arm(_ cred: Data) {
        credential = cred; expiresAt = now().addingTimeInterval(codeLifetime); failures = 0; terminal = nil
    }
    /// Ends the attempt: forgets the secret and records the final state.
    private mutating func wipe(_ t: PairingState) { credential = nil; terminal = t }
    /// Returns to the blank idle state.
    private mutating func reset() { credential = nil; expiresAt = nil; failures = 0; terminal = nil }
}
