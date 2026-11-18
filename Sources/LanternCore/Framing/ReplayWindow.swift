// ==============================================================================
// Program: ReplayWindow.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Sliding-window packet replay protection filter for packet sequence numbers.
//          Inputs: 64-bit sequence numbers from inbound encrypted datagrams.
//          Outputs: Boolean acceptance verdict (accept new packet vs drop duplicate/stale packet).
//          Design Rationale: Constant-time bitmask sliding window guards against UDP packet duplication
//          and replay attacks with zero heap allocations.
// ==============================================================================
// =====================================================================================
// ReplayWindow.swift
//
// PURPOSE
//   Stops "replay attacks": an attacker who recorded a valid encrypted packet cannot send it
//   again and have it accepted. We remember which packet numbers (counters) were already seen.
//
// WHO CALLS IT
//   The secure session code calls `check` before decrypting a packet and `commit` after the
//   packet decrypts successfully.
//
// KEY IDEAS (in plain English)
//   - SLIDING WINDOW: we track the highest counter seen and a bitmap (one bit per counter) for
//     the 2048 numbers just below it. New numbers slide the window forward. Numbers older than
//     the window are rejected, because we can no longer tell whether they are repeats.
//   - UDP packets can arrive out of order, so we cannot require strictly increasing counters;
//     the window allows modest reordering while still blocking duplicates.
//   - A counter is recorded only AFTER the packet authenticates, so forged packets cannot
//     move the window.
//   (A similar window also exists in NoiseCipher.swift; this one reports WHY a counter was refused.)
// =====================================================================================

import Foundation

/// 2048-packet sliding replay window keyed by counter (docs/01 sec. 5).
/// Use `check` before decrypt and `commit` only after a successful decrypt.
public struct ReplayWindow: Sendable {
    /// How many counters the window covers.
    public static let size = 2048
    /// The possible answers for a counter.
    public enum Verdict: Equatable, Sendable { case ok, duplicate, tooOld, reserved }

    /// Highest counter accepted so far (nil before the first packet).
    private var highest: UInt64?
    /// The bitmap of seen counters, 64 per word.
    private var bits = [UInt64](repeating: 0, count: ReplayWindow.size / 64)
    public init() {}

    /// Looks at a counter without changing anything.
    public func check(_ n: UInt64) -> Verdict {
        // The all-ones counter is reserved and never valid.
        if n == UInt64.max { return .reserved }
        // First packet ever: fine.
        guard let h = highest else { return .ok }
        // Newer than anything seen: fine.
        if n > h { return .ok }
        // Behind the window: cannot verify, so reject.
        if h - n >= UInt64(Self.size) { return .tooOld }
        // Inside the window: duplicate if its bit is set.
        return isSet(n) ? .duplicate : .ok
    }

    /// Record a counter whose packet authenticated. Returns the verdict it had (no change unless .ok).
    @discardableResult
    public mutating func commit(_ n: UInt64) -> Verdict {
        let v = check(n)
        guard v == .ok else { return v }
        if let h = highest, n > h {
            // The window must slide forward by `gap`.
            let gap = n - h
            if gap >= UInt64(Self.size) {
                // Jumped past everything we remember: wipe the whole bitmap.
                for i in bits.indices { bits[i] = 0 }
            } else {
                // Clear the slots we are advancing into; they held flags for much older counters.
                for k in 1...Int(gap) { clear(h &+ UInt64(k)) }
            }
            highest = n
        } else if highest == nil {
            // Very first counter.
            highest = n
        }
        // Mark this counter as seen.
        set(n)
        return .ok
    }

    /// Maps a counter to (bitmap word index, bit mask); the modulo makes the bitmap circular.
    private func idx(_ n: UInt64) -> (Int, UInt64) {
        let i = Int(n % UInt64(Self.size))
        return (i / 64, 1 << UInt64(i % 64))
    }
    private func isSet(_ n: UInt64) -> Bool { let (w, m) = idx(n); return bits[w] & m != 0 }
    private mutating func set(_ n: UInt64) { let (w, m) = idx(n); bits[w] |= m }
    private mutating func clear(_ n: UInt64) { let (w, m) = idx(n); bits[w] &= ~m }
}
