// =====================================================================================
// PairingCode.swift
//
// PURPOSE
//   Defines the two "first-time pairing" secrets a user can use to connect a phone to the
//   host: a typed 10-character code, or a QR code payload. Also holds a helper to compare
//   secrets safely.
//
// WHO CALLS IT
//   - PairingPolicy.swift creates and checks codes/payloads.
//   - The pairing UI shows `displayString` or the encoded QR text and parses what the user types
//     or scans.
//   - The handshake code uses `bytes` / `secret` as the Noise pre-shared key input.
//
// KEY IDEAS (in plain English)
//   - A pairing code is a short-lived shared secret. Both devices must know it for pairing to work,
//     so a stranger on the network cannot pair.
//   - CONSTANT-TIME COMPARISON: comparing secrets with a normal "==" can stop at the first
//     difference, and the tiny timing difference can leak information. We compare every byte
//     every time so the time does not depend on where the mismatch is.
//   - CROCKFORD BASE32: an alphabet of 32 characters that avoids look-alikes (no I, L, O, U).
//     10 characters x 5 bits each = 50 bits of randomness.
//   - BASE64URL: a way to write raw bytes as plain text that is safe inside a QR string.
// =====================================================================================

import Foundation
import CryptoKit

// MARK: - Safe comparison

/// Constant-time equality for secrets. Length mismatch is folded into the result
/// without an early return on content.
public func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    // Copy into plain byte arrays for simple indexing.
    let x = [UInt8](a), y = [UInt8](b)
    // `diff` collects every difference; start with the length difference (0 if same length).
    var diff: UInt = UInt(x.count ^ y.count)
    // Always loop over the longer length so timing does not reveal where bytes differ.
    let n = max(x.count, y.count)
    var i = 0
    while i < n {
        // Treat missing bytes as 0 when one input is shorter.
        let l: UInt8 = i < x.count ? x[i] : 0
        let r: UInt8 = i < y.count ? y[i] : 0
        // XOR is 0 when equal; OR-ing accumulates any difference seen.
        diff |= UInt(l ^ r)
        i += 1
    }
    // Equal only if no difference was ever recorded.
    return diff == 0
}

// MARK: - Typed pairing code

/// Reasons a pairing code or QR payload can be rejected.
public enum PairingCodeError: Error, Equatable, Sendable {
    // badLength: wrong number of characters. badCharacter: a character not in the code alphabet.
    // badQRPayload: the QR text was malformed (wrong parts, wrong sizes, bad encoding).
    case badLength, badCharacter, badQRPayload
}

/// 10-char Crockford base32 pairing code (50 bits). Never printed by description.
public struct PairingCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The 32 allowed characters (digits and letters without I, L, O, U).
    public static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    /// How many characters a code has.
    public static let length = 10
    /// 10 characters x 5 bits per character.
    public static let bitsOfEntropy = 50

    /// Canonical 10 uppercase characters, no separator.
    public let text: String

    /// Private so a code can only come from `generate` or a successful parse.
    private init(canonical: String) { self.text = canonical }

    /// Generate using the system CSPRNG.
    /// (CSPRNG = cryptographically secure random number generator, safe for secrets.)
    public static func generate() -> PairingCode {
        var g = SystemRandomNumberGenerator()
        return generate(using: &g)
    }

    /// Generator injectable for tests only; production callers use `generate()`.
    public static func generate<G: RandomNumberGenerator>(using g: inout G) -> PairingCode {
        var s = ""
        // Pick 10 random characters; 0..<32 matches the alphabet size so every pick is equally likely.
        for _ in 0..<length { s.append(alphabet[Int.random(in: 0..<32, using: &g)]) }
        return PairingCode(canonical: s)
    }

    /// Parse user input: case-insensitive, ignores '-' and spaces, maps O->0 and I/L->1 (Crockford).
    public init(parsing input: String) throws {
        var out = ""
        // Uppercase everything and skip the separators people may type.
        for ch in input.uppercased() where ch != "-" && ch != " " {
            switch ch {
            // Common look-alike mistakes are corrected instead of rejected.
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                // Anything else must be a real alphabet character.
                guard Self.alphabet.contains(ch) else { throw PairingCodeError.badCharacter }
                out.append(ch)
            }
        }
        // After cleanup there must be exactly 10 characters.
        guard out.count == Self.length else { throw PairingCodeError.badLength }
        self.text = out
    }

    /// "XXXXX-XXXXX" for display.
    public var displayString: String {
        // Split the 10 characters into two groups of 5 for easier reading.
        let i = text.index(text.startIndex, offsetBy: 5)
        return text[..<i] + "-" + text[i...]
    }

    /// Canonical bytes (ASCII of `text`) for psk derivation.
    public var bytes: Data { Data(text.utf8) }

    /// True if two codes are the same, compared in constant time.
    public func matches(_ other: PairingCode) -> Bool { constantTimeEquals(bytes, other.bytes) }

    /// Printing a code (for example in logs) shows a placeholder, never the secret.
    public var description: String { "PairingCode(redacted)" }
    public var debugDescription: String { "PairingCode(redacted)" }
}

