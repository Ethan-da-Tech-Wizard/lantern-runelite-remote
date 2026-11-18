// ClientModel.swift
//
// PURPOSE: The single "brain" object for the UI. It remembers which screen is showing, the
// connection state, saved settings, and a banner message, and it forwards user input to the transport.
//
// WHO CALLS IT: Views.swift creates one (as a @StateObject) and passes it to every screen;
// StreamView sends touch events to it via `send(_:)`.
//
// KEY IDEAS:
//   - `ObservableObject` + `@Published`: when a published property changes, every SwiftUI view
//     that reads it redraws automatically.
//   - The model never does networking itself. It talks to a `SessionTransport` (real or demo).
//   - `#if DEBUG` blocks are compiled only into debug builds; they hold test helpers driven by
//     launch arguments and are absent from release builds.

import Foundation
import SwiftUI
import LanternCore

// `@MainActor`: all of this class runs on the main thread, which is what UI state requires.
/// The app's shared state and actions. Screens read it and call its methods.
@MainActor
// `final` = nobody can subclass it (simpler and slightly faster).
final class ClientModel: ObservableObject {
    /// Which top-level screen is visible: the pairing form, or the live stream.
    enum Screen { case pair, connected }

    // `@Published` = SwiftUI watches this value and redraws when it changes.
    /// Which screen is showing right now.
    @Published var screen: Screen = .pair
    /// Connection life cycle (idle, connecting, streaming, failed), mirrored from the transport.
    @Published var state: TransportState = .idle
    /// A short message shown in a red strip at the top; nil means no message.
    @Published var banner: String?
    /// The Mac's `ip:port` text. `didSet` runs after every change and saves it to UserDefaults.
    @Published var hostAddress: String { didSet { defaults.set(hostAddress, forKey: "hostAddress") } }
    /// Requested video bitrate in kbps. On change it is saved and also sent to the transport as a hint.
    @Published var bitrateKbps: Int { didSet { defaults.set(bitrateKbps, forKey: "bitrateKbps"); transport.setBitrateHint(kbps: bitrateKbps) } }
    /// How many input events have been sent (shown in the menu for debugging). Only this class may change it.
    @Published private(set) var eventCount = 0
    /// Text description of the most recent event (never contains typed characters).
    @Published private(set) var lastEvent = "none"

    /// The thing that really sends and receives data (network or demo).
    let transport: SessionTransport
    private let defaults = UserDefaults.standard   // non-secret prefs only; keys belong in Keychain (Net layer)

    /// Builds the model. Pass a transport for tests; otherwise one is chosen from launch arguments.
    init(transport: SessionTransport? = nil) {
        // Demo mode is switched on by a launch argument; it swaps in the fake offline transport.
        let demo = ProcessInfo.processInfo.arguments.contains { $0 == "-LanternDemo" || $0 == "-LanternDemoAutoPair" }
        // Use the injected transport if given, otherwise demo or real depending on the flag above.
        self.transport = transport ?? (demo ? DemoTransport() : NetTransport())
        // Show any key-store warning (for example keychain unavailable) from the real transport.
        banner = (self.transport as? NetTransport)?.storeNotice
        // Load the saved host address (empty text if nothing was saved yet).
        hostAddress = UserDefaults.standard.string(forKey: "hostAddress") ?? ""
        // Load the saved bitrate; 0 means never saved, so use 4000 kbps, otherwise keep it between 1000 and 15000.
        let b = UserDefaults.standard.integer(forKey: "bitrateKbps")
        bitrateKbps = b == 0 ? 4000 : min(max(b, 1000), 15000)
        // When the transport reports a new state, `handle(_:)` stores it. `[weak self]` avoids a retain loop.
        self.transport.onState = { [weak self] s in self?.handle(s) }
        // If a Mac is already paired, skip the pairing screen.
        if self.transport.isPaired { screen = .connected }
        // (Everything inside this block is compiled into debug builds only.)
        #if DEBUG
        // Agent-driven test (devicectl/simctl launch arguments, no taps): -LanternHost ip:port -LanternAutoPair CODE [-LanternAutoTap x,y]
        // Prints one LANTERN_DBG line per second to the console so a script can see state, errors, frames and events.
        // Only when no transport was injected (a real app launch, not a test).
        if transport == nil {
            // Collect the launch arguments.
            let args = ProcessInfo.processInfo.arguments
            // Local helper: finds a flag in the launch arguments and returns the word after it, or nil.
            func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
            // Pre-fill the host from the launch argument.
            if let h = arg("-LanternHost") { hostAddress = h }
            // Remember an optional tap position to send once streaming starts.
            autoTap = arg("-LanternAutoTap")
            // Pair automatically with the supplied code, without any screen taps.
            if let code = arg("-LanternAutoPair") { Task { await self.pair(code) } }
            // Start a once-per-second debug printout, but only if a debug argument was given.
            if arg("-LanternHost") != nil || arg("-LanternAutoPair") != nil {
                Task { @MainActor in
                    var n = 0
                    // Loop forever, once a second (the task ends with the app).
                    while true {
                        // Wait one second, then count it.
                        try? await Task.sleep(nanoseconds: 1_000_000_000); n += 1
                        // Peek at the real transport's counters if that is what we are using.
                        let nt = self.transport as? NetTransport
                        // One line of state that a script can read from the console (no typed text is included).
                        print("LANTERN_DBG t=\(n) screen=\(self.screen) state=\(self.state) host=\(self.hostAddress) paired=\(self.transport.isPaired) rx=\(nt?.rxFrames ?? 0) events=\(self.eventCount) last=\(self.lastEvent) nwerr=\(nt?.lastNetworkError ?? "-") banner=\(self.banner ?? "-")")
                    }
                }
            }
        }
        // Simulator smoke test: `simctl launch ... -LanternDemoAutoPair` skips the pair screen (demo transport only).
        if transport == nil, ProcessInfo.processInfo.arguments.contains("-LanternDemoAutoPair") {
            Task { await pair("ABCDE-FGHJK") }
        }
        #endif
    }

