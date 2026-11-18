// ==============================================================================
// Program: main.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Entry point of the lantern-host command-line program on macOS.
//          Commands: list-windows, capture-test, inject-test, serve.
//          Inputs: CLI arguments specifying operation mode, window selection, and network options.
//          Outputs: Low-latency H.264 video stream over encrypted UDP/Noise and processed input injection.
//          Design Rationale: Host is OFF by default; requires macOS Screen Recording and Accessibility
//          permissions; features Ctrl-C emergency kill switch releasing all simulated input.
// ==============================================================================
// main.swift - entry point of the `lantern-host` command-line program on the Mac.
// Who calls it: you, from Terminal. Commands: list-windows, capture-test, inject-test, serve.
// Host Architecture & Streaming Control:
//   - Safe by Default: The program never launches a server or captures video without explicit command arguments.
//   - Commands:
//     * `list-windows`: Queries macOS window server for candidate windows, displaying window IDs, process names, and titles.
//     * `capture-test`: Validates ScreenCaptureKit capture and VideoToolbox H.264 compression without starting network services.
//     * `inject-test`: Tests coordinate calculation and CGEvent synthesis; runs as a dry run by default to verify safety.
//     * `serve`: Initializes `HostSession`, launches UDP listener on a private LAN IP, and manages the authenticated streaming pipeline.
//   - Signal Handling & Emergency Kill Switch:
//     * Traps SIGINT (Ctrl-C) and SIGTERM using DispatchSourceSignal.
//     * Automatically terminates ScreenCaptureKit capture, closes UDP sockets, and releases all simulated keyboard/mouse buttons.

// CoreMedia: sample buffers and pixel-buffer sizes of captured frames.
import CoreMedia
// Dispatch: queues and signal sources (used for Ctrl-C handling).
import Dispatch
// Foundation: strings, files, dates, locks.
import Foundation

// Returns the current time as HH:mm:ss, used as a prefix on log lines.
func stamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date()) }
// LanternCore: the network server, key stores, InputEvent and settings.
import LanternCore
// LanternHostKit: window listing, capture, encoder, input injection, session glue.
import LanternHostKit

// Prints the help text and exits with code 2. `Never` means this function does not return.
func usage() -> Never {
    print("""
    lantern-host \(HostInfo.version) (host is off by default; nothing here starts a server)
      list-windows
      capture-test --window <substring> --out new-file.h264 [--seconds N<=30 | --long] [--fps N] [--kbps N] --confirm-window <id>
        (run once without --confirm-window to resolve and print the window; rerun with the printed id)
      inject-test --window <substring> [--event tap:0.5,0.5 | long:x,y | dragstart:x,y | dragmove:x,y | dragend:x,y | camstart:x,y | camend:x,y | cammove:x,y | scroll:dx,dy | zoom:d | key:text] [--really] [--allow-modifiers]
        (dry run by default: prints what WOULD be injected; --really posts real CGEvents)
      serve --bind <private LAN-IP> --port N --window-id <id from list-windows> [--pair [--qr]] [--allow-modifiers] [--auto-focus] [--keychain] [--pair-minutes N (0.5-15, default 2)] [--debug]
        (starts the encrypted server for that ONE window; --bind and --window-id are required, no wildcard, RFC1918/link-local only; key modifiers are stripped unless --allow-modifiers; capture runs only while a client is connected;
         the pairing code is printed to this terminal only with --pair; Ctrl-C or SIGTERM = kill switch)
    """)
    // Exit code 2 conventionally means 'wrong command-line usage'.
    exit(2)
}

// Finds `--name value` in the argument list and returns the value after it, or nil if the flag or its value is missing.
func opt(_ name: String, _ args: [String]) -> String? {
    // Position of the flag, and there must be one more item after it.
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    // The item right after the flag is its value.
    return args[i + 1]
}

