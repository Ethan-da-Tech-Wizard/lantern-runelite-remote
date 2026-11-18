// ==============================================================================
// Program: InputGate.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Host-side rate limiting, held-button tracking, and staleness safety validation for input.
//          Inputs: Inbound InputEvents received from remote client over network.
//          Outputs: Validated and sanitized InputEvents approved for hardware injection.
//          Design Rationale: Rate-limits clicks and movements to human-plausible thresholds, preventing
//          bot-like bursts and ensuring held mouse buttons/keys are cleanly auto-released on disconnect.
// ==============================================================================
// =====================================================================================
// InputGate.swift
//
// PURPOSE
//   The host-side "bouncer" for input events. Before the host moves the mouse or presses a key
//   on behalf of the phone, each event must pass three checks:
//     1. RATE LIMIT  - not too many events too fast.
//     2. STATE       - the event makes sense (for example no drag-move without a drag-start).
//     3. FRESHNESS   - the event is not stale (old events from a stalled link are dropped).
//
// WHO CALLS IT
//   The host session code calls `HostInputGate.admit` for every decoded input event, and
//   `releaseAll` when the phone disconnects so no mouse button stays stuck down.
//
// KEY IDEAS (in plain English)
//   - "Gating" = letting only valid, timely events through. Excess or stale events are simply
//     dropped, never queued and replayed later (replaying old clicks could do something the
//     user no longer intends).
//   - All functions take the current time as an argument instead of reading the clock, which
//     makes them predictable and easy to test.
//   - Times are in milliseconds ("Ms").
// =====================================================================================

import Foundation

// MARK: - Rate limiter

/// Host-side rate limiter. Pure function of supplied time; no timers, no queue: excess events are dropped.
public struct InputRateLimiter: Sendable {
    /// Categories of events that are limited separately (each class has its own minimum spacing).
    public enum EventClass: Int, CaseIterable, Sendable { case tap, longPress, dragStart, dragMove, scroll, zoom, key, camStart, camMove }

    /// Which class an event belongs to, or nil if it is never limited.
    public static func eventClass(_ e: InputEvent) -> EventClass? {
        switch e {
        case .tap: return .tap
        case .longPress: return .longPress
        case .dragStart: return .dragStart
        case .dragMove: return .dragMove
        case .dragEnd: return nil          // never limited: it only releases a held button
        case .scroll: return .scroll
        case .zoom: return .zoom
        case .key: return .key
        case .camStart: return .camStart
        case .camMove: return .camMove
        case .camEnd: return nil           // never limited: it only releases the held middle button
        }
    }

    /// Minimum gap between two events of the same class.
    public let minSpacingMs: UInt64
    /// Camera drag moves may come faster than other classes so rotation feels smooth.
    public static let camMoveSpacingMs: UInt64 = 20
    /// Global cap over all classes (except dragEnd and camEnd, which are never limited): at most `globalMax` admitted events per `globalWindowMs`.
    public let globalMax: Int
    public let globalWindowMs: UInt64
    /// When each class was last admitted.
    private var last: [EventClass: UInt64] = [:]
    /// Timestamps of recently admitted events (for the global cap).
    private var admitted: [UInt64] = []
    /// How many events were dropped so far (for diagnostics).
    public private(set) var droppedCount = 0
    public init(minSpacingMs: UInt64 = 50, globalMax: Int = 40, globalWindowMs: UInt64 = 1000) {
        self.minSpacingMs = minSpacingMs; self.globalMax = globalMax; self.globalWindowMs = globalWindowMs
    }

    /// Returns true if the event may be injected now. A dropped event does not advance the clock.
    public mutating func allow(_ e: InputEvent, nowMs: UInt64) -> Bool {
        // Unlimited classes always pass.
        guard let c = Self.eventClass(e) else { return true }
        // Camera moves use the shorter gap.
        let spacing = c == .camMove ? Self.camMoveSpacingMs : minSpacingMs
        // Too soon after the last event of this class (or the clock went backwards): drop.
        if let l = last[c], nowMs < l || nowMs - l < spacing { droppedCount += 1; return false }
        // Forget admitted timestamps that fell out of the window (and any that are in the "future").
        admitted.removeAll { nowMs >= $0 ? nowMs - $0 >= globalWindowMs : true }
        // Already at the global cap for this window: drop.
        if admitted.count >= globalMax { droppedCount += 1; return false }
        // Accept: remember when.
        admitted.append(nowMs)
        last[c] = nowMs
        return true
    }
}

// MARK: - Held-button tracking

/// The mouse buttons this system can hold down.
public enum HeldButton: Equatable, Sendable { case left, middle }

/// Tracks held buttons so `releaseAll` can emit the needed mouse-ups on disconnect.
public struct HeldInputState: Sendable {
    /// 0 = left button held (normal drag), 1 = middle button held (camera drag).
    public private(set) var held: Set<Int> = []
    public init() {}
    /// True during a normal drag.
    public var isDragging: Bool { held.contains(0) }
    /// True during a camera drag.
    public var isCamDragging: Bool { held.contains(1) }

