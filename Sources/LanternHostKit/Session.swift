// ==============================================================================
// Program: Session.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Host session orchestrator integrating window capture, video encoding, network, and input.
//          Inputs: Selected window ID, network port, and configuration options.
//          Outputs: Active remote streaming session lifecycle management.
//          Design Rationale: Acts as composition root on the host, ensuring clean teardown of capture
//          sessions and network sockets on shutdown.
// ==============================================================================
// Session.swift - HostSession, the glue between video, network and input.
// Who calls it: lantern-host's serve command creates one and calls shutdown() on Ctrl-C.
// Key ideas: capture runs ONLY while a client is connected; input from the phone is applied on its own
// queue; when a client leaves, anything held down (mouse buttons) is released so nothing sticks.
// Nothing here logs pairing codes, keys or typed text.

// Foundation: locks, queues, Task support.
import Foundation
// LanternCore: HostServer (network side), InputEvent, control messages.
import LanternCore

// @unchecked Sendable: this class is touched from several threads, and we guard its mutable fields with `lock` by hand.
/// Wires FrameSource -> HostServer (video) and HostServer input -> InputInjector (which owns the HostInputGate).
/// Capture runs ONLY while a client session is established. Never logs codes, keys or typed text.
public final class HostSession: @unchecked Sendable {
    // Simple tallies the host can show: frames sent, input applied, input refused.
    public struct Counters: Sendable, Equatable {
        // Three counters declared together, all start at 0.
        public var framesSent = 0, inputApplied = 0, inputRefused = 0
    }
    // The encrypted network server (public so lantern-host can start it and open pairing).
    public let server: HostServer
    // Where video frames come from (window capture + encoder).
    private let source: FrameSource
    // Applies phone touches/keys to the target window, with safety checks.
    private let injector: InputInjector
    // Protects counters, capturing, epoch, stopped and the log callback.
    private let lock = NSLock()
    // A serial queue runs one input job at a time, in order, on its own thread.
    /// Input is applied on its own serial queue so a slow focus switch (auto-focus can wait up to ~1.6 s) never blocks the network queue.
    private let inputQueue = DispatchQueue(label: "lantern.input", qos: .userInteractive)
    // Current tallies.
    private var counters = Counters()
    // True while capture is running or starting.
    private var capturing = false
    // A number that goes up each time capture starts or ends; lets a slow start notice it is out of date.
    private var epoch = 0
    // Set once shutdown begins; blocks any new capture.
    private var stopped = false
    // Backing storage for onLog.
    private var _onLog: (@Sendable (String) -> Void)?
    // Where log lines go (lantern-host prints them). Thread-safe through the lock.
    public var onLog: (@Sendable (String) -> Void)? {
        // Read or replace the callback while holding the lock.
        get { lock.withLock { _onLog } } set { lock.withLock { _onLog = newValue } }
    }

    // Store the three collaborators, then connect their callbacks.
    public init(server: HostServer, source: FrameSource, injector: InputInjector) {
        // Save the parts we were given.
        self.server = server; self.source = source; self.injector = injector
        // Hook everything together (see wire below).
        wire()
    }

    // A safe copy of the counters at this moment.
    public var snapshot: Counters { lock.withLock { counters } }
    // Whether capture is currently on.
    public var isCapturing: Bool { lock.withLock { capturing } }

    // Send a line to the log callback if one is set.
    private func log(_ s: String) { onLog?(s) }