// Parses text such as `tap:0.5,0.5` into an InputEvent (used by inject-test). Returns nil if it does not parse.
func parseEvent(_ s: String) -> InputEvent? {
    // Split at the first colon into [kind, values].
    let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
    // Must have both a kind and values.
    guard parts.count == 2 else { return nil }
    // Key text may itself contain commas or colons, so handle it before number parsing.
    if parts[0] == "key" { return .key(text: parts[1], mods: 0) }
    // Turn 'x,y' into a list of numbers; anything not a number is dropped.
    let n = parts[1].split(separator: ",").compactMap { Float($0) }
    // Match on the kind AND how many numbers it needs (two for a position, one for zoom).
    switch (parts[0], n.count) {
    // Each line maps a command word to an InputEvent.
    case ("tap", 2): return .tap(x: n[0], y: n[1])
    case ("long", 2): return .longPress(x: n[0], y: n[1])
    case ("dragstart", 2): return .dragStart(x: n[0], y: n[1])
    case ("dragmove", 2): return .dragMove(x: n[0], y: n[1])
    case ("dragend", 2): return .dragEnd(x: n[0], y: n[1])
    case ("camstart", 2): return .camStart(x: n[0], y: n[1])
    case ("cammove", 2): return .camMove(x: n[0], y: n[1])
    case ("camend", 2): return .camEnd(x: n[0], y: n[1])
    case ("scroll", 2): return .scroll(dx: n[0], dy: n[1])
    case ("zoom", 1): return .zoom(delta: n[0])
    // A key event with any number of values (we use the whole text).
    case ("key", _): return .key(text: parts[1], mods: 0)
    // Unknown kind or wrong number of values.
    default: return nil
    }
}

// A small thread-safe bundle of counters for capture-test (several threads update it).
final class Stats: @unchecked Sendable {
    // The lock that protects the counters.
    private let l = NSLock()
    // frames = packets encoded, keys = keyframes, bytes = total size, captured = frames received from capture.
    var frames = 0, keys = 0, bytes = 0, captured = 0, bFrameSuspect = 0
    // Run an update closure while holding the lock.
    func bump(_ f: (Stats) -> Void) { l.lock(); f(self); l.unlock() }
}

