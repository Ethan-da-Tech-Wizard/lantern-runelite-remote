// =====================================================================================
// VideoReassembly.swift
//
// PURPOSE
//   Cuts each encoded video frame into packet-sized pieces on the sending side
//   (`VideoFragmenter`) and glues the pieces back together on the receiving side
//   (`VideoReassembler`), tolerating lost or out-of-order packets.
//
// WHO CALLS IT
//   The host's video sender calls `VideoFragmenter.fragment` for each encoded frame.
//   The phone's receiver feeds every arriving `VideoFragment` to `VideoReassembler.ingest`
//   and sends a keyframe request (REQUEST_IDR) when `takeKeyframeRequest` says so.
//
// KEY IDEAS (in plain English)
//   - A frame is bigger than one network packet (about 1200 bytes max), so it is split up.
//   - ANNEX-B is the byte format of H.264 video units; we treat it as opaque bytes here.
//   - If any piece is lost, the frame is useless, and later frames may depend on it. So the
//     receiver asks for a KEYFRAME (a complete picture) to recover.
//   - Frame IDs are 32-bit and wrap around; comparisons use "serial number arithmetic" so the
//     wrap does not break ordering.
// =====================================================================================

import Foundation

/// Splits one Annex-B access unit into MTU-safe fragments.
/// (MTU = the largest packet the network will carry without breaking it up.)
public enum VideoFragmenter {
    /// Returns the pieces of one frame, in order, each carrying the frame's shared info.
    public static func fragment(frameID: UInt32, ptsUs: UInt64, isKeyframe: Bool,
                                annexB: Data, maxData: Int = VideoFragment.maxData) throws -> [VideoFragment] {
        // Piece size must be sensible and the frame must not be empty.
        guard maxData > 0, maxData <= VideoFragment.maxData, !annexB.isEmpty else { throw FramingError.badValue }
        let bytes = Array(annexB)
        // Number of pieces = ceiling of size / pieceSize.
        let n = (bytes.count + maxData - 1) / maxData
        guard n <= VideoFragment.maxFragments else { throw FramingError.tooLarge }
        // Build piece i from the byte range [lo, hi).
        return (0..<n).map { i in
            let lo = i * maxData, hi = min(lo + maxData, bytes.count)
            return VideoFragment(frameID: frameID, index: UInt16(i), count: UInt16(n), ptsUs: ptsUs,
                                 isKeyframe: isKeyframe, data: Array(bytes[lo..<hi]))
        }
    }
}

/// A fully rebuilt frame, ready to decode.
public struct ReassembledFrame: Equatable, Sendable {
    public var frameID: UInt32
    public var ptsUs: UInt64
    public var isKeyframe: Bool
    public var annexB: Data
}

/// Loss-tolerant reassembler: incomplete frames are dropped when a newer frame completes or
/// the pending set overflows; every drop (or frame-id gap) raises the keyframe-request flag.
public struct VideoReassembler: Sendable {
    /// How many unfinished frames we keep waiting before throwing the oldest away.
    public static let maxPending = 8
    /// A frame in progress: expected piece count, shared info, and the pieces received so far.
    private struct Pending {
        var count: Int; var pts: UInt64; var key: Bool
        var parts: [Int: [UInt8]] = [:]
    }
    /// Frames being assembled, keyed by frame ID.
    private var pending: [UInt32: Pending] = [:]
    /// ID of the newest frame handed out so far.
    private var lastDelivered: UInt32?
    /// How many frames were thrown away incomplete.
    public private(set) var droppedFrames = 0
    /// Set when something was lost and a keyframe should be requested.
    private var keyframeWanted = false

    public init() {}

    /// Serial-number comparison (wrap-safe): is a newer than b?
    static func newer(_ a: UInt32, than b: UInt32) -> Bool { a != b && (a &- b) < 0x8000_0000 }

    /// True once after any loss; clears on read. Caller sends REQUEST_IDR.
    public mutating func takeKeyframeRequest() -> Bool { defer { keyframeWanted = false }; return keyframeWanted }

    /// Adds one fragment. Returns the finished frame when this fragment completes it, else nil.
    public mutating func ingest(_ f: VideoFragment) -> ReassembledFrame? {
        // Ignore fragments with impossible numbers.
        guard f.count >= 1, Int(f.count) <= VideoFragment.maxFragments, f.index < f.count else { return nil }
        if let last = lastDelivered, !Self.newer(f.frameID, than: last) { return nil }   // stale or dup
        // Find the frame in progress, or start tracking a new one.
        var p = pending[f.frameID] ?? Pending(count: Int(f.count), pts: f.ptsUs, key: f.isKeyframe)
        // All fragments of one frame must agree on count, keyframe flag and timestamp.
        guard p.count == Int(f.count), p.key == f.isKeyframe, p.pts == f.ptsUs else { return nil }
        // Store the piece (a duplicate piece is ignored).
        if p.parts[Int(f.index)] == nil { p.parts[Int(f.index)] = f.data }
        // Still missing pieces: save progress and wait.
        if p.parts.count < p.count {
            pending[f.frameID] = p
            evictIfNeeded()
            return nil
        }
        // complete
        // Join the pieces in index order.
        var out: [UInt8] = []
        for i in 0..<p.count { out.append(contentsOf: p.parts[i] ?? []) }
        pending[f.frameID] = nil
        // Drop older incomplete frames; detect gaps.
        for id in pending.keys where !Self.newer(id, than: f.frameID) {
            pending[id] = nil; droppedFrames += 1; keyframeWanted = true
        }
        // If the frame ID skipped a number, some frame never arrived at all.
        if let last = lastDelivered, f.frameID != last &+ 1 { keyframeWanted = true }   // whole frame never seen
        lastDelivered = f.frameID
        return ReassembledFrame(frameID: f.frameID, ptsUs: p.pts, isKeyframe: p.key, annexB: Data(out))
    }

    /// If too many frames are waiting, discard the oldest ones and ask for a keyframe.
    private mutating func evictIfNeeded() {
        while pending.count > Self.maxPending {
            // The oldest frame is the one that no other pending ID is older than.
            guard let oldest = pending.keys.min(by: { Self.newer($1, than: $0) }) else { return }
            pending[oldest] = nil; droppedFrames += 1; keyframeWanted = true
        }
    }
}