// MARK: - QR payload

/// QR payload: 128-bit secret + SHA-256 fingerprint of host static public key + LAN address hint.
/// Wire string: `LNT1.<b64url secret>.<b64url fingerprint>.<b64url utf8 hint>`
///
/// The fingerprint lets the phone check it is talking to the right host (a man-in-the-middle
/// would have a different key and so a different fingerprint). The address hint just tells the
/// phone where on the local network to connect.
public struct PairingQRPayload: Sendable, CustomStringConvertible {
    /// Tag at the start of the QR text so the app can recognise its own format and version.
    public static let prefix = "LNT1"
    public let secret: Data           // 16 bytes
    public let hostFingerprint: Data  // 32 bytes
    public let addressHint: String    // e.g. "192.168.1.20:7777"

    /// Builds a payload, checking that the secret and fingerprint have the exact sizes.
    public init(secret: Data, hostFingerprint: Data, addressHint: String) throws {
        guard secret.count == 16, hostFingerprint.count == 32 else { throw PairingCodeError.badQRPayload }
        self.secret = secret; self.hostFingerprint = hostFingerprint; self.addressHint = addressHint
    }

    /// SHA-256 hash ("fingerprint") of a public key: a short stand-in that identifies the key.
    public static func fingerprint(ofPublicKey key: Data) -> Data { Data(SHA256.hash(data: key)) }

    /// Creates a fresh payload with a new random 16-byte secret for the given host key.
    public static func generate(hostPublicKey: Data, addressHint: String) -> PairingQRPayload {
        var g = SystemRandomNumberGenerator()
        // 16 random bytes = 128 bits of secret.
        let secret = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) })
        // sizes are fixed, so this cannot throw
        return try! PairingQRPayload(secret: secret, hostFingerprint: fingerprint(ofPublicKey: hostPublicKey), addressHint: addressHint)
    }

    /// Turns the payload into the text that goes inside the QR image.
    public func encoded() -> String {
        // Four dot-separated parts: prefix, secret, fingerprint, address hint.
        [Self.prefix, Self.b64(secret), Self.b64(hostFingerprint), Self.b64(Data(addressHint.utf8))].joined(separator: ".")
    }

    /// Reads QR text back into a payload; throws if anything is off.
    public init(parsing s: String) throws {
        // Split on dots, keeping empty pieces so a malformed string is noticed.
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // Need exactly 4 parts, the right prefix, valid base64url in each, valid text, and a short hint.
        guard parts.count == 4, parts[0] == Self.prefix,
              let sec = Self.unb64(parts[1]), let fp = Self.unb64(parts[2]), let hint = Self.unb64(parts[3]),
              let hintStr = String(data: hint, encoding: .utf8), hintStr.utf8.count <= 128
        else { throw PairingCodeError.badQRPayload }
        // The designated init re-checks the secret and fingerprint sizes.
        try self.init(secret: sec, hostFingerprint: fp, addressHint: hintStr)
    }

    /// True if the host key presented over the wire matches the QR fingerprint (constant time).
    public func matchesHostKey(_ publicKey: Data) -> Bool {
        constantTimeEquals(hostFingerprint, Self.fingerprint(ofPublicKey: publicKey))
    }

    /// Never prints the secret.
    public var description: String { "PairingQRPayload(redacted)" }

    /// Base64url encode: standard base64 with + -> -, / -> _, and the "=" padding removed.
    private static func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    /// Reverses `b64`: restore the standard characters and padding, then decode. Nil if invalid.
    private static func unb64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // Base64 length must be a multiple of 4, so re-add the "=" padding.
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t)
    }
}