    /// Validates the event against state (drag sequence) and updates it. False = reject.
    public mutating func admit(_ e: InputEvent) -> Bool {
        switch e {
        case .camStart:
            if isDragging || isCamDragging { return false }     // one held button at a time
            held.insert(1); return true
        // A camera move only makes sense during a camera drag.
        case .camMove: return isCamDragging
        case .camEnd:
            if !isCamDragging { return false }
            held.remove(1); return true
        case .dragStart:
            if isDragging || isCamDragging { return false }
            held.insert(0); return true
        // A drag move only makes sense during a drag.
        case .dragMove: return isDragging
        case .dragEnd:
            if !isDragging { return false }
            held.remove(0); return true
        case .tap, .longPress: return !isDragging && !isCamDragging     // no clicks mid-drag
        // Scroll, zoom and key do not depend on drag state.
        default: return true
        }
    }

    /// Returns buttons that must be released and clears state.
    public mutating func releaseAll() -> [HeldButton] {
        // `defer` clears the set after the return value is computed.
        defer { held.removeAll() }
        var r: [HeldButton] = []
        if held.contains(0) { r.append(.left) }
        if held.contains(1) { r.append(.middle) }
        return r
    }
}

// MARK: - Freshness

/// Staleness check for INPUT (docs/03 rule 3: "dropped if the link stalls, never replayed").
/// The sender stamps each event with its monotonic clock (u32 ms, wraps). The two clocks are unrelated, so
/// the host tracks the smallest observed offset (host_now - sent) over a rotating 60 s window as the
/// "no queueing delay" baseline; an event whose offset exceeds the baseline by more than `maxAgeMs` is stale.
/// Rotating the minimum absorbs clock drift (100 ppm = 6 ms per minute).
public struct InputFreshness: Sendable {
    /// An event this much slower than the fastest recent event is considered stale.
    public static let maxAgeMs: Int64 = 250
    /// Length of one "bucket" of minimum tracking; two buckets (current + previous) give the 60 s window.
    static let rotateMs: UInt64 = 30_000
    /// Smallest offset in the current bucket and in the previous bucket.
    private var cur: UInt32?, prev: UInt32?
    /// When the current bucket began.
    private var curStart: UInt64 = 0

    public init() {}

    /// The smaller of two wrapping 32-bit offsets (compared as signed difference so wraparound works).
    private static func lower(_ a: UInt32, _ b: UInt32) -> UInt32 { Int32(bitPattern: a &- b) <= 0 ? a : b }

    /// Age of the event in ms relative to the fastest recently seen event (0 for the first ever event).
    public mutating func age(sentMs: UInt32, nowMs: UInt64) -> Int64 {
        // Offset between the host clock and the sender clock (wrapping subtraction in 32 bits).
        let off = UInt32(truncatingIfNeeded: nowMs) &- sentMs
        // Very first event: start the first bucket now.
        if cur == nil && prev == nil { curStart = nowMs }
        // Bucket is old enough: current becomes previous, start a new current.
        if nowMs >= curStart, nowMs - curStart >= Self.rotateMs { prev = cur; cur = nil; curStart = nowMs }
        // Update the current bucket's minimum with this event's offset.
        let c = cur.map { Self.lower($0, off) } ?? off
        cur = c
        // Baseline is the smaller of the previous and current minimums.
        let base = prev.map { Self.lower($0, c) } ?? c
        // Age = how much this event's offset exceeds the baseline.
        return Int64(Int32(bitPattern: off &- base))
    }
}

// MARK: - The combined gate

/// Limiter + state, the single host-side admission point.
public struct HostInputGate: Sendable {
    public var limiter: InputRateLimiter
    public private(set) var state = HeldInputState()
    public private(set) var freshness = InputFreshness()
    /// How many events were dropped for being stale.
    public private(set) var staleDropped = 0
    public init(minSpacingMs: UInt64 = 50, globalMax: Int = 40) {
        limiter = InputRateLimiter(minSpacingMs: minSpacingMs, globalMax: globalMax)
    }

    /// `sentMs` is the sender's monotonic stamp; events older than 250 ms are dropped, never injected late.
    /// A late dragEnd or camEnd is still admitted (they only release a held button) so a stall cannot leave a button down.
    public mutating func admit(_ e: InputEvent, nowMs: UInt64, sentMs: UInt32) -> Bool {
        let age = freshness.age(sentMs: sentMs, nowMs: nowMs)
        if age > InputFreshness.maxAgeMs {
            // Stale: only the two "release" events may continue; everything else is dropped and counted.
            switch e { case .dragEnd, .camEnd: break; default: staleDropped += 1; return false }
        }
        return admit(e, nowMs: nowMs)
    }

    /// Checks state and rate (without the freshness test).
    public mutating func admit(_ e: InputEvent, nowMs: UInt64) -> Bool {
        // Check state on a copy first so a rate-limit drop does not alter state, and vice versa.
        var s = state
        guard s.admit(e) else { return false }
        guard limiter.allow(e, nowMs: nowMs) else { return false }
        // Both checks passed: commit the new state.
        state = s
        return true
    }
    /// Lists buttons to release (call on disconnect) and clears the held state.
    public mutating func releaseAll() -> [HeldButton] { state.releaseAll() }
}
