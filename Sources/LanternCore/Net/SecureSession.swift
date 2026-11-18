// =====================================================================================
// SecureSession.swift
//
// PURPOSE: The encrypted conversation after the handshake is finished. It seals (encrypts) outgoing
// messages into UDP datagrams, opens (decrypts) incoming ones, rejects replayed or forged packets,
// and adds a small "reliable delivery" layer on top of UDP for input and control messages.
//
// WHO CALLS IT: HostServer and ClientConnection each keep one SecureSession per connected peer and
// call send helpers (unreliable / reliable / videoFrame), `receive` for each incoming packet and
// `tick` on their timers.
//
// KEY IDEAS FOR A BEGINNER:
//  - UDP may lose, duplicate or reorder packets. Video tolerates loss (a missing frame is skipped).
//    Taps and control messages must not be lost, so they get ACKs and are re-sent until acknowledged.
//  - AEAD encryption (the Noise cipher state) both hides the content and detects tampering.
//  - Every packet carries a counter used as the encryption nonce; a "replay window" remembers which
//    counters were already seen so an attacker cannot re-send a recorded packet.
//  - A struct that is `mutating` changes its own state; nothing here is thread-safe, so the owner
//    (host or client) calls it from one serial queue only.
// =====================================================================================

import Foundation
// CryptoKit supplies the cipher used by NoiseCipherState (defined elsewhere in this module).
import CryptoKit

/// Transport-independent encrypted session: AEAD DATA datagrams, replay window, lossy video,
/// reliable (ACK + retransmit + in-order, deduplicated) input/control. Not thread-safe; the owner serialises.
///
/// Reliable delivery: flags bit0 marks a message as needing an ACK; `seq` is a per-direction
/// reliable sequence starting at 0. Receiver delivers strictly in order and de-duplicates.
/// Video and PING/ACK/BYE are unreliable.
struct SecureSession: Sendable {
    /// Bit 0 of the flags byte: "this message needs an ACK".
    static let flagReliable: UInt8 = 0x01
    /// How many sequence numbers ahead of the next expected one we are willing to hold in memory.
    static let reorderWindow: UInt32 = 256

    /// What `receive` hands back to the owner after a packet is accepted: a video frame, an input event,
    /// a control message, or a goodbye.
    enum Delivered: Sendable, Equatable {
        case video(VideoFrame)
        case input(InputEvent, sentMs: UInt32)
        case control(ControlMessage)
        case bye
    }
    /// The reasons a datagram may be rejected (the owner turns these into counters).
    enum Drop: Sendable, Equatable { case malformed, wrongSession, replay, auth }
    /// Outcome of processing one incoming datagram.
    struct Result: Sendable {
        // Messages that are ready for the app, in order.
        var delivered: [Delivered] = []
        // Datagrams we must send back (ACKs).
        var replies: [Data] = []
        // Set if the packet was dropped, saying why.
        var drop: Drop?
        // True if the video decoder seems to have lost sync and a keyframe should be requested.
        var wantKeyframe = false
    }

    /// Short id of this session, put in every packet so stray packets can be recognised.
    let sessionID: UInt32
    /// One cipher state for each direction: one only encrypts, the other only decrypts.
    private var sendCipher: NoiseCipherState
    private var recvCipher: NoiseCipherState
    /// Remembers the packet counters already used, to block replays.
    private var replay = ReplayWindow()
    /// Next packet counter to send (also the encryption nonce); must never repeat with the same key.
    private var sendCounter: UInt64 = 0
    /// Sequence number for unreliable messages (they are not ACKed or ordered).
    private var unreliableSeq: UInt32 = 0
    /// Sequence number for the next reliable message, starting at 0.
    private var reliableSeq: UInt32 = 0
    /// Next reliable sequence number we expect to deliver to the app.
    private var nextExpected: UInt32 = 0
    /// Reliable messages that arrived early (out of order), waiting for the missing ones.
    private var buffered: [UInt32: (msg: ChannelMessage, sentMs: UInt32)] = [:]
    /// A reliable message we sent and are still waiting to hear an ACK for, with its retry schedule.
    private struct Unacked { var msg: ChannelMessage; var sentMs: UInt32; var nextSend: Date; var tries: Int }
    /// All messages currently waiting for an ACK, keyed by reliable sequence number.
    private var unacked: [UInt32: Unacked] = [:]
    /// Puts video fragments back together into whole frames.
    private var reassembler = VideoReassembler()
    /// Number of the next video frame we send.
    private var frameID: UInt32 = 0
    /// Timing and limit settings.
    private let cfg: NetConfig
    // When we last got a valid packet (used for the idle timeout). Readable from outside, settable only here.
    private(set) var lastReceive: Date
    /// When we last sent a keepalive PING.
    private var lastPingSent: Date
    /// When we last asked for a keyframe, to avoid asking too often.
    private var lastIDRRequest = Date.distantPast
    // Drop counters for this session.
    private(set) var stats = NetStats()

