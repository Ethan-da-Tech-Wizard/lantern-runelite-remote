// Program: Lantern - Transport.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Protocol describing what the phone app needs from a transport.
//
// Transport.swift
//
// PURPOSE: Defines the small "seam" (set of agreements) between the app's screens and whatever
// actually moves bytes: video frames coming in, and touch/keyboard events going out.
//
// WHO CALLS IT: ClientModel talks to a `SessionTransport`; NetTransport (real network) and
// DemoTransport (fake, offline) both conform to it. StreamView hands a `VideoSink` to the transport.
//
// KEY IDEAS:
//   - A Swift `protocol` is a list of requirements. Any type that promises to provide them
//     can be used wherever the protocol is expected. That lets the app swap real/fake networking.
//   - `@MainActor` means the code runs on the main (UI) thread, so UI state is never touched
//     from two threads at once.

import Foundation
import LanternCore

/// Where decoded video goes. The UI owns a concrete sink; transports only know this protocol.
///
/// In plain words: a transport receives compressed video from the Mac and hands each frame to
/// a sink; the sink decodes and shows it.
protocol VideoSink: AnyObject {
    /// One access unit in Annex B form. SPS/PPS (parameter sets, Annex B) may be included inside key-frame data.
    /// Called once for every frame (an "access unit") that arrives.
    /// - Parameter annexB: the compressed H.264 bytes, with 00 00 01 (or 00 00 00 01) start codes between pieces.
    /// - Parameter isKey: true when this is a key frame, a frame that can be decoded without earlier frames.
    /// - Parameter ptsUs: presentation timestamp (when to show the frame), in microseconds.
    func enqueue(annexB: Data, isKey: Bool, ptsUs: UInt64)
    /// Drop the format description and any queued frames (reconnect, resize, new config).
    func reset()
}

/// The life cycle of a connection, shown in the UI and used to decide whether input may be sent.
enum TransportState: Equatable {
    // idle: nothing happening. connecting: handshake under way. streaming: video flowing.
    case idle, connecting, streaming
    // failed carries a human-readable reason that the UI can show in a banner.
    case failed(String)
}

/// What the user typed to pair with a Mac: either the short code or the text from a QR code.
enum PairingInput: Equatable {
    case code(String)       // 10-char base32, as typed
    case qrPayload(String)  // "LNT1...." string
}

// `@MainActor`: every method below runs on the main/UI thread, so no two threads touch UI state at once.
/// Seam for the real network layer (LanternCore/Net, written elsewhere). This app does NO networking itself.
/// All methods are called on the main actor.
@MainActor
protocol SessionTransport: AnyObject {
    /// The model sets this closure; the transport calls it whenever the connection state changes.
    var onState: ((TransportState) -> Void)? { get set }
    /// Where the transport delivers incoming video. StreamView sets this to its display sink.
    var videoSink: VideoSink? { get set }
    /// True once this phone has a saved trust relationship (keys) with a Mac.
    var isPaired: Bool { get }
    /// Exchange the pairing secret with the Mac at `host` (can throw, e.g. on a wrong code).
    func pair(_ input: PairingInput, host: String) async throws
    /// Open the session to the already-paired Mac at `host`.
    func connect(host: String) async throws
    /// Exactly one call per user gesture. Implementations must send immediately, never queue or repeat.
    func send(_ event: InputEvent)
    /// Tell the transport the bitrate (video quality/size) the user would like, in kilobits per second.
    func setBitrateHint(kbps: Int)
    /// Close the session and stop video.
    func disconnect()
    /// Remove the saved pairing so the phone no longer trusts that Mac.
    func forgetHost()
    /// Decoder lost sync: ask the host for an IDR frame. Default no-op (demo).
    func requestKeyframe()
    /// Local syntax check of the host address (no network). Default: accept.
    func validate(host: String) -> Bool
}

// Default implementations: a transport that does not care about these two methods gets
// harmless behaviour for free (nothing / accept everything).
extension SessionTransport {
    // Do nothing by default.
    func requestKeyframe() {}
    // Accept any host string by default.
    func validate(host: String) -> Bool { true }
}
