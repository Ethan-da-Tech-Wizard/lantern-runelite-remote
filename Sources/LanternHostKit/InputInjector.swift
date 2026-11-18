// InputInjector.swift - turns phone touches/keys into real mouse/keyboard events on the Mac, but only after
// many safety checks pass.
// Who calls it: HostSession (serving) and lantern-host's inject-test.
// Key ideas for beginners: 'Accessibility' is a macOS permission that lets a program watch windows and post
// events. 'Focus' = which window receives keystrokes; 'frontmost' = which app is in front; 'occluded' = another
// window covers the spot. The injector refuses (throws) instead of guessing. It acts on ONE target window
// and never on others. Protocols (WindowEnvironment, ActionSink) let tests run without touching the screen.

// ApplicationServices: the Accessibility API (AXUIElement...), which lets a program ask which window has focus and requires the user's Accessibility permission.
import ApplicationServices
// CoreGraphics: CGEvent (synthetic mouse/keyboard events), CGPoint, CGRect.
import CoreGraphics
// Foundation: basic types, Process, locks.
import Foundation
// AppKit: NSWorkspace (which app is frontmost).
import AppKit
// LanternCore: InputEvent and HostInputGate (rate limiting and held-button tracking).
import LanternCore

/// Every reason an input event can be refused. The injector prefers to refuse over guessing.
public enum InjectError: Error, Equatable, CustomStringConvertible, Sendable {
    // Each case is one safety rule that failed.
    case windowGone
    // The target's app is not the front app and auto-focus is off.
    case notFrontmost
    // Auto-focus tried but the app still did not come to the front.
    case focusNotAcquired(front: Int32?, target: Int32)   // auto-focus asked macOS to bring the app forward but it did not become frontmost
    // Something else covers the spot where we would click.
    case occluded            // another window is on top at the target point
    // Same as occluded, with a description of what covers it (for the log).
    case occludedBy(String)  // same, naming the covering window (owner/layer) for the log
    // The point is not inside the target window.
    case outsideWindow       // coordinates invalid, or pointer not inside window for scroll/key
    // The rate limiter / drag-state gate said no.
    case rejected            // rate limit / drag-state gate
    // The program lacks the Accessibility permission.
    case accessibilityDenied
    // The app is front but another of its windows has keyboard focus.
    case notFocused          // the captured window itself is not the focused window of its app
    // We could not find out which window has focus.
    case focusUnknown        // Accessibility could not tell which window is focused; refusing
    // Human-readable messages (shown in logs and at the terminal).
    public var description: String {
        switch self {
        case .windowGone: return "target window no longer exists"
        case .notFrontmost: return "target window's app is not frontmost; refusing (start the host with --auto-focus to let it bring the app forward)"
        case .focusNotAcquired(let f, let t): return "asked macOS to bring app pid \(t) forward (auto-focus) but pid \(f.map(String.init) ?? "none") is still in front; refusing"
        case .occludedBy(let w): return "another window covers the target point (\(w)); refusing"
        case .occluded: return "another window covers the target point; refusing"
        case .outsideWindow: return "event falls outside the target window; refusing"
        case .rejected: return "event rejected by rate limit or drag-state gate"
        case .accessibilityDenied: return "Accessibility permission not granted to this process"
        case .notFocused: return "the captured window is not the focused window (another window of the app has focus); refusing"
        case .focusUnknown: return "cannot determine the focused window (Accessibility unavailable); refusing"
        }
    }
}

// 'Focus' means which window receives keystrokes right now.
/// Which window of the frontmost app has keyboard focus.
public enum FocusedWindow: Equatable, Sendable {
    // Four possible answers to 'which window is focused?'.
    case window(UInt32)     // CG window id of the focused window
    case other              // focused window exists but is not a window we can identify
    case none               // app has no focused window
    case unavailable        // Accessibility not trusted / query failed
}