    // Connects the video source, input, control messages and session state to each other.
    private func wire() {
        // VIDEO: each encoded frame from the source is sent to the connected phone.
        source.onFrame = { [weak self] data, key, pts in
            // If this session object is already gone, do nothing. [weak self] avoids a retain cycle.
            guard let self else { return }
            // Send the frame; if it worked, count it.
            do { try self.server.sendVideoFrame(data, isKeyframe: key, ptsUs: pts); self.lock.withLock { self.counters.framesSent += 1 } }
            // Sending fails when no client is connected or it is closing; dropping the frame is intended.
            catch {}   // no client / closing: frame dropped by design
        }
        // If capture ends by itself (lock, sleep, error), log it and tear capture down and release held buttons.
        source.onEnded = { [weak self] why in
            // Record why capture stopped.
            self?.log("capture ended: \(why)")
            // Stop capture and let go of any held mouse buttons.
            self?.endCapture(release: true)
        }
        // INPUT: events from the phone are queued onto the input queue so slow work never stalls the network thread.
        server.onInput = { [weak self] e in
            // async = run later on the input queue and return immediately.
            self?.inputQueue.async { [weak self] in
                guard let self else { return }
                // Try to apply the event; the injector throws when a safety rule refuses it.
                do {
                    // Perform the click/drag/scroll/typing for this one event.
                    try self.injector.apply(e)
                    // Count it and read the new total in one locked step.
                    let n = self.lock.withLock { () -> Int in self.counters.inputApplied += 1; return self.counters.inputApplied }
                    // Log only the first three and then every 10th, to avoid flooding the log.
                    if n <= 3 || n % 10 == 0 { self.log("input applied (\(n) so far)") }
                }
                // Refused: count it and log the error. (Typed text is never logged.)
                catch { self.lock.withLock { self.counters.inputRefused += 1 }; self.log("input refused: \(error)") }
            }
        }
        // CONTROL: small messages from the phone about the stream.
        server.onControl = { [weak self] m in
            // Pick what to do for each message type.
            switch m {
            // The phone asks for a fresh keyframe (e.g. it lost sync).
            case .requestIDR: self?.source.requestKeyframe()
            // The phone asks for a different video data rate.
            case .bitrate(let b): self?.source.setBitrate(bps: Int(b))
            // Other control messages are not our business here.
            default: break
            }
        }
        // If the connection dropped while a button was held, let go of it so nothing stays stuck down.
        server.onHeldButtonsReleased = { [weak self] _ in self?.injector.releaseAll() }
        // SESSION: capture starts when a client is fully connected and stops when it leaves.
        server.onSessionStateChange = { [weak self] st in
            guard let self else { return }
            // Only two states matter here.
            switch st {
            // A paired client finished the secure handshake: log and start capture.
            case .established(let tag): self.log("client connected (\(tag))"); self.beginCapture()
            // Client left or was dropped: log, stop capture, release input.
            case .closed(let why): self.log("client session closed (\(why))"); self.endCapture(release: true)
            default: break
            }
        }
    }

    // Starts capture once; ignores duplicates.
    private func beginCapture() {
        // Under the lock: refuse if we are shutting down or already capturing; otherwise mark capturing and take a new epoch number.
        let myEpoch: Int? = lock.withLock {
            // Refuse (nil) when shutting down or when capture is already on.
            guard !stopped, !capturing else { return nil }
            // Claim the capture slot and bump the epoch.
            capturing = true; epoch += 1; return epoch
        }
        // Already capturing: just ask for a keyframe so the new client gets a picture quickly.
        guard let myEpoch else { source.requestKeyframe(); return }
        // Start capture in the background because it is async (it waits on the system).
        Task { [weak self] in
            guard let self else { return }
            do {
                // Start the capture + encoder.
                try await self.source.start()
                // If the session ended while starting, tear down again.
                // Check whether the epoch changed or capturing was cleared while we waited.
                if self.lock.withLock({ self.epoch != myEpoch || !self.capturing }) { await self.source.stop() }
                // Otherwise all is well: request the first keyframe.
                else { self.source.requestKeyframe() }
            // Start failed: log it, clean up and disconnect the client.
            } catch {
                self.log("capture start failed: \(error)")
                self.endCapture(release: true)
                self.server.disconnectClient()
            }
        }
    }

    // Stops capture (if on). `release` also lets go of held input.
    private func endCapture(release: Bool) {
        // Flip capturing off and bump the epoch; remember whether it was on.
        let was: Bool = lock.withLock { let w = capturing; capturing = false; epoch += 1; return w }
        // Release any held buttons right away.
        if release { injector.releaseAll() }
        // Stop the source in the background (stop is async).
        if was { Task { [source] in await source.stop() } }
    }

    /// Kill switch: stop capture, release held input, hard-stop the server. Idempotent.
    public func shutdown() async {
        // Block any future capture first.
        lock.withLock { stopped = true }
        // Immediately cut the network side.
        server.killSwitch()
        // Let go of held mouse buttons.
        injector.releaseAll()
        // Mark capture as off.
        let was: Bool = lock.withLock { let w = capturing; capturing = false; epoch += 1; return w }
        // The value is not needed here; this line only silences an unused-variable warning.
        _ = was
        // Wait for capture and encoder to stop.
        await source.stop()
        // Release once more in case something was pressed during shutdown.
        injector.releaseAll()
        // Finally close the server and wait for it.
        await server.stop()
    }
}
