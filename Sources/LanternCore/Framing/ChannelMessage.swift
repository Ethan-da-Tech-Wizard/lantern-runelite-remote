// ==============================================================================
// Program: ChannelMessage.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Defines inner encrypted channel message types (video fragments, input events, heartbeats).
//          Inputs: Typed payload instances (video slices, input events, control packets).
//          Outputs: Compact binary-encoded channel messages and deserialized typed structures.
//          Design Rationale: Compact binary packing avoids JSON/text serialization overhead to minimize latency.
// ==============================================================================
// =====================================================================================
// ChannelMessage.swift
//
// PURPOSE
//   Defines what goes INSIDE an encrypted DATA packet. After decryption, the bytes are a
//   "channel message": a small header saying which channel it belongs to (video, input or
//   control), followed by that channel's content.
//
// WHO CALLS IT
//   The session code calls `ChannelMessage.encode` before encrypting, and `decode` /
//   `decodeStamped` after decrypting. WireMessage.swift's `FrameCodec` handles the outer layer.
//
// LAYOUT (plaintext of a DATA packet)
//   chan u8 | flags u8 | seq u32 | payload
//
// KEY IDEAS (in plain English)
//   - CHANNELS let one connection carry three kinds of traffic: video (screen picture pieces),
//     input (touches and keys) and control (acks, requests, pings).
//   - A video frame is too big for one packet, so it is cut into FRAGMENTS that the receiver
//     reassembles (see VideoReassembly.swift).
//   - SEQ is a per-message sequence number chosen by the sender.
// =====================================================================================

import Foundation

/// The three kinds of traffic and their wire codes.
public enum Channel: UInt8, Sendable { case video = 0, input = 1, control = 2 }

// MARK: - Control messages

/// Control messages (docs/01 sec. 5, chan 2).
public enum ControlMessage: Equatable, Sendable {
    /// Acknowledge receipt up to a sequence number.
    case ack(seq: UInt32)
    /// Ask for a missing video frame again.
    case nack(frameID: UInt32)
    /// Ask the video sender for a fresh keyframe (a full picture that needs no earlier frames).
    case requestIDR
    /// Tell the phone the size of the captured window.
    case windowInfo(width: UInt16, height: UInt16)
    /// Suggest a new video bitrate.
    case bitrate(UInt32)
    /// "Are you there?" ping.
    case ping
    /// "Goodbye": the sender is closing the session.
    case bye

    /// Writes a type byte (1...7) followed by that message's fields.
    func encode(_ w: inout FrameWriter) {
        switch self {
        case .ack(let s): w.u8(1); w.u32(s)
        case .nack(let f): w.u8(2); w.u32(f)
        case .requestIDR: w.u8(3)
        case .windowInfo(let a, let b): w.u8(4); w.u16(a); w.u16(b)
        case .bitrate(let b): w.u8(5); w.u32(b)
        case .ping: w.u8(6)
        case .bye: w.u8(7)
        }
    }

    /// Reads one control message; throws on unknown type, bad size values or leftover bytes.
    static func decode(_ r: inout FrameReader) throws -> ControlMessage {
        let t = try r.u8()
        let m: ControlMessage
        switch t {
        case 1: m = .ack(seq: try r.u32())
        case 2: m = .nack(frameID: try r.u32())
        case 3: m = .requestIDR
        case 4:
            let w = try r.u16(), h = try r.u16()
            // A zero-size window makes no sense.
            guard w > 0, h > 0 else { throw FramingError.badValue }
            m = .windowInfo(width: w, height: h)
        case 5: m = .bitrate(try r.u32())
        case 6: m = .ping
        case 7: m = .bye
        default: throw FramingError.unknownType(t)
        }
        guard r.remaining == 0 else { throw FramingError.trailingBytes }
        return m
    }
}

// MARK: - Video fragment

/// One video fragment (docs/01 sec. 5, chan 0).
public struct VideoFragment: Equatable, Sendable {
    /// Fragment header size: frameID(4) + index(2) + count(2) + pts(8) + flags(1).
    public static let headerSize = 4 + 2 + 2 + 8 + 1
    /// Most video bytes one fragment can carry after all headers.
    public static let maxData = FrameCodec.maxPlaintext - ChannelHeader.size - headerSize
    /// A frame may be split into at most this many fragments.
    public static let maxFragments = 1024
    /// Bit in the flags byte meaning "this frame is a keyframe".
    public static let flagKeyframe: UInt8 = 0x01

