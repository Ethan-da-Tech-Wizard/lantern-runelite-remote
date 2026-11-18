// Program: Lantern - NetTransport.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Real transport: connects the phone app to the Mac host over the encrypted network layer.
//
// NetTransport.swift
//
// PURPOSE: The real transport. It adapts LanternCore's ClientConnection (encrypted UDP on the local
// network) to the app's SessionTransport protocol: pair with a Mac, connect, receive video frames,
// and send input events.
//
// WHO CALLS IT: ClientModel creates it (unless demo mode is on) and calls its methods; the video
// sink supplied by StreamView receives the frames it gets.
//
// KEY IDEAS:
//   - Network callbacks arrive on background threads, so each one hops to the main actor with
//     `Task { @MainActor in ... }` before touching app state.
//   - Pairing keys are stored by a `KeyStore` (the Keychain normally).
//   - The `conn === c` check in `handle` ignores late callbacks from an old, replaced connection.

import Foundation
import LanternCore

/// Real transport: pairs and connects with LanternCore's ClientConnection (Noise over UDP, LAN only).
/// Keys live in the Keychain. Unsigned simulator builds can fail Keychain with -34018; in DEBUG ONLY we then
/// fall back to an in-memory store and set `storeNotice` (shown in the red banner) because nothing is persisted.
// `@MainActor`: all methods run on the main thread (matches the SessionTransport protocol).
@MainActor
// `final` = no subclasses.
final class NetTransport: SessionTransport {
    /// Set by the model; called whenever the connection state changes.
    var onState: ((TransportState) -> Void)?
    /// Where incoming video frames are delivered.
    var videoSink: VideoSink?
    /// A warning to show the user when keys cannot be saved permanently (debug builds only); nil otherwise.
    private(set) var storeNotice: String?
    /// Where pairing keys are kept.
    private let keyStore: KeyStore
    /// The current network connection, if any.
    private var conn: ClientConnection?

    /// Diagnostics: last Network.framework reason from the current connection, and how many video frames arrived.
    /// The most recent low-level network error text from the current connection, if any.
    var lastNetworkError: String? { conn?.lastNetworkError }
    /// Count of video frames received (for debugging).
    private(set) var rxFrames = 0
    /// True when at least one paired Mac is stored. A key store error counts as not paired.
    var isPaired: Bool { ((try? keyStore.peers()) ?? []).isEmpty == false }

    /// Uses the given key store, or tries the Keychain and falls back to memory (debug builds only).
    init(keyStore: KeyStore? = nil) {
        // A caller-supplied store wins (for example one injected by a test).
        if let keyStore { self.keyStore = keyStore; return }
        // Otherwise try the real Keychain.
        let kc = KeychainKeyStore()
        // Attempt the probe below; any error jumps to `catch`.
        do {
            _ = try kc.loadOrCreateDeviceKey()          // probe: fails with -34018 when unsigned
            // It worked: use the Keychain.
            self.keyStore = kc
        } catch {
            // The Keychain probe failed. What happens next depends on the build type.
            #if DEBUG
            // Debug build:
            // Use a temporary in-memory store so development can continue.
            self.keyStore = InMemoryKeyStore()
            // Remember a warning for the UI, because nothing will be saved.
            storeNotice = "Keychain unavailable (\(error)). DEBUG build: keys are NOT persisted and are lost on quit."
            #else
            // Release build: never silently downgrade to memory.
            self.keyStore = kc    // release: never silently downgrade; pair/connect will surface the error
            // End of the debug/release split.
            #endif
        }
    }

    /// The error thrown for a badly formed host address.
    enum AddressError: Error, LocalizedError {
        // Only one kind of failure.
        case bad
        // The message shown to the user.
        var errorDescription: String? { "Enter the Mac as ip:port, for example 192.168.1.20:7777." }
    }

    /// Splits `ip:port` into the host text and port number; throws if the text is malformed.
    static func parse(_ host: String) throws -> (String, UInt16) {
        // Remove spaces around the text.
        let t = host.trimmingCharacters(in: .whitespaces)
        // Find the last colon and read the number after it as a port (must be 1...65535).
        guard let i = t.lastIndex(of: ":"), let p = UInt16(t[t.index(after: i)...]), p > 0 else { throw AddressError.bad }
        // Everything before the colon is the host.
        let h = String(t[..<i])
        // The host part must not be empty.
        guard !h.isEmpty else { throw AddressError.bad }
        // Return both parts.
        return (h, p)
    }