    /// Create a session from the two cipher states that the handshake produced.
    init(send: NoiseCipherState, receive: NoiseCipherState, sessionID: UInt32, config: NetConfig, now: Date) {
        self.sendCipher = send; self.recvCipher = receive; self.sessionID = sessionID
        self.cfg = config; self.lastReceive = now; self.lastPingSent = now
    }

    /// How many reliable messages are still waiting for an ACK.
    var unackedCount: Int { unacked.count }

    // MARK: send

    /// Encrypt one message and wrap it in a DATA datagram.
    /// Steps: encode the message bytes, encrypt them with the next counter, bump the counter, frame the result.
    /// The session id is passed as "associated data": not hidden, but any change to it makes decryption fail.
    private mutating func seal(_ m: ChannelMessage, seq: UInt32, flags: UInt8, sentMs: UInt32 = 0) throws -> Data {
        let pt = try ChannelMessage.encode(m, seq: seq, flags: flags, sentMs: sentMs)
        let ctr = sendCounter
        let sealed = try sendCipher.encrypt(pt, ad: FrameCodec.dataAAD(sessionID: sessionID), counter: ctr)
        sendCounter += 1
        return try FrameCodec.encode(.data(sessionID: sessionID, counter: ctr, sealed: Array(sealed)))
    }

    /// Send something that need not arrive (video, ping, ACK). It is sent once, with no flags.
    mutating func unreliable(_ m: ChannelMessage, sentMs: UInt32 = 0) throws -> Data {
        // Wrapping add (`&+=`) so the counter rolls over instead of crashing.
        unreliableSeq &+= 1
        return try seal(m, seq: unreliableSeq, flags: 0, sentMs: sentMs)
    }

    /// Send something that must arrive (input end events, control messages). It is remembered until ACKed.
    mutating func reliable(_ m: ChannelMessage, now: Date, sentMs: UInt32 = 0) throws -> Data {
        // Refuse if too many messages are already waiting, so memory cannot grow without bound.
        guard unacked.count < cfg.maxUnacked else { throw LanternNetError.sendQueueFull }
        // Take the next reliable sequence number.
        let seq = reliableSeq; reliableSeq &+= 1
        // Send it with the reliable flag set so the receiver knows to ACK.
        let d = try seal(m, seq: seq, flags: Self.flagReliable, sentMs: sentMs)
        // Remember it so `tick` can re-send it if no ACK comes.
        unacked[seq] = Unacked(msg: m, sentMs: sentMs, nextSend: now.addingTimeInterval(cfg.reliableRetransmit), tries: 1)
        return d
    }

    /// Split one encoded video frame into fragments that fit in packets and send each one unreliably.
    /// A lost fragment just means that frame is dropped; the decoder asks for a keyframe to recover.
    mutating func videoFrame(_ annexB: Data, isKeyframe: Bool, ptsUs: UInt64) throws -> [Data] {
        // Give this frame its number and advance the counter.
        let id = frameID; frameID &+= 1
        // Cut the frame into fragments.
        let frags = try VideoFragmenter.fragment(frameID: id, ptsUs: ptsUs, isKeyframe: isKeyframe, annexB: annexB)
        // Encrypt each fragment as its own datagram.
        return try frags.map { try unreliable(.video($0)) }
    }

    /// Periodic work, called by the owner's timer: retransmits, keepalive. `failed` means a reliable message ran out of tries.
    /// The third value `idle` is true when nothing has been heard for longer than the idle timeout.
    /// Periodic work: retransmits, keepalive. `failed` means a reliable message ran out of tries.
    mutating func tick(now: Date) -> (datagrams: [Data], failed: Bool, idle: Bool) {
        // Datagrams to send this round.
        var out: [Data] = []
        var failed = false
        // Go through every message still waiting for an ACK whose retry time has come.
        for (seq, var u) in unacked where now >= u.nextSend {
            // Out of tries: flag failure and do not send again.
            if u.tries >= cfg.reliableMaxTries { failed = true; continue }
            // Re-encrypt with a fresh counter (never reuse a counter) and queue it.
            if let d = try? seal(u.msg, seq: seq, flags: Self.flagReliable, sentMs: u.sentMs) {
                out.append(d); stats.retransmits += 1
            }
            // Count one more try and schedule the next one.
            u.tries += 1; u.nextSend = now.addingTimeInterval(cfg.reliableRetransmit)
            unacked[seq] = u
        }
        // Send a PING if we have been quiet for the keepalive interval, so the peer knows we are alive.
        if now.timeIntervalSince(lastPingSent) >= cfg.keepaliveInterval {
            lastPingSent = now
            if let d = try? unreliable(.control(.ping)) { out.append(d) }
        }
        // Report the new datagrams, whether a reliable message failed, and whether the link looks dead.
        return (out, failed, now.timeIntervalSince(lastReceive) > cfg.idleTimeout)
    }

