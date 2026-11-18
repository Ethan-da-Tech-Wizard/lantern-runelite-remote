// Program: Lantern - CaptureGuard.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Safety checks before a screen capture: which window, how long and where the output goes.
//
// CaptureGuard.swift - pure safety checks for the capture-test command (which window, how long, where to write).
// Who calls it: lantern-host's captureTest; also unit tests.
// Key ideas: recording the screen is sensitive, so the tool demands one exact window, a typed confirmation
// of its id, a time cap, and a brand-new private output file. None of this needs Screen Recording permission.

// Foundation: basic types and FileHandle.
import Foundation
// Darwin: the low-level C functions (open, lstat, fchmod) used for safe file creation.
import Darwin

// Namespace of static safety checks run BEFORE any recording starts.
/// Pure guard logic for commands that record a window. No Screen Recording permission needed.
public enum CaptureGuard {
    // Default recording length cap in seconds.
    public static let defaultMaxSeconds: Double = 30

    // Every reason a recording request can be refused; each prints a clear message.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        // No window matches the search text.
        case noMatch(String)
        // More than one window matches; the user must be more specific.
        case multipleMatches(Int)
        // The user did not pass --confirm-window yet.
        case confirmRequired(UInt32)
        // The confirmation id does not equal the resolved window id.
        case confirmMismatch(given: String, expected: UInt32)
        // --seconds was zero, negative, or not a finite number.
        case secondsInvalid
        // Over the cap and --long was not given.
        case secondsTooLong(requested: Double, cap: Double)
        // The output file is already there (we never overwrite).
        case pathExists(String)
        // The file could not be created (permissions, missing folder, etc.).
        case cannotCreate(String)
        // Messages shown to the person at the terminal.
        public var description: String {
            switch self {
            case .noMatch(let s): return "no on-screen window matches '\(s)'"
            case .multipleMatches(let n): return "\(n) windows match; refine the substring (candidates above)"
            case .confirmRequired(let id): return "refusing to record without confirmation; rerun with --confirm-window \(id)"
            case .confirmMismatch(let g, let e): return "--confirm-window '\(g)' does not match resolved window id \(e); refusing"
            case .secondsInvalid: return "--seconds must be a positive number"
            case .secondsTooLong(let r, let c): return "--seconds \(r) exceeds the cap of \(Int(c)); pass --long to allow longer"
            case .pathExists(let p): return "output path already exists (no overwrite): \(p)"
            case .cannotCreate(let p): return "cannot create output file: \(p)"
            }
        }
    }

    /// Windows matching the substring (uses WindowInfo.matches).
    public static func candidates(_ needle: String, in windows: [WindowInfo]) -> [WindowInfo] {
        // Keep only windows whose title or owner contains the text.
        windows.filter { $0.matches(needle) }
    }

    // Result is either .success(one window) or .failure(reason).
    /// Exactly one candidate or a failure.
    public static func resolve(_ needle: String, in windows: [WindowInfo]) -> Result<WindowInfo, Failure> {
        // Find all matches first.
        let m = candidates(needle, in: windows)
        // Zero matches is a failure.
        if m.isEmpty { return .failure(.noMatch(needle)) }
        // Several matches is also a failure: we never guess.
        if m.count > 1 { return .failure(.multipleMatches(m.count)) }
        // Exactly one match.
        return .success(m[0])
    }

    /// Makes a title safe to print on one line: placeholder for empty, newlines/tabs turned into spaces, cut to `limit` characters.
    public static func truncatedTitle(_ t: String, limit: Int = 60) -> String {
        // Show a label instead of nothing.
        if t.isEmpty { return "(no title)" }
        // Replace line breaks and tabs so the output stays on a single line.
        let flat = t.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        // Short titles pass through; long ones are cut to the first `limit` characters.
        return flat.count <= limit ? flat : String(flat.prefix(limit))
    }

    // Builds the one-line text with id, owner app, title and size.
    /// One line describing a window: id, owner, truncated title, size.
    public static func describe(_ w: WindowInfo) -> String {
        // Sizes are shown as whole numbers.
        "id=\(w.id) owner=\(w.ownerName) title=\(truncatedTitle(w.title)) size=\(Int(w.frame.width))x\(Int(w.frame.height))"
    }

    // Returns nil when OK, or the Failure to report.
    /// Recording needs the exact resolved id via --confirm-window.
    public static func requireConfirm(window: WindowInfo, confirm: String?) -> Failure? {
        // No confirmation given: tell the user which id to pass.
        guard let c = confirm else { return .confirmRequired(window.id) }
        // A confirmation was given but it is not this window's id: refuse.
        guard c == String(window.id) else { return .confirmMismatch(given: c, expected: window.id) }
        // Confirmed correctly.
        return nil
    }

    // Returns nil if the length is acceptable.
    /// Validates --seconds; capped at 30 unless long.
    public static func checkSeconds(_ s: Double, long: Bool, cap: Double = defaultMaxSeconds) -> Failure? {
        // Reject NaN, infinity, zero and negative numbers.
        guard s.isFinite, s > 0 else { return .secondsInvalid }
        // Over the cap is allowed only with --long.
        if !long && s > cap { return .secondsTooLong(requested: s, cap: cap) }
        // Length accepted.
        return nil
    }

    // lstat looks at the path itself without following symlinks, so even a broken symlink counts as 'exists'.
    /// Path must not exist (symlinks, even dangling, count as existing).
    public static func checkPath(_ path: String) -> Failure? {
        // An empty stat structure for lstat to fill in.
        var st = stat()
        // lstat returns 0 when the path exists, which means we must refuse.
        return lstat(path, &st) == 0 ? .pathExists(path) : nil
    }

    // Opens the file for writing. O_CREAT|O_EXCL = create it, and fail if it already exists (no race with another program);
    // O_NOFOLLOW = refuse to follow a symlink; 0o600 = only the owner can read or write it.
    /// Atomically creates the file (O_EXCL) with mode 0600 and returns an open handle.
    public static func createExclusive(_ path: String) -> Result<FileHandle, Failure> {
        // `fd` is a 'file descriptor', the OS's small-number handle to an open file.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        // Negative means failure; EEXIST specifically means 'already exists'.
        if fd < 0 { return .failure(errno == EEXIST ? .pathExists(path) : .cannotCreate(path)) }
        // Set the permissions again explicitly in case the system's umask changed them.
        fchmod(fd, 0o600)
        // Wrap the descriptor in a FileHandle that closes it automatically when released.
        return .success(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    // Notice printed before recording so the user knows what is happening and where the data stays.
    public static let banner = "RECORDING the contents of the confirmed window. Output stays on this Mac only (local file, mode 0600); nothing is sent anywhere."
}