// A protocol describing what we need to know about the desktop. The real one asks macOS; tests give fake answers.
/// Live facts about the desktop. Protocol so the safety rules are testable without a display.
public protocol WindowEnvironment: Sendable {
    // Where is the window now? nil if it no longer exists.
    func frame(ofWindow id: UInt32) -> CGRect?
    // Process id of the app in front (nil if unknown).
    func frontmostPID() -> Int32?
    // Which window is visually on top at a screen point?
    /// Topmost normal window at a global point (owner pid and window id).
    func topWindow(at point: CGPoint) -> (id: UInt32, pid: Int32)?
    // Where the mouse pointer currently is.
    func cursorLocation() -> CGPoint?
    // See FocusedWindow above.
    /// The focused window of the frontmost app (Accessibility AXFocusedWindow mapped to a CG window id).
    func focusedWindow() -> FocusedWindow
    // Bring an app to the front.
    /// Ask macOS to bring the app with this pid to the front. Default: do nothing (tests and dry runs).
    func activateApp(pid: Int32)
}

// An extension gives a default implementation, so fakes need not write it.
public extension WindowEnvironment {
    // Default: do nothing.
    func activateApp(pid: Int32) {}
}

/// Something that carries out PlannedActions: the real one posts OS events, the test one just records them.
public protocol ActionSink: Sendable {
    // Do (or record) one action; may throw if not allowed.
    func perform(_ a: PlannedAction) throws
}

// Test/dry-run helper. @unchecked Sendable because the lock protects its list.
/// Dry-run sink: records what WOULD be done. Never touches the OS.
public final class RecordingSink: ActionSink, @unchecked Sendable {
    // Guards the list from concurrent access.
    private let lock = NSLock()
    // Everything recorded so far, in order.
    private var _actions: [PlannedAction] = []
    // Empty list to start.
    public init() {}
    // Copy of what was recorded.
    public var actions: [PlannedAction] { lock.lock(); defer { lock.unlock() }; return _actions }
    // Append the action instead of doing it.
    public func perform(_ a: PlannedAction) throws { lock.lock(); _actions.append(a); lock.unlock() }
}

// The heart of input safety: it checks many rules, and only then lets the sink act.
/// Injects exactly the planned actions of one InputEvent per `apply`. No timers, retries or queueing; auto-focus only with the explicit opt-in flag.
public final class InputInjector: @unchecked Sendable {
    // The id of the one window we may act on.
    public let target: UInt32
    // Process id of that window's app.
    private let targetPID: Int32
    // Source of desktop facts (real or fake).
    private let env: WindowEnvironment
    // Where approved actions go.
    private let sink: ActionSink
    // Returns the current time in milliseconds (replaceable in tests).
    private let clock: @Sendable () -> UInt64
    // Makes apply and releaseAll run one at a time.
    private let lock = NSLock()
    // Rate limiter and tracker of which mouse buttons are down.
    private var gate: HostInputGate
    // Last left-button drag position (so a mouse-up can be sent there if we must let go).
    private var lastDragPoint: CGPoint?
    // Same for the middle-button camera drag.
    private var lastCamPoint: CGPoint?

    // Whether ctrl/alt/cmd/shift bits from the phone are honoured.
    private let allowModifiers: Bool
    // Whether we may bring the target app forward ourselves.
    /// Opt-in (host flag `--auto-focus`, default off): when the target app is not frontmost, bring it forward ONCE per second,
    /// wait at most 800 ms for the switch, and still refuse if it did not happen. All other checks (focused window is the target,
    /// nothing covering the click point, inside the window, rate limits) are unchanged and still run.
    private let autoFocus: Bool
    // Time of the last bring-to-front request (limits it to once a second).
    private var lastActivateMs: UInt64 = 0

