// ==============================================================================
// Program: InputEvent.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Defines every touch and keyboard input event transmitted from client to host.
//          Inputs: Touch coordinates (normalized 0.0-1.0), drag deltas, and keyboard character codes.
//          Outputs: Compact 8-16 byte binary structures transmitted over the encrypted channel.
//          Design Rationale: Normalized coordinates decouple mobile screen geometry from server display resolution.
// ==============================================================================
// =====================================================================================
// InputEvent.swift
//
// PURPOSE
//   Describes every kind of touch/keyboard action the phone can send to the host, and how each
//   one is turned into bytes ("encoded") and back ("decoded") for the network.
//
// WHO CALLS IT
//   - The phone's gesture code creates `InputEvent` values.
//   - ChannelMessage.swift calls `encode` / `decode` when it builds or reads an INPUT packet.
//   - The host's input gate and injector receive decoded events.
//
// KEY IDEAS (in plain English)
//   - NORMALIZED COORDINATES: positions are fractions from 0 to 1 of the captured window, so
//     they work no matter the screen size.
//   - QUANTIZING: a Float is squeezed into a 16-bit whole number (0...65535) to save bytes, and
//     expanded back on the other side (a tiny rounding error is expected).
//   - CLAMPING: forcing a number into its allowed range so bad/hostile data cannot cause trouble.
//   - Decoding never trusts the sender: it clamps out-of-range floats; only bad lengths, types or key size throw an error
//     instead of crashing.
// =====================================================================================

import Foundation

/// One event == one user touch action. Coordinates normalized 0...1 in the captured window.
public enum InputEvent: Equatable, Sendable {
    case tap(x: Float, y: Float)
    case longPress(x: Float, y: Float)          // right click
    case dragStart(x: Float, y: Float)
    case dragMove(x: Float, y: Float)
    case dragEnd(x: Float, y: Float)
    case scroll(dx: Float, dy: Float)           // each -1...1
    case zoom(delta: Float)                     // -1...1, host maps to wheel
    case key(text: String, mods: UInt8)
    // Camera drag = middle mouse button held (OSRS rotates the camera with middle-drag). Wire codes 9-11 (older hosts drop them).
    case camStart(x: Float, y: Float)
    case camMove(x: Float, y: Float)
    case camEnd(x: Float, y: Float)

    /// Longest allowed key text, in UTF-8 bytes.
    public static let maxKeyBytes = 32

    /// Wire event-type codes.
    /// (Only `tap` is given a value, 1; Swift numbers the rest 2, 3, 4... in order.)
    enum Code: UInt8 { case tap = 1, longPress, dragStart, dragMove, dragEnd, scroll, zoom, key, camStart, camMove, camEnd }

    /// Forces a value into 0...1 (NaN, "not a number", becomes 0).
    public static func clamp01(_ v: Float) -> Float { v.isNaN ? 0 : min(max(v, 0), 1) }
    /// Forces a value into -1...1 (NaN becomes 0).
    public static func clampSigned(_ v: Float) -> Float { v.isNaN ? 0 : min(max(v, -1), 1) }

    /// Same event with all numeric fields clamped into range.
    public var clamped: InputEvent {
        let c = Self.clamp01, s = Self.clampSigned
        switch self {
        case .tap(let x, let y): return .tap(x: c(x), y: c(y))
        case .longPress(let x, let y): return .longPress(x: c(x), y: c(y))
        case .dragStart(let x, let y): return .dragStart(x: c(x), y: c(y))
        case .dragMove(let x, let y): return .dragMove(x: c(x), y: c(y))
        case .dragEnd(let x, let y): return .dragEnd(x: c(x), y: c(y))
        case .scroll(let dx, let dy): return .scroll(dx: s(dx), dy: s(dy))
        case .zoom(let d): return .zoom(delta: s(d))
        case .camStart(let x, let y): return .camStart(x: c(x), y: c(y))
        case .camMove(let x, let y): return .camMove(x: c(x), y: c(y))
        case .camEnd(let x, let y): return .camEnd(x: c(x), y: c(y))
        // Key text has no numbers to clamp.
        case .key: return self
        }
    }

    // MARK: Quantizing helpers

