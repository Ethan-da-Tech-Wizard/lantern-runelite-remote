// ==============================================================================
// Program: WireMessage.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Defines outer network packet framing with magic bytes, message types, and lengths.
//          Inputs: Binary datagram buffers received from UDP network sockets.
//          Outputs: Parsed packet headers and verified payload byte slices.
//          Design Rationale: 4-byte magic signature prevents cross-protocol confusion and drops spurious traffic.
// ==============================================================================
// =====================================================================================
// WireMessage.swift
//
// PURPOSE
//   Defines the outermost layer of our network protocol: the "datagram" (one UDP packet).
//   This file turns structured messages into bytes and bytes back into structured messages.
//   "Framing" means deciding where a message starts, what each byte means, and where it ends.
//
// WHO CALLS IT
//   The transport and secure-session code call `FrameCodec.encode` before sending a packet
//   and `FrameCodec.decode` on every packet received. The Noise layer (Noise/) does the actual
//   encryption; this file only arranges the bytes.
//
// PACKET LAYOUT (every packet)
//   byte 0-1 : magic number "TW" (0x54 0x57) so we can spot our own packets
//   byte 2   : protocol version (1)
//   byte 3   : message type (pairing step, reconnect step, data, reject)
//   rest     : the type-specific body
//
// KEY IDEAS (RuneLite Remote Streaming & Wire Framing):
//   - Low-Latency Remote Protocol vs Standard Stacks:
//     * Unlike HTTP/WebSocket streaming or WebRTC SCTP data channels, Lantern transmits raw framed UDP
//       datagrams directly, bypassing TCP head-of-line blocking and kernel connection state overhead.
//     * Inbound touches and outbound video slices are packed into small, fixed-layout binary datagrams.
//   - BIG-ENDIAN: multi-byte numbers are written with the most significant byte first.
//   - BOUNDS CHECKING: the reader refuses to read past the end; it throws an error rather than
//     crashing, because packets come from the network and cannot be trusted.
//   - AAD (additional authenticated data): the packet header is not encrypted, but it is fed into
//     the encryption's tamper seal so it cannot be altered unnoticed.
//   - Pairing messages M1/M2/M3 are the three steps of the first-time handshake; IK M1/M2 are the
//     two steps of the reconnect handshake; DATA carries encrypted application bytes.
// =====================================================================================

import Foundation

// MARK: - Errors

/// Errors from framing. Decoding never traps; every malformed input maps to one of these.
public enum FramingError: Error, Equatable, Sendable {
    /// Ran out of bytes.
    case truncated
    /// The first two bytes were not "TW".
    case badMagic
    /// A protocol version we do not understand.
    case unsupportedVersion(UInt8)
    /// A message/channel/event type code we do not know.
    case unknownType(UInt8)
    /// A field had the wrong exact size.
    case badLength
    /// Packet or field larger than allowed.
    case tooLarge
    /// Extra bytes remained after a complete message.
    case trailingBytes
    /// A field held a value outside its allowed range.
    case badValue
    /// The reserved last counter value (all ones) was used.
    case reservedCounter
}

// MARK: - Byte reader and writer

/// Bounds-checked big-endian reader.
struct FrameReader {
    /// The bytes being read.
    let bytes: [UInt8]
    /// Position of the next unread byte.
    private(set) var pos = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    /// How many unread bytes are left.
    var remaining: Int { bytes.count - pos }

    /// Reads one byte.
    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw FramingError.truncated }
        // `defer` advances the position after the value is returned.
        defer { pos += 1 }
        return bytes[pos]
    }
    /// Reads 2, 4 or 8 bytes as one number (big-endian).
    mutating func u16() throws -> UInt16 { UInt16(try uint(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }
    mutating func u64() throws -> UInt64 { try uint(8) }
    /// Shared helper: reads `n` bytes and builds a number from them.
    private mutating func uint(_ n: Int) throws -> UInt64 {
        guard remaining >= n else { throw FramingError.truncated }
        var v: UInt64 = 0
        // Each step shifts what we have left by 8 bits and adds the next byte.
        for i in 0..<n { v = (v << 8) | UInt64(bytes[pos + i]) }
        pos += n
        return v
    }
    /// Reads exactly `n` raw bytes.
    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw FramingError.truncated }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }
    /// Reads everything that is left.
    mutating func rest() -> [UInt8] {
        defer { pos = bytes.count }
        return Array(bytes[pos...])
    }
}