// The capture-test command: records ONE confirmed window to a new local file as raw H.264.
func captureTest(_ args: [String]) async -> Int32 {
    // Both --window and --out are required; otherwise show the help.
    guard let needle = opt("--window", args), let out = opt("--out", args) else { usage() }
    // Options with defaults: 5 seconds, 30 fps, 4000 kbit/s. A bad number becomes 0 (seconds) and is refused below.
    let secs = Double(opt("--seconds", args) ?? "5") ?? 0
    let fps = Int(opt("--fps", args) ?? "30") ?? 30
    let kbps = Int(opt("--kbps", args) ?? "4000") ?? 4000
    // Guards run first; none of them need Screen Recording permission or touch the screen.
    // Show every window that matches the search text.
    let cands = CaptureGuard.candidates(needle, in: WindowCapturer.listWindows())
    // Print each candidate on its own line.
    for c in cands { print("candidate: \(CaptureGuard.describe(c))") }
    // The single window we will record.
    let win: WindowInfo
    // Must resolve to exactly one window.
    switch CaptureGuard.resolve(needle, in: WindowCapturer.listWindows()) {
    // No match or several matches: print why and stop.
    case .failure(let f): print("error: \(f)"); return 1
    // Exactly one window: keep it.
    case .success(let w): win = w
    }
    // Safety check 1: the user must confirm the exact window id.
    if let f = CaptureGuard.requireConfirm(window: win, confirm: opt("--confirm-window", args)) { print("error: \(f)"); return 1 }
    // Safety check 2: positive length, within 30 seconds unless --long.
    if let f = CaptureGuard.checkSeconds(secs, long: args.contains("--long")) { print("error: \(f)"); return 1 }
    // Safety check 3: do not overwrite an existing file.
    if let f = CaptureGuard.checkPath(out) { print("error: \(f)"); return 1 }
    // Everything below can throw; one catch at the end prints the error.
    do {
        // Screen Recording permission must already be granted (this tool never asks).
        guard WindowCapturer.permissionGranted else { throw CaptureError.permissionDenied }
        // The output file handle.
        let fh: FileHandle
        // Create the file atomically with owner-only permissions.
        switch CaptureGuard.createExclusive(out) {
        case .failure(let f): print("error: \(f)"); return 1
        case .success(let h): fh = h
        }
        // Tell the user what is being recorded and that it stays local.
        print(CaptureGuard.banner)
        // The capturer for the chosen window.
        let cap = WindowCapturer(window: win, fps: fps)
        // Counters shared with the callbacks.
        let st = Stats()
        // Protects `enc`, which is created on the first frame from a capture thread.
        let lock = NSLock()
        // The encoder is created lazily. `nonisolated(unsafe)` tells Swift's concurrency checker we are handling thread safety ourselves with `lock`.
        nonisolated(unsafe) var enc: H264Encoder?
        // For every captured frame: count it, make the encoder on first use, and encode.
        cap.onSample = { sb in
            // One more frame received.
            st.bump { $0.captured += 1 }
            // Only one frame handled at a time.
            lock.lock(); defer { lock.unlock() }
            // First frame: now the real pixel size is known, create the encoder with it.
            if enc == nil, let pb = CMSampleBufferGetImageBuffer(sb) {
                // Encoder sized to the frame; kbps * 1000 converts to bits per second.
                let e = try? H264Encoder(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), bitrate: kbps * 1000, fps: fps)
                // Each compressed packet is written straight to the file and counted.
                e?.onPacket = { p in
                    // Append the bytes.
                    try? fh.write(contentsOf: p.annexB)
                    // Update the counters (including keyframes).
                    st.bump { $0.frames += 1; $0.bytes += p.annexB.count; if p.isKey { $0.keys += 1 } }
                }
                // Keep it for later frames.
                enc = e
            }
            // Compress this frame.
            try? enc?.encode(sb)
        }
        // If the system ends capture (sleep, lock...), print why.
        cap.onAutoStop = { why in print("auto-stopped: \(why)") }
        // Start capturing.
        try await cap.start()
        // Let it run for the requested number of seconds (converted to nanoseconds).
        try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        // Stop capturing.
        await cap.stop()
        // Flush and close the encoder under the lock and note whether hardware was used.
        let hw: Bool? = lock.withLock { enc?.finish(); return enc?.usingHardware }
        // Close the file.
        try? fh.close()
        // Summary line.
        print("captured=\(st.captured) encoded=\(st.frames) keyframes=\(st.keys) bytes=\(st.bytes) hardware=\(hw.map(String.init) ?? "n/a") out=\(out)")
        // Success exit code.
        return 0
    // Any thrown error: print it and return failure code 1.
    } catch {
        print("error: \(error)"); return 1
    }
}

// The inject-test command: dry run by default; with --really it sends real events to one window.
func injectTest(_ args: [String]) -> Int32 {
    // --window is required.
    guard let needle = opt("--window", args) else { usage() }
    // Only --really makes it post real events.
    let really = args.contains("--really")
    // Collect every --event argument and parse each one.
    let evs = args.indices.filter { args[$0] == "--event" && $0 + 1 < args.count }.compactMap { parseEvent(args[$0 + 1]) }
    // Default to one tap in the middle if none were given.
    let events = evs.isEmpty ? [InputEvent.tap(x: 0.5, y: 0.5)] : evs
    // resolve throws if there is not exactly one matching window.
    do {
        // The chosen window.
        let win = try WindowCapturer.resolve(needle)
        // Dry run branch.
        if !really {
            // Dry run: plans against the window frame only; reads nothing that needs permission, injects nothing.
            // Show the plan for each event.
            for e in events {
                // A nil plan means out-of-range coordinates or unsafe key text.
                guard let plan = InputPlanner.plan(e, frame: win.frame, allowModifiers: args.contains("--allow-modifiers")) else { print("\(e): DROPPED (out of range)"); continue }
                // Print the actions that WOULD happen.
                print("WOULD inject \(e) -> " + plan.map(\.description).joined(separator: ", "))
            }
            // Remind how to do it for real.
            print("dry run (pass --really to inject)")
            return 0
        }
        // Real injection needs the Accessibility permission.
        guard CGEventSink.accessibilityGranted else { print("error: \(InjectError.accessibilityDenied)"); return 1 }
        // Build the injector with the real event sink and the chosen flags.
        let inj = InputInjector(target: win, sink: CGEventSink(), allowModifiers: args.contains("--allow-modifiers"), autoFocus: args.contains("--auto-focus"))
        // Apply each event; stop at the first refusal.
        for e in events {
            // On refusal print why, let go of anything held, and return failure.
            do { try inj.apply(e); print("injected \(e)") } catch { print("refused \(e): \(error)"); inj.releaseAll(); return 1 }
        }
        // Always release held buttons at the end.
        inj.releaseAll()
        return 0
    // Resolve failure (no or several matching windows).
    } catch { print("error: \(error)"); return 1 }
}

