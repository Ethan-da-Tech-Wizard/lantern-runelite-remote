// ==============================================================================
// Program: WindowCapturer.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: ScreenCaptureKit capture engine capturing high-framerate frames from a specific window.
//          Inputs: Window identifier and capture stream configuration.
//          Outputs: Asynchronous stream of CMSampleBuffer video frames.
//          Design Rationale: Uses modern macOS ScreenCaptureKit for zero-copy GPU window capture,
//          drastically outperforming legacy CGWindowListCreateImage.
// ==============================================================================
// WindowCapturer.swift - captures ONE window as video frames using ScreenCaptureKit.
// Who calls it: WindowFrameSource (the real video source) and lantern-host (list-windows, capture-test,
// inject-test, serve).
// ScreenCaptureKit Video Capture Pipeline:
//   - Frame Acquisition Architecture:
//     * Utilizes macOS `ScreenCaptureKit` (SCStream) for zero-copy hardware frame capture directly from the compositor.
//     * Unlike legacy CGWindowListCreateImage which copied pixel data from CPU memory, ScreenCaptureKit delivers
//       GPU-resident `CVPixelBuffer` surfaces directly to the VideoToolbox encoder with sub-millisecond overhead.
//   - Security & Permission Isolation:
//     * Requires explicit macOS 'Screen Recording' permission (TCC check). Fails gracefully if unauthorized.
//     * Window-scoped capture: Captures exclusively the selected RuneLite window, excluding notification banners,
//       other application windows, and the Mac desktop.
//     * Power & Lifecycle Guardrails: Automatically invalidates capture on machine sleep, screen lock, or user switch.

// AppKit: NSWorkspace, which tells us about sleep, screen sleep and user switching.
import AppKit
// CoreGraphics: the permission check for screen capture.
import CoreGraphics
// CoreMedia: CMSampleBuffer (one captured frame) and CMTime (timing).
import CoreMedia
// Foundation: locks, queues, notifications.
import Foundation
// ScreenCaptureKit (SCK): Apple's modern framework for capturing windows/displays as a stream of video frames.
import ScreenCaptureKit

/// Everything that can go wrong starting a capture, each with a readable message.
public enum CaptureError: Error, CustomStringConvertible, Sendable {
    // Cases: no Screen Recording permission, no matching window, several matches, or capture not running.
    case permissionDenied, windowNotFound(String), ambiguous([UInt32]), notRunning
    // The text shown to the person when the error is printed.
    public var description: String {
        switch self {
        // Explains how to grant permission; this tool never triggers the system prompt itself.
        case .permissionDenied:
            return "Screen Recording permission not granted. Enable it for this app in System Settings > Privacy & Security > Screen & System Audio Recording, then rerun. (This tool never prompts.)"
        // The search text (or id) matched no on-screen window.
        case .windowNotFound(let s): return "no on-screen window matches '\(s)'"
        // More than one window matched: list their ids so the user can narrow down.
        case .ambiguous(let ids): return "multiple windows match; use a more specific substring (ids: \(ids))"
        // stop/use called while nothing is capturing.
        case .notRunning: return "capture not running"
        }
    }
}