/// Big-endian writer.
struct FrameWriter {
    /// The bytes written so far.
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    /// Multi-byte writers split the number: high byte first.
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xff)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    /// Appends raw bytes as they are.
    mutating func raw(_ d: [UInt8]) { bytes.append(contentsOf: d) }
}

// MARK: - Message types

/// The type byte (header byte 3), which follows the 2 magic bytes and the version byte.
public enum WireType: UInt8, Sendable {
    case pairM1 = 0x01, pairM2 = 0x02, pairM3 = 0x03
    case ikM1 = 0x10, ikM2 = 0x11
    case data = 0x20
    case reject = 0x30
}

/// Datagram-level message (docs/01 sec. 4 and 5). Sealed byte blobs are opaque here;
/// crypto lives in Noise/.
public enum WireMessage: Equatable, Sendable {
    /// e[32] || 16-byte AEAD tag over the empty payload (XXpsk3: the `e` token MixKeys, so a key is set).
    case pairM1(eAndTag: [UInt8])
    /// Pairing step 2: ephemeral key, encrypted static key, encrypted payload.
    case pairM2(e: [UInt8], encS: [UInt8], encPayload: [UInt8])
    /// Pairing step 3: encrypted static key and encrypted payload.
    case pairM3(encS: [UInt8], encPayload: [UInt8])
    /// Reconnect step 1: ephemeral key, encrypted static key, encrypted timestamp.
    case ikM1(e: [UInt8], encS: [UInt8], encTs: [UInt8])
    /// Reconnect step 2: ephemeral key and encrypted (empty) payload.
    case ikM2(e: [UInt8], encPayload: [UInt8])
    /// `sealed` = ciphertext || 16-byte tag.
    /// The session ID picks the session; the counter is the packet number (also the nonce).
    case data(sessionID: UInt32, counter: UInt64, sealed: [UInt8])
    /// "Go away" notice with no body.
    case reject
}

// MARK: - Codec

/// Converts `WireMessage` to bytes and back, and holds all the size constants.
public enum FrameCodec {
    /// "T" and "W", the two magic bytes at the start of every packet.
    public static let magic0: UInt8 = 0x54
    public static let magic1: UInt8 = 0x57
    /// Protocol version we speak.
    public static let version: UInt8 = 1
    /// Magic (2) + version (1) + type (1).
    public static let headerSize = 4
    /// Largest packet allowed (a safe size for typical networks without fragmentation).
    public static let maxDatagram = 1200
    /// Authentication tag size.
    public static let tagSize = 16
    /// A public key is 32 bytes.
    public static let keySize = 32
    /// An encrypted static key: 32 key bytes + 16 tag bytes.
    public static let encStaticSize = 48
    /// PAIR_M1 body: e(32) + tag(16). Verified empirically against NoiseHandshake XXpsk3.
    public static let pairM1Size = keySize + tagSize
    /// An encrypted timestamp field: 24 bytes.
    public static let encTimestampSize = 24
    public static let maxPairPayload = 16 + 64        // device name utf8 max 64 + tag
    /// Bytes of DATA overhead before ciphertext: hdr(4) + session_id(4) + counter(8).
    public static let dataHeaderSize = 16
    /// Most sealed bytes that fit in one DATA packet.
    public static let maxSealed = maxDatagram - dataHeaderSize
    /// Most plaintext bytes that fit (sealed size minus the tag).
    public static let maxPlaintext = maxSealed - tagSize