    // Spells out all tunables; the defaults are the safe ones.
    /// `allowModifiers` (host flag `--allow-modifiers`, default off): without it key events are typed as plain text
    /// and ctrl/alt/cmd/shift bits from the client are stripped.
    public init(target: WindowInfo, environment: WindowEnvironment = SystemWindowEnvironment(),
                sink: ActionSink, minSpacingMs: UInt64 = 50, globalMax: Int = 40, allowModifiers: Bool = false, autoFocus: Bool = false,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }) {
        // Remember which window and app we are bound to.
        self.target = target.id; self.targetPID = target.ownerPID
        // Store collaborators and options.
        self.env = environment; self.sink = sink; self.clock = clock
        self.allowModifiers = allowModifiers
        self.autoFocus = autoFocus
        // Build the rate limiter with the chosen spacing and global limit.
        self.gate = HostInputGate(minSpacingMs: minSpacingMs, globalMax: globalMax)
    }

    /// Checks every safety rule for one event and, only if all pass, performs it. Throws InjectError on refusal.
    public func apply(_ event: InputEvent) throws {
        // One event at a time.
        lock.lock(); defer { lock.unlock() }
        // Rule 1: the window must still exist; we use its CURRENT frame (it may have moved).
        guard let frame = env.frame(ofWindow: target) else { throw InjectError.windowGone }
        // Rule 2: the target app must be in front.
        if env.frontmostPID() != targetPID {
            // Without auto-focus that is a refusal.
            guard autoFocus else { throw InjectError.notFrontmost }
            // With auto-focus: ask macOS to bring it forward at most once a second...
            let now = clock()
            if now &- lastActivateMs >= 1000 { lastActivateMs = now; env.activateApp(pid: targetPID) }
            // ...then wait up to 800 milliseconds, checking every 20 ms (Thread.sleep pauses this thread).
            var waited = 0
            while env.frontmostPID() != targetPID && waited < 800 { Thread.sleep(forTimeInterval: 0.02); waited += 20 }
            // If it still is not in front, refuse.
            guard env.frontmostPID() == targetPID else { throw InjectError.focusNotAcquired(front: env.frontmostPID(), target: targetPID) }
        }
        // Rule 3: keys and mouse go to the key window of the app, which must be our target. Match on the four possible answers.
        // Keys and mouse go to the key window of the app: that must be the captured window itself.
        switch env.focusedWindow() {
        case .window(let id) where id == target: break
        case .unavailable: throw InjectError.focusUnknown
        default: throw InjectError.notFocused
        }
        // Plan the event into primitive actions; nil means bad coordinates or text, so refuse.
        guard let actions = InputPlanner.plan(event, frame: frame, allowModifiers: allowModifiers) else { throw InjectError.outsideWindow }
        // Rule 4: check every positional action before doing any of them.
        for a in actions {
            // Only actions with a screen point need position checks.
            if let p = a.point {
                // The point must be inside the window.
                guard WindowGeometry.contains(p, in: frame) else { throw InjectError.outsideWindow }
                // A release is always allowed (otherwise a button could stay stuck down); every other action must not be covered by another window.
                // Release (mouse-up) may land after another window appears; only refuse non-release actions.
                // Skip the check for mouse-up; for others, find the top window at that point.
                if case .leftUp = a {} else if case .otherUp = a {} else if var top = env.topWindow(at: p), top.id != target {
                    // If something else is on top, auto-focus mode gives the raise a short time to finish.
                    // With auto-focus the raise lands a moment after the app becomes frontmost: give it time to settle.
                    // Poll up to 800 ms; re-ask to raise at 200 ms and 500 ms.
                    if autoFocus {
                        var w = 0
                        while top.id != target && w < 800 {
                            Thread.sleep(forTimeInterval: 0.02); w += 20
                            if w == 200 || w == 500 { env.activateApp(pid: targetPID) }
                            if let t = env.topWindow(at: p) { top = t } else { break }
                        }
                    }
                    // Still covered: describe the covering window for the log, then refuse.
                    if top.id != target {
                        // Look up the covering window's owner and size by id.
                        let who = WindowLister.windows(onScreenOnly: true).first { $0.id == top.id }
                        // Build a short description such as owner, id, layer and size.
                        throw InjectError.occludedBy(who.map { "\($0.ownerName) id \($0.id) layer \($0.layer) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "id \(top.id)")
                    }
                }
            }
        }
        // Rule 5: scroll and key events act at the pointer / focus rather than at a planned point, so check the pointer too.
        // Scroll and keys act at the current pointer / focus: pointer must be inside the target window.
        // Only these three event kinds.
        switch event {
        // The pointer must be inside the window and the window must be on top there.
        case .scroll, .zoom, .key:
            guard let c = env.cursorLocation(), WindowGeometry.contains(c, in: frame) else { throw InjectError.outsideWindow }
            if let top = env.topWindow(at: c), top.id != target { throw InjectError.occluded }
        // All other events already checked above.
        default: break
        }
        // Rule 6: the rate limiter and drag-state gate (e.g. a drag move without a drag start is rejected).
        guard gate.admit(event, nowMs: clock()) else { throw InjectError.rejected }
        // All checks passed: carry out the planned actions in order.
        for a in actions { try sink.perform(a) }
        // Remember where drags are, so releaseAll can let go at the right spot.
        switch event {
        case .dragStart(let x, let y), .dragMove(let x, let y):
            lastDragPoint = WindowGeometry.point(normX: x, normY: y, in: frame)
        // Ended: forget the position.
        case .dragEnd: lastDragPoint = nil
        case .camStart(let x, let y), .camMove(let x, let y):
            lastCamPoint = WindowGeometry.point(normX: x, normY: y, in: frame)
        case .camEnd: lastCamPoint = nil
        default: break
        }
    }

    // Called when a client disconnects or the host stops, to make sure no button stays held.
    /// Mouse-up for anything held. Always attempts the release, even if the window moved or vanished.
    public func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        // Ask the gate which buttons it believes are down.
        let held = gate.releaseAll()
        // Send a mouse-up for each held button; errors are ignored (best effort).
        if held.contains(.left), let p = lastDragPoint { try? sink.perform(.leftUp(p)) }
        if held.contains(.middle), let p = lastCamPoint { try? sink.perform(.otherUp(p)) }
        // Forget stored positions.
        lastDragPoint = nil; lastCamPoint = nil
    }
}