// NSObject base class is required by SCStreamOutput/Delegate. @unchecked Sendable: thread safety is handled by `lock` below.
// SCStreamOutput receives frames; SCStreamDelegate is told if the stream stops with an error.
/// Captures ONE window (SCContentFilter desktopIndependentWindow). Never the display or other windows.
public final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // CGPreflightScreenCaptureAccess only CHECKS the Screen Recording permission; it never shows a prompt.
    public static var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }   // does not prompt

    // Real app windows only: layer 0 (normal windows, not menus or overlays) and bigger than 1x1 point.
    public static func listWindows() -> [WindowInfo] {
        // Get visible windows, then filter out tiny or non-normal ones.
        WindowLister.windows().filter { $0.layer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }
    }

    // Throws if no window matches or if more than one does (we never guess).
    /// Resolves a substring (title or owner) to exactly one window.
    public static func resolve(_ needle: String) throws -> WindowInfo {
        // Windows whose title or owner contains the text.
        let m = listWindows().filter { $0.matches(needle) }
        // None found.
        if m.isEmpty { throw CaptureError.windowNotFound(needle) }
        // Too many: report their ids.
        if m.count > 1 { throw CaptureError.ambiguous(m.map(\.id)) }
        // Exactly one match.
        return m[0]
    }

    // The window being captured.
    public let window: WindowInfo
    // Target frames per second.
    private let fps: Int
    // Protects `stream`, `observers` and the two callbacks, which can be touched from different threads.
    private let lock = NSLock()
    // The running SCStream (nil when stopped).
    private var stream: SCStream?
    // Notification listeners we added (sleep/lock/etc.), kept so we can remove them again.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    // The queue where SCK delivers frames; userInteractive = highest priority for smooth video.
    private let q = DispatchQueue(label: "capture.q", qos: .userInteractive)
    // Backing store for onSample.
    private var _onSample: (@Sendable (CMSampleBuffer) -> Void)?
    // Backing store for onAutoStop.
    private var _onStop: (@Sendable (String) -> Void)?

    // Callback that receives each valid captured frame.
    public var onSample: (@Sendable (CMSampleBuffer) -> Void)? {
        // Reads and writes go through the lock for thread safety.
        get { lock.lock(); defer { lock.unlock() }; return _onSample }
        set { lock.lock(); _onSample = newValue; lock.unlock() }
    }
    // Fired when capture ends by itself (lock, sleep, user switch or stream error).
    /// Called with the reason when capture ended on its own (lock, sleep, error).
    public var onAutoStop: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStop }
        set { lock.lock(); _onStop = newValue; lock.unlock() }
    }

    // Clamp fps to the range 1...60 so a bad value cannot reach SCK.
    public init(window: WindowInfo, fps: Int) { self.window = window; self.fps = max(1, min(fps, 60)) }

    /// Starts streaming the one window. Throws if permission is missing or the window cannot be found.
    public func start() async throws {
        // Step 1: refuse (do not prompt) when Screen Recording permission is missing.
        guard Self.permissionGranted else { throw CaptureError.permissionDenied }
        // Step 2: ask SCK for the shareable windows currently on screen (desktop elements excluded).
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        // Step 3: find our window by id in that list; if it vanished, fail.
        guard let w = content.windows.first(where: { $0.windowID == window.id }) else {
            throw CaptureError.windowNotFound("id \(window.id)")
        }
        // Step 4: a content filter says WHAT to capture. 'desktopIndependentWindow' = just this window, nothing behind it.
        let filter = SCContentFilter(desktopIndependentWindow: w)
        // The configuration says HOW to capture.
        let cfg = SCStreamConfiguration()
        // Output size: twice the window's point size, for sharp Retina pixels (assumes a 2x screen).
        cfg.width = Int(w.frame.width) * 2; cfg.height = Int(w.frame.height) * 2
        // At most `fps` frames per second (the minimum time between frames is 1/fps seconds).
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Number of frame buffers SCK may keep in flight; small = lower delay.
        cfg.queueDepth = 2
        // 32-bit BGRA pixels, which the H.264 encoder can accept directly.
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // Do not draw the mouse cursor into the video.
        cfg.showsCursor = false
        // Build the stream from filter + configuration; `self` is told about errors.
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        // Register self to receive screen frames on our queue.
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        // Begin capture (this is where macOS starts delivering frames).
        try await s.startCapture()
        // Remember the stream so stop() can end it.
        setStream(s)
        // Start listening for sleep/lock/user-switch events so capture stops by itself.
        installAutoStop()
    }

    /// Stops capture and removes the listeners. Safe to call when already stopped.
    public func stop() async {
        // Remove listeners first so they cannot fire during shutdown.
        removeAutoStop()
        // Take the stream out (leaving nil) so a second stop() does nothing.
        let s = takeStream()
        // Ask SCK to stop; errors are ignored.
        try? await s?.stopCapture()
    }

    // Small helpers that read/write `stream` while holding the lock.
    private func setStream(_ s: SCStream) { lock.lock(); stream = s; lock.unlock() }
    // Returns the stream and clears the stored one in one locked step.
    private func takeStream() -> SCStream? { lock.lock(); defer { lock.unlock() }; let s = stream; stream = nil; return s }

    // Registers for notifications that mean 'we should stop capturing' (the screen is no longer ours to watch).
    private func installAutoStop() {
        // Two notification centers: the workspace one (sleep, user switch) and the system-wide distributed one (screen lock).
        let ws = NSWorkspace.shared.notificationCenter, dn = DistributedNotificationCenter.default()
        // A table of (center, notification name, reason text).
        let pairs: [(NotificationCenter, Notification.Name, String)] = [
            // Mac is about to sleep.
            (ws, NSWorkspace.willSleepNotification, "sleep"),
            // Displays went to sleep.
            (ws, NSWorkspace.screensDidSleepNotification, "screen sleep"),
            // Another user's session became active (fast user switching).
            (ws, NSWorkspace.sessionDidResignActiveNotification, "user switch"),
            // The screen was locked.
            (dn, Notification.Name("com.apple.screenIsLocked"), "screen lock"),
        ]
        // Add one listener per row.
        for (c, n, why) in pairs {
            // When it fires: stop capture, then tell our owner the reason.
            let o = c.addObserver(forName: n, object: nil, queue: nil) { [weak self] _ in
                // [weak self] avoids keeping this object alive forever; if it is gone, do nothing.
                guard let self else { return }
                // A Task runs async code from this non-async callback.
                Task { await self.stop(); self.onAutoStop?(why) }
            }
            // Remember the observer so removeAutoStop can unregister it.
            lock.lock(); observers.append((c, o)); lock.unlock()
        }
    }

    // Unregisters every listener added by installAutoStop.
    private func removeAutoStop() {
        // Copy the list and empty it under the lock.
        lock.lock(); let o = observers; observers = []; lock.unlock()
        // Then remove each listener outside the lock.
        for (c, t) in o { c.removeObserver(t) }
    }

    // SCK calls this for every frame (on our queue). Not every callback holds a real picture.
    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only handle video frames, and only valid buffers whose status attachment says .complete
        // (SCK also sends 'idle' or 'blank' notices without new pixels, which we skip).
        guard type == .screen, CMSampleBufferIsValid(sb),
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        // Pass the good frame to whoever is listening (the encoder side).
        onSample?(sb)
    }

    // SCK calls this if the stream dies on its own (for example the window closed).
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Clean up listeners and forget the stream, then report the reason.
        removeAutoStop()
        // The stream is already dead, so clear our reference.
        lock.lock(); self.stream = nil; lock.unlock()
        // Tell the owner, including the system's error text.
        onAutoStop?("stream error: \(error.localizedDescription)")
    }
}