// A one-shot 'stop now' signal: a task can wait() until another thread calls fire(). Works even if fire() happens first.
final class StopFlag: @unchecked Sendable {
    // l = lock, c = the waiting continuation (a saved 'resume here later' point), fired = already triggered?
    private let l = NSLock(); private var c: CheckedContinuation<Void, Never>?; private var fired = false
    // Mark as fired and wake the waiter, if any.
    func fire() { l.lock(); fired = true; let k = c; c = nil; l.unlock(); k?.resume() }
    // Suspend until fired (returns immediately if it already was).
    func wait() async { await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        l.lock(); if fired { l.unlock(); k.resume() } else { c = k; l.unlock() } } }
}

// The serve command: starts the encrypted server for ONE window and runs until Ctrl-C or SIGTERM.
func serve(_ args: [String]) async -> Int32 {
    // Required options come first; each failure prints a clear message and returns an error code.
    guard let bind = opt("--bind", args), !bind.isEmpty else { print("error: --bind <LAN-IP> is required (no default, no wildcard)"); return 2 }
    // --window-id must be a number from list-windows.
    guard let idText = opt("--window-id", args), let wid = UInt32(idText) else { print("error: --window-id <id> is required (see list-windows)"); return 2 }
    // --port must be 1 to 65535.
    guard let portText = opt("--port", args), let port = UInt16(portText), port > 0 else { print("error: --port N (1-65535) is required"); return 2 }
    // The window must currently be on screen.
    guard let win = WindowCapturer.listWindows().first(where: { $0.id == wid }) else { print("error: no on-screen window with id \(wid)"); return 1 }
    // Screen Recording permission is required (check only).
    guard WindowCapturer.permissionGranted else { print("error: \(CaptureError.permissionDenied)"); return 1 }
    // Accessibility permission is required (check only).
    guard CGEventSink.accessibilityGranted else { print("error: \(InjectError.accessibilityDenied)"); return 1 }
    // Warn that touches may bring the app to the front.
    if args.contains("--auto-focus") { print("[lantern] --auto-focus ON: a paired phone's touch may bring \(win.ownerName) to the front") }
    // Say which window is being served.
    print("serving window \(win.id): \(win.ownerName) / \(win.title.isEmpty ? "(no title)" : win.title) \(Int(win.frame.width))x\(Int(win.frame.height))")
    // --keychain opts in to saving keys in the system Keychain.
    // Keys live in memory only by default: the login Keychain asks for the Mac password on each access by an ad-hoc signed binary,
    // and those reads/writes happen on the handshake thread, so the phone times out (error 6) while the dialog is open.
    // `--keychain` opts in to saving keys in the Keychain (expect password prompts; pairing may time out while they are open).
    let useKeychain = args.contains("--keychain")
    // Network settings, with the default pairing-code lifetime unless changed below.
    var cfg = NetConfig()
    // Accept 0.5 to 15 minutes; other values are ignored.
    if let m = opt("--pair-minutes", args), let minutes = Double(m), minutes >= 0.5, minutes <= 15 { cfg.pairingCodeLifetime = minutes * 60 }
    // Create the server with the chosen key store (Keychain or memory).
    let server = HostServer(keyStore: useKeychain ? KeychainKeyStore(service: "org.twu.lantern.host", useDataProtectionKeychain: false) as KeyStore : InMemoryKeyStore(), config: cfg)
    // Optional extra logging.
    if args.contains("--debug") { server.onDebug = { print("\(stamp()) [lantern] debug: \($0)") } }
    // Tell the user where keys are kept.
    print(stamp() + (useKeychain ? " [lantern] keys: saved in the login Keychain (--keychain); the Mac may ask for your password" : " [lantern] keys: in memory only (not saved; the phone must pair again after the host restarts)"))
    // Glue it together: video source for this window and an injector bound to it.
    let session = HostSession(server: server, source: WindowFrameSource(window: win),
                              injector: InputInjector(target: win, sink: CGEventSink(), allowModifiers: args.contains("--allow-modifiers"), autoFocus: args.contains("--auto-focus")))
    // Print session log lines with a timestamp.
    session.onLog = { print("\(stamp()) [lantern] \($0)") }
    // Print server state changes.
    server.onStateChange = { print("\(stamp()) [lantern] state: \($0)") }
    // Will be fired by Ctrl-C or SIGTERM.
    let stop = StopFlag()
    // Ignore the default signal behaviour so we can shut down cleanly ourselves.
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    // A signal source is a Dispatch object that calls us when a signal arrives.
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        // Create one for each signal.
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        // When the signal arrives, print and fire the stop flag (the kill switch).
        s.setEventHandler { print("[lantern] kill switch (signal \(sig))"); stop.fire() }
        // Start listening.
        s.resume(); return s
    }
    // Keep the array alive so the signal sources are not freed.
    _ = sources
    // Start listening, then maybe open pairing.
    do {
        // Start the server on the private LAN address; it returns the port actually bound.
        let bound = try await server.start(bindAddress: bind, port: port)
        // Announce.
        print("[lantern] listening on \(bind):\(bound) (encrypted; only paired devices; Ctrl-C stops)")
        // Pairing is off unless --pair was passed.
        if args.contains("--pair") {
            // QR mode prints a payload to turn into a QR code; otherwise a typed code.
            if args.contains("--qr") {
                // The printed lifetime text is fixed; the real lifetime follows --pair-minutes.
                print("pairing QR payload (valid ~2 min, single use): \(try server.beginPairingQR(addressHint: "\(bind):\(bound)").encoded())")
            } else {
                print("pairing code (valid ~\(Int(cfg.pairingCodeLifetime / 60 * 10) % 10 == 0 ? "\(Int(cfg.pairingCodeLifetime / 60))" : String(format: "%.1f", cfg.pairingCodeLifetime / 60)) min, single use): \(try server.beginPairing().displayString)")
            }
        // No --pair: pairing stays closed.
        } else { print("[lantern] pairing closed (pass --pair to open it)") }
    // Startup failed: print, shut down cleanly, return failure.
    } catch { print("error: \(error)"); await session.shutdown(); return 1 }
    // Block here until a stop signal arrives.
    await stop.wait()
    // Kill switch: stop capture, release input, close the server.
    await session.shutdown()
    // Confirm everything is off.
    print("[lantern] stopped; capture off, input released, server closed")
    return 0
}

// ---- Program entry point: top-level code runs from here ----
// Drop the program name; what remains are the user's arguments.
let args = Array(CommandLine.arguments.dropFirst())
// The first word picks the command.
switch args.first {
// Prints one line per window: id, owner, title, size and position.
case "list-windows":
    // Candidate windows only (normal layer, real size).
    let ws = WindowCapturer.listWindows()
    for w in ws {
        print("\(w.id)\t\(w.ownerName)\t\(w.title.isEmpty ? "(no title)" : w.title)\t\(Int(w.frame.width))x\(Int(w.frame.height))@\(Int(w.frame.minX)),\(Int(w.frame.minY))")
    }
    // Titles are hidden without Screen Recording permission, so say so.
    if !WindowCapturer.permissionGranted { print("note: Screen Recording not granted; titles of other apps' windows are hidden") }
// Run the chosen command and exit with its result code.
case "capture-test": exit(await captureTest(args))
case "serve": exit(await serve(args))
case "inject-test": exit(injectTest(args))
// No command: just print the version; nothing starts.
case nil: print("lantern-host", HostInfo.version, "(not started: host is off by default)")
// Unknown command: show help.
default: usage()
}