    /// Builds a ClientConnection for the host and wires its callbacks to this transport.
    private func makeConnection(_ host: String) throws -> ClientConnection {
        // Split the address text (throws if bad).
        let (h, p) = try Self.parse(host)
        // Default network settings, with a name the Mac can show for this device.
        var cfg = NetConfig(); cfg.deviceName = "Lantern iPhone"
        // The connection object, using our key store.
        let c = ClientConnection(host: h, port: p, keyStore: keyStore, config: cfg)
        // Each video frame: hop to the main actor, count it, and give it to the sink with the current time as its timestamp in microseconds.
        c.onVideoFrame = { [weak self] data, key in
            Task { @MainActor in self?.rxFrames += 1; self?.videoSink?.enqueue(annexB: data, isKey: key, ptsUs: UInt64(Date().timeIntervalSince1970 * 1e6)) }
        }
        // Each state change: hop to the main actor and handle it, passing which connection it came from.
        c.onStateChange = { [weak self, weak c] st in
            Task { @MainActor in self?.handle(st, from: c) }
        }
        // Hand back the new, not yet started connection.
        return c
    }

    /// Translates a connection state into a TransportState.
    private func handle(_ st: SessionState, from c: ClientConnection?) {
        // Ignore events from an old connection that has been replaced.
        guard let c, c === conn else { return }
        // Map each connection state.
        switch st {
        // Nothing happening yet: no change.
        case .idle: break
        // Handshake in progress.
        case .handshaking: onState?(.connecting)
        // Handshake done: video can flow.
        case .established: onState?(.streaming)
        // The connection ended.
        case .closed(let why):
            // Clear the display.
            videoSink?.reset()
            // A deliberate local close is plain idle; any other reason is shown as a failure.
            if why == .localClose { onState?(.idle) } else { onState?(.failed("Connection closed: \(why)")) }
        }
    }

    /// Pairs with the Mac using a typed code or a scanned QR payload.
    func pair(_ input: PairingInput, host: String) async throws {
        // Drop any previous connection first.
        conn?.disconnect()
        // Build a new connection.
        let c = try makeConnection(host)
        // Keep it so callbacks are recognised.
        conn = c
        // Tell the UI we are working.
        onState?(.connecting)
        // Run the pairing exchange, which may throw.
        do {
            // Typed 10-character code.
            switch input {
            case .code(let s): try await c.pair(code: s, deviceName: "Lantern iPhone")
            // QR payload text, parsed first.
            case .qrPayload(let s): try await c.pair(qr: try PairingQRPayload(parsing: s), deviceName: "Lantern iPhone")
            }
        // On failure: show the failure state, then pass the error up to the caller.
        } catch { onState?(.failed("Pairing failed")); throw error }
    }

    /// Starts streaming. After a fresh pairing the connection is already up, so it is just reused.
    func connect(host: String) async throws {
        // If the connection from pairing is already established, report streaming and ask for a key frame (a first full picture).
        if let c = conn, case .established = c.state { onState?(.streaming); try? c.send(control: .requestIDR); return }   // just paired
        // Otherwise drop any old connection.
        conn?.disconnect()
        // Build a new one.
        let c = try makeConnection(host)
        // Keep it.
        conn = c
        // Clear the display before new video.
        videoSink?.reset()
        // Tell the UI we are connecting.
        onState?(.connecting)
        // Do the handshake; on failure show a state and rethrow the error.
        do { try await c.connect() } catch { onState?(.failed("Could not connect")); throw error }
        // Ask the Mac for a key frame so the picture starts right away.
        try? c.send(control: .requestIDR)
    }

    /// Sends one input event. Without a connection it is silently ignored.
    func send(_ event: InputEvent) {
        // No connection: nothing to do.
        guard let c = conn else { return }
        // Send it; if sending throws, report a failure state.
        do { try c.send(input: event) } catch { onState?(.failed("Send failed: \(error)")) }
    }

    /// True if the host text parses as ip:port (no network used).
    func validate(host: String) -> Bool { (try? Self.parse(host)) != nil }

    /// ClientConnection.requestKeyframe() exists (rate-limited, returns Bool); this could delegate to it.
    /// For now .requestIDR is sent directly with no rate limit.
    func requestKeyframe() { try? conn?.send(control: .requestIDR) }

    /// Tells the Mac the bitrate we want (kbps converted to bits per second).
    func setBitrateHint(kbps: Int) { try? conn?.send(control: .bitrate(UInt32(kbps * 1000))) }

    /// Ends the connection, clears the picture and reports idle.
    func disconnect() {
        // Take the connection out of the property so no more callbacks match it.
        let c = conn; conn = nil
        // Close it.
        c?.disconnect()
        // Clear the display.
        videoSink?.reset()
        // Report idle.
        onState?(.idle)
    }

    /// Revokes every stored pairing so the phone no longer trusts any Mac.
    func forgetHost() {
        // Look up all paired peers (none if the lookup fails) and revoke each.
        for p in (try? keyStore.peers()) ?? [] { try? keyStore.revoke(p) }
    }
}