    // MARK: receive

    /// Process one incoming datagram. Checks run cheapest first: parse, session id, replay window, decrypt.
    /// Any failure is counted and returned in `drop`; nothing is delivered.
    mutating func receive(_ datagram: Data, now: Date) -> Result {
        var res = Result()
        // Must parse as a DATA frame; otherwise it is junk.
        guard case .data(let sid, let ctr, let sealed)? = try? FrameCodec.decode(datagram) else {
            stats.malformedDrops += 1; res.drop = .malformed; return res
        }
        // Packet belongs to a different session.
        guard sid == sessionID else { stats.wrongSessionDrops += 1; res.drop = .wrongSession; return res }
        // Quick check whether this counter was already used (does not record it yet).
        guard replay.check(ctr) == .ok else { stats.replayDrops += 1; res.drop = .replay; return res }
        // Decrypt and check authenticity. A forged or altered packet fails here.
        let pt: Data
        do { pt = try recvCipher.decrypt(Data(sealed), ad: FrameCodec.dataAAD(sessionID: sid), counter: ctr) }
        catch { stats.authDrops += 1; res.drop = .auth; return res }
        // Only now, after authentication succeeded, record the counter as used. This stops an attacker burning counters with fake packets.
        replay.commit(ctr)
        // Decode the inner message: its body, sequence number, flags and the sender's timestamp.
        guard let (msg, seq, flags, sentMs) = try? ChannelMessage.decodeStamped(pt) else {
            stats.malformedDrops += 1; res.drop = .malformed; return res
        }
        // We heard from the peer: reset the idle timer.
        lastReceive = now
        // Reliable path: ordered, de-duplicated, and acknowledged.
        if flags & Self.flagReliable != 0 {
            // Always ACK (even duplicates) so the sender stops retransmitting.
            if let a = try? unreliable(.control(.ack(seq: seq))) { res.replies.append(a) }
            // Distance of this seq ahead of the next one we expect. Wrapping subtraction handles number roll-over;
            // a huge result really means "behind us".
            let ahead = seq &- nextExpected
            if ahead >= 0x8000_0000 { return res }              // already delivered: duplicate
            if ahead >= Self.reorderWindow { return res }       // too far ahead: sender will retry
            // Store it, then hand over every message that is now consecutive, in order.
            buffered[seq] = (msg, sentMs)
            while let m = buffered.removeValue(forKey: nextExpected) {
                nextExpected &+= 1
                deliver(m.msg, sentMs: m.sentMs, into: &res)
            }
        // Unreliable path: deliver straight away.
        } else {
            deliver(msg, sentMs: sentMs, into: &res)
        }
        // If the video re-assembler saw missing data, ask for a keyframe, but not more than every 0.25 s.
        if reassembler.takeKeyframeRequest(), now.timeIntervalSince(lastIDRRequest) > 0.25 {
            lastIDRRequest = now
            res.wantKeyframe = true
        }
        return res
    }

    /// Route a decoded message to the right output. ACKs remove the message from the waiting list; PING needs nothing.
    private mutating func deliver(_ m: ChannelMessage, sentMs: UInt32, into res: inout Result) {
        switch m {
        case .video(let f):
            // Video: only yields a frame when all its fragments have arrived.
            if let r = reassembler.ingest(f) {
                res.delivered.append(.video(VideoFrame(data: r.annexB, isKeyframe: r.isKeyframe, ptsUs: r.ptsUs, frameID: r.frameID)))
            }
        // Input event: pass up with the sender's timestamp (the host uses it to ignore stale taps).
        case .input(let e): res.delivered.append(.input(e, sentMs: sentMs))
        // Control message: handle internally if it is ACK/PING/BYE, otherwise pass up.
        case .control(let c):
            switch c {
            // ACK: the peer got message `s`, so stop re-sending it.
            case .ack(let s): unacked[s] = nil
            // PING only keeps the link alive; the idle timer was already reset in `receive`.
            case .ping: break
            // BYE: the peer is closing.
            case .bye: res.delivered.append(.bye)
            default: res.delivered.append(.control(c))
            }
        }
    }
}
