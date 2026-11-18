// ==============================================================================
// Program: NoiseCipher.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Noise protocol cipher layer wrapping ChaCha20-Poly1305 authenticated encryption.
//          Inputs: Plaintext bytes, 32-byte symmetric key, 64-bit nonce, and optional authentication data.
//          Outputs: Authenticated ciphertext with 16-byte Poly1305 tag.
//          Design Rationale: ChaCha20-Poly1305 offers constant-time operation in software without
//          hardware AES acceleration dependencies.
// ==============================================================================
// =====================================================================================
// NoiseCipher.swift
//
// PURPOSE
//   This file holds the "encrypt and decrypt one message" part of our Noise protocol
//   code. Noise is a recipe for two devices to agree on secret keys and then talk
//   privately. Once the handshake (see NoiseHandshake.swift) finishes, each side ends up
//   holding two `NoiseCipherState` values: one for sending and one for receiving.
//
// WHO CALLS IT
//   - NoiseHandshake.swift uses `NoiseCipherState` while the handshake is still running
//     (to encrypt the handshake's own payloads) and hands out the final pair at the end.
//   - The secure session code uses the finished cipher states to encrypt every data
//     packet it sends and to decrypt every packet it receives.
//
// KEY IDEAS (in plain English)
//   - A CIPHER turns readable bytes ("plaintext") into scrambled bytes ("ciphertext")
//     using a secret KEY. Here the cipher is ChaCha20-Poly1305, an "AEAD" cipher:
//     it both scrambles the data AND adds a 16-byte "tag" that works like a tamper seal.
//     If anyone changes even one bit, the tag no longer matches and decryption fails.
//   - A NONCE ("number used once") is a counter mixed into the encryption. Using the
//     same key with the same nonce twice would be a serious security mistake, so the
//     nonce must never repeat for one key.
//   - AD ("associated data") is extra data that is NOT encrypted but IS covered by the
//     tamper seal, so it cannot be changed without detection.
//   - A REPLAY WINDOW remembers which packet numbers we already accepted, so an
//     attacker who records a packet and sends it again gets rejected.
// =====================================================================================

import Foundation
import CryptoKit

// MARK: - Errors

/// Errors from the Noise layer. Never carries key material.
public enum NoiseError: Error, Equatable, Sendable {
    /// The handshake was set up with bad inputs (for example a wrong-sized pre-shared key).
    case invalidConfiguration(String)
    /// An operation was tried at the wrong time (for example encrypting before a key exists).
    case wrongState(String)
    /// The incoming bytes were too short or otherwise not shaped like a valid message.
    case malformedMessage
    /// The tamper seal (tag) did not match: wrong key, corrupted data, or forged data.
    case decryptionFailed
    /// This packet number was already seen, or is too old to track.
    case replay
    /// The nonce counter reached its reserved last value, so no more messages are allowed.
    case nonceExhausted
    /// A handshake message would be bigger than the Noise maximum.
    case messageTooLong
}

// MARK: - Replay window

/// Sliding-window replay filter (default 2048 packets), per Noise spec 11.4 / WireGuard style.
/// A counter is only recorded after successful authentication.
///
/// How it works: we remember the HIGHEST packet number seen so far, plus one bit for each of
/// the most recent `size` numbers below it ("seen" = 1). Anything older than the window is
/// refused outright (we cannot tell if it is a repeat), and anything inside the window is
/// accepted only if its bit is still 0.
public struct NoiseReplayWindow: Sendable {
    /// How many packet numbers (counting down from the highest) the window remembers.
    public let size: UInt64
    /// The largest packet number we have accepted so far.
    private var highest: UInt64 = 0
    /// False until the very first packet is accepted (so "highest = 0" is not mistaken for real data).
    private var seenAny = false
    /// The bitmap: each bit says whether a packet number was seen. 64 numbers per UInt64 word.
    private var bits: [UInt64]

    /// Creates an empty window. `size` must be a positive multiple of 64 because the bitmap is
    /// stored in 64-bit words.
    public init(size: Int = 2048) {
        // Programmer-error guard: a bad size would break the bit math below.
        precondition(size > 0 && size % 64 == 0)
        self.size = UInt64(size)
        // One UInt64 holds 64 flags, so we need size/64 words, all starting at 0 (nothing seen).
        self.bits = Array(repeating: 0, count: size / 64)
    }

    /// True if the counter would be accepted (not too old, not seen).
    /// This only LOOKS; it does not change anything. Call it before decrypting.
    public func check(_ n: UInt64) -> Bool {
        // Nothing seen yet, so anything is new.
        guard seenAny else { return true }
        // Bigger than everything so far: definitely new.
        if n > highest { return true }
        // How far behind the newest packet is this one?
        let diff = highest - n
        // Older than the window can remember: refuse to be safe.
        if diff >= size { return false }
        // Inside the window: accept only if its "seen" bit is still 0.
        return !bit(n)
    }

    /// Record a counter that authenticated successfully.
    /// Only call this AFTER the tamper seal checked out, otherwise a forged packet could
    /// push the window forward and block real packets.
    public mutating func commit(_ n: UInt64) {
        // First ever packet: it becomes the highest and gets its bit set.
        if !seenAny {
            seenAny = true; highest = n; setBit(n); return
        }
        // A new highest number: the window slides forward.
        if n > highest {
            let shift = n - highest
            if shift >= size {
                // Jumped past the whole window: everything old is forgotten, wipe all bits.
                for i in bits.indices { bits[i] = 0 }
            } else {
                // Small jump: clear the bits for the new slots we are sliding into, because
                // those slots used to hold flags for much older packet numbers.
                var s = highest
                while s < n { s += 1; clearBit(s) }
            }
            highest = n
        }
        // Mark this packet number as seen.
        setBit(n)
    }

