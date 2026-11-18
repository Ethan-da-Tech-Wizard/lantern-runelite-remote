// Program: Lantern - SessionSource.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Video source abstraction and the real window-capture-plus-encoder source.
//
// SessionSource.swift - the "where does video come from?" abstraction (FrameSource) and its real
// implementation (WindowFrameSource = one window captured then H.264 encoded).
// Who calls it: HostSession (starts/stops it when a client connects/leaves) and lantern-host serve.
// Key ideas: a protocol lets tests substitute a fake source; capture only runs while a client is connected;
// the encoder is created lazily because the true frame size is known only after the first frame arrives.

// CoreMedia: CMSampleBuffer (one captured video frame wrapper) and related types.
import CoreMedia
// Foundation: Data, NSLock.
import Foundation
// LanternCore: shared types (imported for consistency with sibling files).
import LanternCore

// A protocol is a list of requirements; anything that offers them can act as a video source.
/// Where encoded video comes from. The real one is capture + encoder; tests use a synthetic one.
// AnyObject = classes only. Sendable = safe to share across threads.
public protocol FrameSource: AnyObject, Sendable {
    // Callback the receiver sets: it is called for every encoded frame with its bytes, keyframe flag and timestamp (microseconds).
    /// (Annex B access unit, isKeyframe, ptsUs). Set before start.
    var onFrame: (@Sendable (Data, Bool, UInt64) -> Void)? { get set }
    // Callback fired if the source stops by itself, with a short reason text.
    /// Called when the source ended by itself (lock, sleep, error).
    var onEnded: (@Sendable (String) -> Void)? { get set }
    // Begin producing frames (async because capture start-up waits on the system).
    func start() async throws
    // Stop producing frames and release resources.
    func stop() async
    // Ask for a full 'keyframe' soon (a picture that can be decoded without earlier frames, useful when a client joins).
    func requestKeyframe()
    // Change the target video data rate in bits per second.
    func setBitrate(bps: Int)
}

// @unchecked Sendable: we promise thread safety ourselves by guarding shared state with `lock`.
/// Real source: ONE window via WindowCapturer, encoded by H264Encoder. Only started while a client is connected.
public final class WindowFrameSource: FrameSource, @unchecked Sendable {
    // The one window being streamed.
    private let window: WindowInfo
    // Frames per second to capture.
    private let fps: Int
    // Current target bitrate (bits per second); clamped when changed.
    private var bitrate: Int
    // Protects the mutable fields below, because capture, encoder and network threads all touch them.
    private let lock = NSLock()
    // The running ScreenCaptureKit capturer (nil while stopped).
    private var capturer: WindowCapturer?
    // The H.264 encoder, created lazily when the first frame shows the real pixel size.
    private var encoder: H264Encoder?
    // Backing storage for the onFrame property (underscore = read/write only through the lock).
    private var _onFrame: (@Sendable (Data, Bool, UInt64) -> Void)?
    // Backing storage for onEnded.
    private var _onEnded: (@Sendable (String) -> Void)?

    // Defaults: 30 frames per second and about 4 megabits per second.
    public init(window: WindowInfo, fps: Int = 30, bitrate: Int = 4_000_000) {
        // Store the settings.
        self.window = window; self.fps = fps; self.bitrate = bitrate
    }
    // Thread-safe accessors: every read and write happens while holding the lock.
    public var onFrame: (@Sendable (Data, Bool, UInt64) -> Void)? {
        // get = read the stored callback; set = replace it.
        get { lock.withLock { _onFrame } } set { lock.withLock { _onFrame = newValue } }
    }
    // Same pattern for the 'ended' callback.
    public var onEnded: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onEnded } } set { lock.withLock { _onEnded = newValue } }
    }

    /// Creates the capturer, wires its callbacks, then starts capture. Throws if permission is missing or the window is gone.
    public func start() async throws {
        // Make a capturer for our window (it captures only this window, not the whole screen).
        let cap = WindowCapturer(window: window, fps: fps)
        // Every captured frame goes to handle(); [weak self] avoids a retain cycle (the objects keeping each other alive forever).
        cap.onSample = { [weak self] sb in self?.handle(sb) }
        // If the system stops capture (sleep, lock, error) tell our listener.
        cap.onAutoStop = { [weak self] why in self?.onEnded?(why) }
        // Remember the capturer so stop() can find it.
        lock.withLock { capturer = cap }
        // Actually begin capture (may prompt nothing: permission is checked and refused, never requested).
        try await cap.start()
    }

    /// Stops capture and flushes the encoder. Safe to call more than once.
    public func stop() async {
        // Take both objects out under the lock and clear the fields so nothing else can use them.
        let (cap, enc) = lock.withLock { () -> (WindowCapturer?, H264Encoder?) in
            let r = (capturer, encoder); capturer = nil; encoder = nil; return r
        }
        // Stop the capturer first so no more frames arrive, then finish the encoder (flushes pending frames).
        await cap?.stop()
        enc?.finish()
    }

    // If an encoder exists, ask it to make the next frame a keyframe.
    public func requestKeyframe() { lock.withLock { encoder }?.forceKeyframe() }
    // Clamp the requested rate between 0.5 and 20 megabits per second, store it, and apply it to a running encoder.
    public func setBitrate(bps: Int) {
        // Update the stored value and grab the encoder in one locked step.
        let enc = lock.withLock { () -> H264Encoder? in bitrate = max(500_000, min(bps, 20_000_000)); return encoder }
        // Re-read the stored value and push it to the encoder; errors are ignored (best effort).
        try? enc?.update(bitrate: lock.withLock { bitrate })
    }

    /// Called for each captured frame (on the capture queue). Creates the encoder on first use, then encodes.
    private func handle(_ sb: CMSampleBuffer) {
        // Hold the lock for the whole call so the encoder cannot be torn down mid-frame.
        lock.lock(); defer { lock.unlock() }
        // First frame: now we know the real pixel size of the captured window, so build the encoder to match.
        if encoder == nil, let pb = CMSampleBufferGetImageBuffer(sb) {
            // If creation fails the encoder stays nil and frames are skipped.
            let e = try? H264Encoder(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), bitrate: bitrate, fps: fps)
            // Every finished packet is forwarded to whoever listens on onFrame (the network session).
            e?.onPacket = { [weak self] p in self?.onFrame?(p.annexB, p.isKey, p.ptsUs) }
            // Keep the encoder for later frames.
            encoder = e
        }
        // Hand the frame to the encoder; a failed frame is simply dropped.
        try? encoder?.encode(sb)
    }
}