    #if DEBUG
    // Debug-only storage for the automatic tap test (position text, and whether it already ran).
    private var autoTap: String?
    private var autoTapped = false
    #endif

    /// Called whenever the transport reports a new state.
    private func handle(_ s: TransportState) {
        // Remember the state so views can show it.
        state = s
        #if DEBUG
        // The first time streaming begins, send the automatic test tap (debug builds only).
        if case .streaming = s, let t = autoTap, !autoTapped {
            // Mark it done so it only happens once.
            autoTapped = true
            // Parse the x,y text into two numbers.
            let v = t.split(separator: ",").compactMap { Float($0) }
            // If both numbers parsed, wait 2 seconds (let video settle) and send one tap.
            if v.count == 2 { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.send(.tap(x: v[0], y: v[1])) } }
        }
        #endif
        // A failure also becomes the red banner text.
        if case .failed(let m) = s { banner = m }
    }

    /// Validates input locally (no network) then hands it to the transport.
    func pair(_ raw: String) async {
        // Step 1: clean up the text (remove spaces/newlines at the ends).
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Will hold either a QR payload or a plain code once the text is checked.
        let input: PairingInput
        // QR text starts with a known prefix.
        if text.hasPrefix(PairingQRPayload.prefix) {
            // Parse only to check it is valid (the parsed value is thrown away). On failure, show a message and stop.
            do { _ = try PairingQRPayload(parsing: text) } catch { banner = "That QR text is not valid."; return }
            // Keep the original text; the transport does the real work.
            input = .qrPayload(text)
        } else {
            // Otherwise treat it as the typed 10-character code: same idea, check the format locally (no network yet).
            do { _ = try PairingCode(parsing: text) } catch { banner = "Enter the 10-character code shown on the Mac."; return }
            input = .code(text)
        }
        // Step 2: check the host looks like ip:port before touching the network.
        guard transport.validate(host: hostAddress) else {
            banner = "Enter the Mac as ip:port, for example 192.168.1.20:7777."; return
        }
        // Everything looked fine, so clear any old message.
        banner = nil
        // Step 3: do the pairing. `try await` waits for the network and may throw.
        do {
            try await transport.pair(input, host: hostAddress)
            // Success: show the stream screen and start connecting.
            screen = .connected
            await connect()
        } catch {
            // Add the low-level network reason, if there is one, in brackets, then tell the user why pairing failed.
            let why = (transport as? NetTransport)?.lastNetworkError.map { " [\($0)]" } ?? ""
            banner = "Pairing failed: \(error.localizedDescription)\(why)"
        }
    }

    /// Opens the streaming session with the saved host and shows an error banner if that fails.
    func connect() async {
        // Clear any old message first.
        banner = nil
        do { try await transport.connect(host: hostAddress) }
        catch {
            // Append the low-level network reason if one is available.
            let why = (transport as? NetTransport)?.lastNetworkError.map { " [\($0)]" } ?? ""
            banner = "Could not connect: \(error.localizedDescription)\(why)"
        }
    }

    /// Closes the session and goes back to the pairing screen (keys stay saved).
    func disconnect() { transport.disconnect(); screen = .pair }

    /// Closes the session, deletes the saved pairing keys and host address, and returns to the pairing screen.
    func forgetHost() {
        // Stop streaming first.
        transport.disconnect()
        // Delete the stored keys for the paired Mac.
        transport.forgetHost()
        // Forget the typed address too.
        hostAddress = ""
        // Back to the pair screen.
        screen = .pair
    }

    /// Single choke point for input: one call per gesture, straight to the transport.
    func send(_ e: InputEvent) {
        // Input is only sent while video is streaming; otherwise the event is silently ignored.
        guard state == .streaming else { return }
        // Hand it to the transport right away (no queue, no repeat).
        transport.send(e)
        // Count it for the menu readout.
        eventCount += 1
        // Remember a text description of it for the menu readout.
        lastEvent = Self.describe(e)
    }

    /// Turns an event into short readable text for the debug line. Coordinates are shown with 2 decimals.
    static func describe(_ e: InputEvent) -> String {
        // Tiny helper: format a Float with two digits after the decimal point.
        func f(_ v: Float) -> String { String(format: "%.2f", v) }
        // One readable label per kind of event (a long press is a right-click on the Mac).
        switch e {
        case .tap(let x, let y): return "tap \(f(x)),\(f(y))"
        case .longPress(let x, let y): return "right-click \(f(x)),\(f(y))"
        case .dragStart(let x, let y): return "drag start \(f(x)),\(f(y))"
        case .dragMove(let x, let y): return "drag move \(f(x)),\(f(y))"
        case .dragEnd(let x, let y): return "drag end \(f(x)),\(f(y))"
        case .scroll(let dx, let dy): return "scroll \(f(dx)),\(f(dy))"
        case .zoom(let d): return "zoom \(f(d))"
        case .camStart(let x, let y): return "camera start \(f(x)),\(f(y))"
        case .camMove(let x, let y): return "camera move \(f(x)),\(f(y))"
        case .camEnd(let x, let y): return "camera end \(f(x)),\(f(y))"
        case .key: return "key"   // never display typed text
        }
    }
}