// These types talk to the real OS.
// MARK: - Real implementations

// Real WindowEnvironment: answers come from macOS.
public struct SystemWindowEnvironment: WindowEnvironment {
    // Nothing to configure.
    public init() {}
    // Look the window up in the current window list.
    public func frame(ofWindow id: UInt32) -> CGRect? {
        WindowLister.windows(onScreenOnly: true).first { $0.id == id }?.frame
    }
    // Ask Accessibility for the focused application; AX* functions are the Accessibility API.
    /// Live answer from Accessibility (system-wide focused application). NSWorkspace.frontmostApplication is cached
    /// and only refreshes while the main run loop spins, which a command-line host does not do: it kept reporting the
    /// old app after a successful switch (observed 2026-11-18). Falls back to NSWorkspace if AX cannot answer.
    public func frontmostPID() -> Int32? {
        // Holds the answer.
        var v: CFTypeRef?
        // System-wide element = the whole desktop; its 'focused application' attribute names the front app.
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &v) == .success,
           let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() {
            // Convert that element to a process id.
            var pid: pid_t = 0
            if AXUIElementGetPid(el as! AXUIElement, &pid) == .success { return pid }
        }
        // Fallback when Accessibility cannot answer.
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    // Instance version: uses the live window list.
    public func topWindow(at point: CGPoint) -> (id: UInt32, pid: Int32)? {
        // Delegates to the pure static function below.
        Self.topWindow(at: point, in: WindowLister.windows(onScreenOnly: true))
    }
    // Static so tests can pass a made-up window list.
    /// CGWindowList is front-to-back. The first visible window of ANY layer (banners, panels, popups, system
    /// dialogs sit above layer 0) that contains the point is the top one. Fully transparent windows and the
    /// cursor-level window are ignored.
    public static func topWindow(at point: CGPoint, in windows: [WindowInfo]) -> (id: UInt32, pid: Int32)? {
        // Windows at or above the cursor's layer (the pointer itself) are ignored.
        let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
        // Walk front to back; skip nearly invisible windows.
        for w in windows where w.alpha > 0.01 && w.layer < cursorLevel && w.frame.contains(point) {
            // Ignore the big invisible Dock overlay.
            // macOS keeps one transparent, display-sized Dock window at layer 20 (hot corners / Dock hit area).
            // It is not content and never hides anything; the real Dock bar is a small window and still counts.
            if w.ownerName == "Dock", w.layer == 20, w.frame.width >= 1000, w.frame.height >= 700 { continue }
            // First qualifying window = the top one.
            return (w.id, w.ownerPID)
        }
        return nil
    }
    // Works out which window (as a CG window id) has keyboard focus.
    public func focusedWindow() -> FocusedWindow {
        // Needs Accessibility permission and a front app; otherwise report unavailable.
        guard AXIsProcessTrusted(), let fpid = frontmostPID() else { return .unavailable }
        // An Accessibility handle for the front app.
        let el = AXUIElementCreateApplication(fpid)
        // Ask it for its focused window.
        var ref: CFTypeRef?
        // r is the result code.
        let r = AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &ref)
        // The app has no focused window.
        if r == .noValue { return .none }
        // Any other failure means we cannot tell.
        guard r == .success, let w = ref, CFGetTypeID(w) == AXUIElementGetTypeID() else { return .unavailable }
        // Treat the answer as an Accessibility window element.
        let win = w as! AXUIElement
        // Small helper to read one attribute (position, size, title) of that window.
        func axValue(_ attr: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(win, attr as CFString, &v) == .success ? v : nil
        }
        // Read the window's position and size as Accessibility values.
        var pos = CGPoint.zero, size = CGSize.zero
        // If either cannot be read, report unavailable.
        guard let pv = axValue(kAXPositionAttribute), let sv = axValue(kAXSizeAttribute),
              AXValueGetValue(pv as! AXValue, .cgPoint, &pos), AXValueGetValue(sv as! AXValue, .cgSize, &size)
        else { return .unavailable }
        // The window's title, or empty if none.
        let title = axValue(kAXTitleAttribute) as? String ?? ""
        // Match that frame and title against the CG window list to get a window id.
        return Self.matchFocused(axFrame: CGRect(origin: pos, size: size), axTitle: title, pid: fpid,
                                 windows: WindowLister.windows(onScreenOnly: true))
    }
    // Same-process, normal-layer windows with nearly the same frame (within 2 points) and compatible title.
    /// Maps an AX window (frame + title, same global top-left coordinates as CGWindowList) to a CG window id of
    /// the same process. A non-empty title must agree. Two same-size stacked windows with the same title remain
    /// indistinguishable (documented residual).
    static func matchFocused(axFrame: CGRect, axTitle: String, pid: Int32, windows: [WindowInfo]) -> FocusedWindow {
        // Compare two rectangles allowing 2 points of difference.
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }
        // Candidate windows.
        let m = windows.filter { $0.ownerPID == pid && $0.layer == 0 && close($0.frame, axFrame)
            && ($0.title.isEmpty || axTitle.isEmpty || $0.title == axTitle) }
        // No match means a window we cannot identify.
        guard let first = m.first else { return .other }
        // Use the first match.
        return .window(first.id)
    }
    // A CGEvent created with no source reports the current pointer position.
    public func cursorLocation() -> CGPoint? { CGEvent(source: nil)?.location }
    // Brings an app to the front by running a small AppleScript through osascript.
    public func activateApp(pid: Int32) {
        // Set up the helper process: /usr/bin/osascript with two script lines (set frontmost, then raise its first window).
        // Activate by PID, not by bundle path: two RuneLite processes can share one bundle (the Jagex-launched game and a
        // translocated copy), and `open -a <path>` then raises the wrong one (observed 2026-11-18). The only value placed
        // in the script is our own Int32 pid, never anything from the network.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The script lines contain only the integer pid.
        p.arguments = ["-e", "tell application \"System Events\" to tell (first process whose unix id is \(pid)) to set frontmost to true",
                       "-e", "tell application \"System Events\" to tell (first process whose unix id is \(pid)) to try\nperform action \"AXRaise\" of window 1\nend try"]
        // Discard the helper's output.
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        // Start it and do not wait; errors are ignored.
        try? p.run()
    }
}