    /// Maps a packet number to (which word in the bitmap, which bit mask inside that word).
    /// The modulo makes the bitmap act like a circular buffer.
    private func idx(_ n: UInt64) -> (Int, UInt64) {
        let p = Int(n % size)
        return (p / 64, 1 << UInt64(p % 64))
    }
    /// Reads the "seen" flag for a packet number.
    private func bit(_ n: UInt64) -> Bool { let (i, m) = idx(n); return bits[i] & m != 0 }
    /// Sets the "seen" flag to 1.
    private mutating func setBit(_ n: UInt64) { let (i, m) = idx(n); bits[i] |= m }
    /// Clears the "seen" flag back to 0.
    private mutating func clearBit(_ n: UInt64) { let (i, m) = idx(n); bits[i] &= ~m }
}

// MARK: - Cipher state

/// Noise CipherState (ChaChaPoly, 64-bit nonce). Counter 2^64-1 is reserved and never used.
///
/// Holds one secret key (or none yet) and a counter. Two ways to use it:
///   1. Sequential (stream-like, in order): the counter is kept inside and goes up by one each message.
///   2. Explicit counter (datagram-like, packets may arrive out of order): the caller supplies the
///      counter, and a replay window rejects repeats.
public struct NoiseCipherState: Sendable {
    /// The secret key. `nil` means "no key yet", in which case encrypting is not allowed.
    private var key: SymmetricKey?
    /// The next nonce for the sequential mode. Readable outside, changeable only here.
    public private(set) var nonce: UInt64 = 0
    /// Remembers which explicit counters were already accepted (used by the counter-based decrypt).
    private var window = NoiseReplayWindow()

    /// A cipher with no key yet (used at the very start of a handshake).
    public init() { key = nil }
    /// A cipher that is ready to use with the given secret key.
    public init(key: SymmetricKey) { self.key = key }

    /// True once a key has been set.
    public var hasKey: Bool { key != nil }

    /// Builds the 12-byte ChaChaPoly nonce from our 64-bit counter:
    /// 4 zero bytes followed by the counter in little-endian byte order (as the Noise spec says).
    static func nonceBytes(_ n: UInt64) -> ChaChaPoly.Nonce {
        // Start with four zero bytes.
        var d = Data(repeating: 0, count: 4)
        // Append the 8 counter bytes, least significant byte first.
        withUnsafeBytes(of: n.littleEndian) { d.append(contentsOf: $0) }
        // 12 bytes is always the right size, so this cannot fail.
        return try! ChaChaPoly.Nonce(data: d)
    }

    /// Encrypts `pt` with a specific nonce `n`. Output is ciphertext followed by the 16-byte tag.
    func seal(_ pt: Data, ad: Data, n: UInt64) throws -> Data {
        // No key means we cannot encrypt.
        guard let key else { throw NoiseError.wrongState("no key") }
        // The last counter value is reserved, so refuse it.
        guard n != UInt64.max else { throw NoiseError.nonceExhausted }
        // Do the actual ChaCha20-Poly1305 encryption; `ad` is covered by the tag but not encrypted.
        let box = try ChaChaPoly.seal(pt, using: key, nonce: Self.nonceBytes(n), authenticating: ad)
        // Pack as ciphertext || tag (the nonce is not sent; both sides know it from the counter).
        var out = Data(); out.append(box.ciphertext); out.append(box.tag); return out
    }

    /// Decrypts `ct` (ciphertext followed by 16-byte tag) with nonce `n`.
    /// Throws if the tag does not match.
    func open(_ ct: Data, ad: Data, n: UInt64) throws -> Data {
        guard let key else { throw NoiseError.wrongState("no key") }
        guard n != UInt64.max else { throw NoiseError.nonceExhausted }
        // Must at least be big enough to hold the 16-byte tag.
        guard ct.count >= 16 else { throw NoiseError.decryptionFailed }
        // Split the input: everything but the last 16 bytes is ciphertext, the last 16 are the tag.
        let body = ct.prefix(ct.count - 16), tag = ct.suffix(16)
        do {
            // Rebuild the sealed box and verify the tag while decrypting.
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonceBytes(n), ciphertext: body, tag: tag)
            return try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch { throw NoiseError.decryptionFailed }   // hide the reason so errors reveal nothing useful
    }

    /// Sequential encrypt: uses and increments the internal nonce.
    public mutating func encrypt(_ pt: Data, ad: Data = Data()) throws -> Data {
        // Encrypt with the current counter...
        let out = try seal(pt, ad: ad, n: nonce)
        // ...then move to the next one so the nonce is never reused.
        nonce += 1
        return out
    }

    /// Sequential decrypt: nonce advances only on success.
    public mutating func decrypt(_ ct: Data, ad: Data = Data()) throws -> Data {
        // If this throws, the counter stays put, so a forged message cannot desync us.
        let out = try open(ct, ad: ad, n: nonce)
        nonce += 1
        return out
    }

    /// Encrypt with explicit counter (datagram transport). Caller owns uniqueness.
    public func encrypt(_ pt: Data, ad: Data = Data(), counter: UInt64) throws -> Data {
        try seal(pt, ad: ad, n: counter)
    }

    /// Decrypt with explicit counter; rejects replays and too-old counters via the sliding window.
    /// The window is updated only after authentication succeeds.
    public mutating func decrypt(_ ct: Data, ad: Data = Data(), counter: UInt64) throws -> Data {
        // Cheap early check: refuse repeats and very old packets before doing any crypto.
        guard window.check(counter) else { throw NoiseError.replay }
        // Verify and decrypt; throws if the tag is wrong.
        let out = try open(ct, ad: ad, n: counter)
        // Only now is it safe to remember this counter.
        window.commit(counter)
        return out
    }
}