    /// Which video frame this piece belongs to.
    public var frameID: UInt32
    /// This piece's position (0-based) within the frame.
    public var index: UInt16
    /// How many pieces the frame has in total.
    public var count: UInt16
    /// Presentation timestamp in microseconds (when to show the frame).
    public var ptsUs: UInt64
    public var isKeyframe: Bool
    /// The piece of encoded video bytes.
    public var data: [UInt8]
    public init(frameID: UInt32, index: UInt16, count: UInt16, ptsUs: UInt64, isKeyframe: Bool, data: [UInt8]) {
        self.frameID = frameID; self.index = index; self.count = count
        self.ptsUs = ptsUs; self.isKeyframe = isKeyframe; self.data = data
    }
}

/// Size of the channel header: chan(1) + flags(1) + seq(4).
enum ChannelHeader { static let size = 1 + 1 + 4 }

// MARK: - Channel message

/// Decrypted plaintext: `chan u8 | flags u8 | seq u32 | payload`.
public enum ChannelMessage: Equatable, Sendable {
    case video(VideoFragment)
    case input(InputEvent)
    case control(ControlMessage)

    /// `sentMs` is the sender's monotonic clock in milliseconds (wraps at 2^32); it is carried by INPUT only.
    public static func encode(_ m: ChannelMessage, seq: UInt32, flags: UInt8 = 0, sentMs: UInt32 = 0) throws -> Data {
        var w = FrameWriter()
        switch m {
        case .video(let f):
            // Validate the fragment numbers and size before writing.
            guard f.count >= 1, Int(f.count) <= VideoFragment.maxFragments, f.index < f.count,
                  f.data.count <= VideoFragment.maxData else { throw FramingError.badValue }
            w.u8(Channel.video.rawValue); w.u8(flags); w.u32(seq)
            w.u32(f.frameID); w.u16(f.index); w.u16(f.count); w.u64(f.ptsUs)
            w.u8(f.isKeyframe ? VideoFragment.flagKeyframe : 0); w.raw(f.data)
        case .input(let e):
            w.u8(Channel.input.rawValue); w.u8(flags); w.u32(seq)
            // INPUT carries the sender's timestamp so the host can drop stale events.
            w.u32(sentMs)
            try e.encode(&w)
        case .control(let c):
            w.u8(Channel.control.rawValue); w.u8(flags); w.u32(seq)
            c.encode(&w)
        }
        // The whole message must fit in one packet.
        guard w.bytes.count <= FrameCodec.maxPlaintext else { throw FramingError.tooLarge }
        return Data(w.bytes)
    }

    /// Parses a decrypted message (ignoring the INPUT timestamp).
    public static func decode(_ data: Data) throws -> (message: ChannelMessage, seq: UInt32, flags: UInt8) {
        let d = try decodeStamped(data)
        return (d.message, d.seq, d.flags)
    }

    /// Like `decode`, also returns the INPUT sender timestamp (0 for other channels).
    public static func decodeStamped(_ data: Data) throws -> (message: ChannelMessage, seq: UInt32, flags: UInt8, sentMs: UInt32) {
        guard data.count <= FrameCodec.maxPlaintext else { throw FramingError.tooLarge }
        var r = FrameReader(Array(data))
        // Common header first.
        let c = try r.u8(), flags = try r.u8(), seq = try r.u32()
        guard let ch = Channel(rawValue: c) else { throw FramingError.unknownType(c) }
        switch ch {
        case .video:
            let id = try r.u32(), idx = try r.u16(), cnt = try r.u16(), pts = try r.u64(), fl = try r.u8()
            // Sanity checks: valid counts, and no unknown flag bits set.
            guard cnt >= 1, Int(cnt) <= VideoFragment.maxFragments, idx < cnt, fl & ~VideoFragment.flagKeyframe == 0
            else { throw FramingError.badValue }
            // Whatever remains is the video data.
            let f = VideoFragment(frameID: id, index: idx, count: cnt, ptsUs: pts,
                                  isKeyframe: fl & VideoFragment.flagKeyframe != 0, data: r.rest())
            return (.video(f), seq, flags, 0)
        case .input:
            // Timestamp first, then the event itself.
            let sent = try r.u32()
            return (.input(try InputEvent.decode(&r)), seq, flags, sent)
        case .control:
            return (.control(try ControlMessage.decode(&r)), seq, flags, 0)
        }
    }
}