// Turns planned actions into real CGEvents. A CGEvent is a synthetic mouse/keyboard event the system treats like the real thing.
/// Posts real CGEvents. Needs Accessibility; checks with AXIsProcessTrusted() (no prompt).
public final class CGEventSink: ActionSink, @unchecked Sendable {
    // Event source that mimics the hardware state.
    private let source = CGEventSource(stateID: .hidSystemState)
    public init() {}

    // Whether the Accessibility permission is granted (checks only).
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // Executes one action.
    public func perform(_ a: PlannedAction) throws {
        // Without Accessibility permission, posting events would silently do nothing, so refuse clearly.
        guard AXIsProcessTrusted() else { throw InjectError.accessibilityDenied }
        // One branch per action kind.
        switch a {
        // Mouse events: type, position, button. Short pauses before presses help the app notice the hover.
        case .move(let p): mouse(.mouseMoved, p, .left)
        case .leftDown(let p): Thread.sleep(forTimeInterval: 0.02); mouse(.leftMouseDown, p, .left, click: 1)  // let Java/AWT see the hover before the press (audit 2026-11-18)
        case .leftUp(let p): Thread.sleep(forTimeInterval: 0.03); mouse(.leftMouseUp, p, .left, click: 1)
        case .leftDrag(let p): mouse(.leftMouseDragged, p, .left)
        case .otherDown(let p): Thread.sleep(forTimeInterval: 0.02); mouse(.otherMouseDown, p, .center, click: 1)
        case .otherUp(let p): mouse(.otherMouseUp, p, .center, click: 1)
        case .otherDrag(let p): mouse(.otherMouseDragged, p, .center)
        case .rightDown(let p): mouse(.rightMouseDown, p, .right, click: 1)
        case .rightUp(let p): mouse(.rightMouseUp, p, .right, click: 1)
        // Scroll wheel event measured in pixels; the signs are flipped to match the wheel direction convention.
        case .scroll(let dx, let dy):
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0)?
                .post(tap: .cghidEventTap)
        // Typing: each character is sent as a key-down then key-up.
        case .keyText(let text, let mods):
            // Modifier flags from the phone (shift/ctrl/alt/cmd).
            // Java AWT (RuneLite) derives the key from the virtual keycode, so every character goes out with its real
            // US-ANSI keycode (shift flag for the shifted glyph) plus the unicode string; only characters that are not on
            // a US keyboard fall back to keycode 0 + unicode string. Control keys carry no string. Down, short pause, up.
            let baseFlags = Self.flags(mods)
            // Go through the text one character at a time.
            for ch in text {
                // Look up key code, shift need and whether to attach the Unicode text.
                let (vk, shift, sendString) = Self.keyInfo(ch)
                // Add shift if the character needs it.
                var flags = baseFlags
                if shift { flags.insert(.maskShift) }
                // The character as UTF-16 numbers (what the event API wants).
                let units = sendString ? Array(String(ch).utf16) : []
                // First key-down, then key-up.
                for down in [true, false] {
                    // Build the event; skip if it could not be built.
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { continue }
                    // Attach the text so apps can read the exact character.
                    if !units.isEmpty { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
                    // Set the modifier flags.
                    e.flags = flags
                    // Send it into the system's event stream at the hardware level.
                    e.post(tap: .cghidEventTap)
                    // Short pause between key events.
                    Thread.sleep(forTimeInterval: down ? 0.010 : 0.010)
                }
            }
        }
    }