    /// Turns a message into packet bytes, checking every field has a valid size.
    public static func encode(_ m: WireMessage) throws -> Data {
        var w = FrameWriter()
        // Every packet starts with magic and version.
        w.u8(magic0); w.u8(magic1); w.u8(version)
        switch m {
        case .pairM1(let e):
            try need(e, pairM1Size); w.u8(WireType.pairM1.rawValue); w.raw(e)
        case .pairM2(let e, let s, let p):
            try need(e, keySize); try need(s, encStaticSize); try bound(p, min: 16, max: maxPairPayload)
            w.u8(WireType.pairM2.rawValue); w.raw(e); w.raw(s); w.raw(p)
        case .pairM3(let s, let p):
            try need(s, encStaticSize); try bound(p, min: 16, max: maxPairPayload)
            w.u8(WireType.pairM3.rawValue); w.raw(s); w.raw(p)
        case .ikM1(let e, let s, let t):
            try need(e, keySize); try need(s, encStaticSize); try need(t, encTimestampSize)
            w.u8(WireType.ikM1.rawValue); w.raw(e); w.raw(s); w.raw(t)
        case .ikM2(let e, let p):
            try need(e, keySize); try need(p, 16)
            w.u8(WireType.ikM2.rawValue); w.raw(e); w.raw(p)
        case .data(let sid, let ctr, let sealed):
            // The all-ones counter is reserved, never sent.
            guard ctr != UInt64.max else { throw FramingError.reservedCounter }
            try bound(sealed, min: tagSize, max: maxSealed)
            w.u8(WireType.data.rawValue); w.u32(sid); w.u64(ctr); w.raw(sealed)
        case .reject:
            w.u8(WireType.reject.rawValue)
        }
        return Data(w.bytes)
    }

    /// Parses packet bytes into a message. Throws a `FramingError` for anything malformed.
    public static func decode(_ data: Data) throws -> WireMessage {
        // Reject oversize packets first.
        guard data.count <= maxDatagram else { throw FramingError.tooLarge }
        var r = FrameReader(Array(data))
        // Check magic, then version, then type.
        guard try r.u8() == magic0, try r.u8() == magic1 else { throw FramingError.badMagic }
        let ver = try r.u8()
        guard ver == version else { throw FramingError.unsupportedVersion(ver) }
        let t = try r.u8()
        guard let type = WireType(rawValue: t) else { throw FramingError.unknownType(t) }
        switch type {
        case .pairM1:
            let e = try r.take(pairM1Size); try done(r); return .pairM1(eAndTag: e)
        case .pairM2:
            // Fixed-size fields first; the payload is whatever remains.
            let e = try r.take(keySize), s = try r.take(encStaticSize), p = r.rest()
            try bound(p, min: 16, max: maxPairPayload)
            return .pairM2(e: e, encS: s, encPayload: p)
        case .pairM3:
            let s = try r.take(encStaticSize), p = r.rest()
            try bound(p, min: 16, max: maxPairPayload)
            return .pairM3(encS: s, encPayload: p)
        case .ikM1:
            let e = try r.take(keySize), s = try r.take(encStaticSize), ts = try r.take(encTimestampSize)
            try done(r); return .ikM1(e: e, encS: s, encTs: ts)
        case .ikM2:
            let e = try r.take(keySize), p = try r.take(16)
            try done(r); return .ikM2(e: e, encPayload: p)
        case .data:
            let sid = try r.u32(), ctr = try r.u64()
            guard ctr != UInt64.max else { throw FramingError.reservedCounter }
            // Everything after the counter is the sealed (encrypted) body.
            let sealed = r.rest()
            try bound(sealed, min: tagSize, max: maxSealed)
            return .data(sessionID: sid, counter: ctr, sealed: sealed)
        case .reject:
            try done(r); return .reject
        }
    }

    /// AAD for DATA: header(4) || session_id(4), per docs/01 sec. 5.
    /// Both sides rebuild these 8 bytes and feed them to the cipher, so editing the header or the
    /// session ID makes decryption fail.
    public static func dataAAD(sessionID: UInt32) -> Data {
        var w = FrameWriter()
        w.u8(magic0); w.u8(magic1); w.u8(version); w.u8(WireType.data.rawValue); w.u32(sessionID)
        return Data(w.bytes)
    }

    // MARK: Validation helpers

    /// Field must be exactly `n` bytes.
    private static func need(_ a: [UInt8], _ n: Int) throws { guard a.count == n else { throw FramingError.badLength } }
    /// Field length must be within min...max.
    private static func bound(_ a: [UInt8], min: Int, max: Int) throws {
        guard a.count >= min else { throw FramingError.truncated }
        guard a.count <= max else { throw FramingError.tooLarge }
    }
    /// No bytes may remain.
    private static func done(_ r: FrameReader) throws { guard r.remaining == 0 else { throw FramingError.trailingBytes } }
}