    /// 0...1 float -> 16-bit whole number.
    private static func q(_ v: Float) -> UInt16 { UInt16((clamp01(v) * 65535).rounded()) }
    /// -1...1 float -> 16-bit whole number (shifted into 0...1 first).
    private static func qs(_ v: Float) -> UInt16 { q((clampSigned(v) + 1) / 2) }
    /// 16-bit number -> 0...1 float.
    private static func dq(_ v: UInt16) -> Float { Float(v) / 65535 }
    /// 16-bit number -> -1...1 float.
    private static func dqs(_ v: UInt16) -> Float { dq(v) * 2 - 1 }

    // MARK: Encode

    /// Body: type u8 | x u16 | y u16 | buttons u8 | keycode u16 | mods u8 [| keylen u8 | utf8 (key only)]
    /// ("u8" = one unsigned byte, "u16" = two bytes, written big-endian.)
    func encode(_ w: inout FrameWriter) throws {
        // Fields start at neutral values; each case below fills in what it uses.
        var code: Code, x: UInt16 = 0, y: UInt16 = 0, buttons: UInt8 = 0, mods: UInt8 = 0
        var text: [UInt8] = []
        switch self {
        // `buttons` is a bit mask: 1 = left, 2 = right, 4 = middle.
        case .tap(let a, let b): code = .tap; x = Self.q(a); y = Self.q(b); buttons = 1
        case .longPress(let a, let b): code = .longPress; x = Self.q(a); y = Self.q(b); buttons = 2
        case .dragStart(let a, let b): code = .dragStart; x = Self.q(a); y = Self.q(b); buttons = 1
        case .dragMove(let a, let b): code = .dragMove; x = Self.q(a); y = Self.q(b); buttons = 1
        case .dragEnd(let a, let b): code = .dragEnd; x = Self.q(a); y = Self.q(b)
        case .scroll(let a, let b): code = .scroll; x = Self.qs(a); y = Self.qs(b)
        case .zoom(let d): code = .zoom; x = Self.qs(d)
        case .camStart(let a, let b): code = .camStart; x = Self.q(a); y = Self.q(b); buttons = 4
        case .camMove(let a, let b): code = .camMove; x = Self.q(a); y = Self.q(b); buttons = 4
        case .camEnd(let a, let b): code = .camEnd; x = Self.q(a); y = Self.q(b)
        case .key(let t, let m):
            code = .key; mods = m; text = Array(t.utf8)
            // Key text must be non-empty and short enough.
            guard !text.isEmpty, text.count <= Self.maxKeyBytes else { throw FramingError.badValue }
        }
        // Write the fixed-size part in the documented order (the keycode slot is reserved, so 0).
        w.u8(code.rawValue); w.u16(x); w.u16(y); w.u8(buttons); w.u16(0); w.u8(mods)
        // Key events add a length byte and then the text bytes.
        if code == .key { w.u8(UInt8(text.count)); w.raw(text) }
    }

    // MARK: Decode

    /// Reads one event from the bytes. Throws a `FramingError` for anything malformed.
    static func decode(_ r: inout FrameReader) throws -> InputEvent {
        // First byte says which kind of event follows.
        let t = try r.u8()
        guard let code = Code(rawValue: t) else { throw FramingError.unknownType(t) }
        let x = try r.u16(), y = try r.u16()
        _ = try r.u8()            // buttons: implied by type, ignored
        _ = try r.u16()           // keycode: reserved, ignored
        let mods = try r.u8()
        let e: InputEvent
        switch code {
        case .tap: e = .tap(x: dq(x), y: dq(y))
        case .longPress: e = .longPress(x: dq(x), y: dq(y))
        case .dragStart: e = .dragStart(x: dq(x), y: dq(y))
        case .dragMove: e = .dragMove(x: dq(x), y: dq(y))
        case .dragEnd: e = .dragEnd(x: dq(x), y: dq(y))
        case .scroll: e = .scroll(dx: dqs(x), dy: dqs(y))
        case .zoom: e = .zoom(delta: dqs(x))
        case .camStart: e = .camStart(x: dq(x), y: dq(y))
        case .camMove: e = .camMove(x: dq(x), y: dq(y))
        case .camEnd: e = .camEnd(x: dq(x), y: dq(y))
        case .key:
            // Length byte, then that many UTF-8 text bytes; length must be 1...maxKeyBytes.
            let n = Int(try r.u8())
            guard n >= 1, n <= maxKeyBytes else { throw FramingError.badValue }
            guard let s = String(bytes: try r.take(n), encoding: .utf8) else { throw FramingError.badValue }
            e = .key(text: s, mods: mods)
        }
        // Nothing may be left over after the event.
        guard r.remaining == 0 else { throw FramingError.trailingBytes }
        return e.clamped
    }
}