    // Table: character to (virtual key code, needs shift).
    /// US-ANSI virtual keycodes (kVK_ANSI_*). Returns (keycode, needsShift, sendUnicodeString).
    static let ansi: [Character: (UInt16, Bool)] = [
        "a":(0,false),"s":(1,false),"d":(2,false),"f":(3,false),"h":(4,false),"g":(5,false),"z":(6,false),"x":(7,false),
        "c":(8,false),"v":(9,false),"b":(11,false),"q":(12,false),"w":(13,false),"e":(14,false),"r":(15,false),"y":(16,false),
        "t":(17,false),"1":(18,false),"2":(19,false),"3":(20,false),"4":(21,false),"6":(22,false),"5":(23,false),"=":(24,false),
        "9":(25,false),"7":(26,false),"-":(27,false),"8":(28,false),"0":(29,false),"]":(30,false),"o":(31,false),"u":(32,false),
        "[":(33,false),"i":(34,false),"p":(35,false),"l":(37,false),"j":(38,false),"'":(39,false),"k":(40,false),";":(41,false),
        "\\":(42,false),",":(43,false),"/":(44,false),"n":(45,false),"m":(46,false),".":(47,false),"`":(50,false),
        "!":(18,true),"@":(19,true),"#":(20,true),"$":(21,true),"%":(23,true),"^":(22,true),"&":(26,true),"*":(28,true),
        "(":(25,true),")":(29,true),"_":(27,true),"+":(24,true),"{":(33,true),"}":(30,true),"|":(42,true),":":(41,true),
        "\"":(39,true),"<":(43,true),">":(47,true),"?":(44,true),"~":(50,true),
    ]
    // Returns (key code, needs shift, attach Unicode text) for one character.
    static func keyInfo(_ c: Character) -> (UInt16, Bool, Bool) {
        // Special keys first (Return, Tab, Backspace, space).
        switch c {
        case "\n", "\r": return (36, false, false)      // Return
        case "\t": return (48, false, false)            // Tab
        case "\u{8}": return (51, false, false)         // Backspace
        case " ": return (49, false, true)
        default: break
        }
        // Normal US-keyboard characters.
        if let e = ansi[c] { return (e.0, e.1, true) }
        // Uppercase letters: use the lowercase key with shift.
        if c.isUppercase, let l = c.lowercased().first, let e = ansi[l] { return (e.0, true, true) }
        // Anything else: key code 0 with the Unicode text.
        return (0, false, true)                           // not on a US keyboard: unicode string only
    }

    // Converts the 4 modifier bits into CGEventFlags.
    /// Modifier bit assignment (protocol leaves mods undefined; documented here): 1 shift, 2 ctrl, 4 alt, 8 cmd.
    public static func flags(_ mods: UInt8) -> CGEventFlags {
        // Start with no modifiers.
        var f: CGEventFlags = []
        // Add each flag whose bit is set.
        if mods & 1 != 0 { f.insert(.maskShift) }
        if mods & 2 != 0 { f.insert(.maskControl) }
        if mods & 4 != 0 { f.insert(.maskAlternate) }
        if mods & 8 != 0 { f.insert(.maskCommand) }
        return f
    }

    // Creates and posts one mouse event. `click` sets the click count (1 for a press or release, 0 for moves and drags).
    private func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton, click: Int64 = 0) {
        // Create the event; skip if the system refuses.
        guard let e = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: b) else { return }
        // Mark it as a single click.
        if click > 0 { e.setIntegerValueField(.mouseEventClickState, value: click) }
        // Send it.
        e.post(tap: .cghidEventTap)
    }
}
