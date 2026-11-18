// Program: Lantern - SAS.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Short authentication string: digits both devices can compare to confirm they paired with each other.
//
// =====================================================================================
// SAS.swift
//
// PURPOSE
//   Makes a "Short Authentication String": a few digits both screens can show so a person
//   can glance at both devices and confirm they match.
//
// WHO CALLS IT
//   The pairing UI on both phone and host calls `derive` with the finished handshake hash and
//   shows the result via `display`.
//
// KEY IDEAS (in plain English)
//   - The handshake hash is a fingerprint of the whole conversation. If an attacker sat in the
//     middle, the two sides would have different hashes and therefore different digits.
//   - We shrink the long hash into a short number a human can compare.
// =====================================================================================

import Foundation
import CryptoKit

/// Short authentication string from the Noise handshake hash, for optional visual comparison.
public enum SAS {
    /// A fixed label mixed into the key derivation so these digits are only usable for this purpose.
    static let info = Data("twu-stream-pair-v1 sas".utf8)

    /// Deterministic decimal string (default 6 digits) via HKDF-SHA256 over the handshake hash.
    /// "Deterministic" = the same input always gives the same digits on both devices.
    public static func derive(handshakeHash: Data, digits: Int = 6) -> String {
        // Keep the digit count between 4 and 9 so it fits comfortably in a 64-bit number.
        let n = min(max(digits, 4), 9)
        // Stretch/derive 8 bytes of key material from the hash.
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: handshakeHash),
                                         salt: Data(), info: info, outputByteCount: 8)
        // Combine the 8 bytes into one 64-bit integer (big-endian: shift left 8, add next byte).
        let v = okm.withUnsafeBytes { $0.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
        // Compute 10^n by repeated multiplication.
        var mod: UInt64 = 1
        for _ in 0..<n { mod *= 10 }
        // Remainder after dividing by 10^n gives exactly n decimal digits (possibly with leading zeros).
        let s = String(v % mod)
        // Pad with zeros on the left so the length is always n.
        return String(repeating: "0", count: n - s.count) + s
    }

    /// "123 456" display grouping.
    public static func display(_ sas: String) -> String {
        // Only split when it divides evenly (or is the usual 6); otherwise show as is.
        guard sas.count % 2 == 0 || sas.count == 6 else { return sas }
        // Insert a space in the middle.
        let h = sas.index(sas.startIndex, offsetBy: sas.count / 2)
        return sas[..<h] + " " + sas[h...]
    }
}
