// Program: Lantern - CaptureGuardTests.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Tests the capture safety checks.
//
// Area protected: CaptureGuard, the safety checks that run before a screen capture
// starts. It must pick exactly one window, require explicit confirmation, limit the
// recording length, shorten titles, and never overwrite or follow links into
// existing files. Each rule exists so a capture cannot hit the wrong window or file.
import XCTest
import CoreGraphics
@testable import LanternHostKit

// Tests for the CaptureGuard rules.
final class CaptureGuardTests: XCTestCase {
    // Helper: builds a fake window description with a given id, owner and title.
    func win(_ id: UInt32, _ owner: String, _ title: String) -> WindowInfo {
        WindowInfo(id: id, ownerName: owner, ownerPID: 1, title: title, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    // Scenario: look up windows by name text among three windows.
    // Expected: a name matching one window returns it, no match returns noMatch, and a
    // name matching two windows returns multipleMatches (it does not guess).
    // Why it matters: capturing the wrong window would leak the wrong content.
    func testResolve() {
        // Arrange: three windows; two belong to the same app.
        let ws = [win(1, "RuneLite", "RuneLite - a"), win(2, "Safari", "Home"), win(3, "RuneLite", "Other")]
        // Assert: "safari" (any letter case) finds exactly the second window.
        XCTAssertEqual(CaptureGuard.resolve("safari", in: ws), .success(ws[1]))
        // Assert: an unknown name fails with noMatch carrying that name.
        XCTAssertEqual(CaptureGuard.resolve("nothing", in: ws), .failure(.noMatch("nothing")))
        // Assert: a name that matches two windows fails with multipleMatches(2).
        XCTAssertEqual(CaptureGuard.resolve("runelite", in: ws), .failure(.multipleMatches(2)))
    }
    // Scenario: ask for confirmation using the window id.
    // Expected: no confirmation gives confirmRequired, a wrong id gives confirmMismatch,
    // and the right id returns nil (nil means no problem).
    // Why it matters: the user must say yes about the exact window being captured.
    func testConfirm() {
        // Arrange: a window with id 42.
        let w = win(42, "A", "t")
        // Assert: no confirm value means confirmation is required.
        XCTAssertEqual(CaptureGuard.requireConfirm(window: w, confirm: nil), .confirmRequired(42))
        // Assert: a different id is a mismatch, showing what was given and what was expected.
        XCTAssertEqual(CaptureGuard.requireConfirm(window: w, confirm: "41"), .confirmMismatch(given: "41", expected: 42))
        // Assert: the matching id passes with no error.
        XCTAssertNil(CaptureGuard.requireConfirm(window: w, confirm: "42"))
    }
    // Scenario: check capture durations for the short and long modes.
    // Expected: 30 s is fine in short mode, 30.5 is rejected in short mode, 300 s is fine in
    // long mode, and zero or not-a-number is invalid.
    // Why it matters: bounds stop runaway or nonsensical recordings.
    func testSeconds() {
        // Short mode: 30 seconds is accepted.
        XCTAssertNil(CaptureGuard.checkSeconds(30, long: false))
        // Short mode: 30.5 seconds is rejected (some error returned).
        XCTAssertNotNil(CaptureGuard.checkSeconds(30.5, long: false))
        // Long mode: 300 seconds is accepted.
        XCTAssertNil(CaptureGuard.checkSeconds(300, long: true))
        // Zero seconds is invalid.
        XCTAssertEqual(CaptureGuard.checkSeconds(0, long: true), .secondsInvalid)
        // Not-a-number is invalid.
        XCTAssertEqual(CaptureGuard.checkSeconds(.nan, long: true), .secondsInvalid)
    }
    // Scenario: shorten window titles for display.
    // Expected: a 100-character title is cut to 60, and an empty title shows a placeholder.
    // Why it matters: titles come from other apps and could be huge or blank.
    func testTitleTruncation() {
        // A 100-character title becomes 60 characters.
        XCTAssertEqual(CaptureGuard.truncatedTitle(String(repeating: "x", count: 100)).count, 60)
        // An empty title becomes the "(no title)" placeholder.
        XCTAssertEqual(CaptureGuard.truncatedTitle(""), "(no title)")
    }
    // Scenario: create an output file in a temporary folder, then try to reuse the path.
    // Expected: a fresh path passes, the file is created with owner-only permissions (0600),
    // an existing path is refused, a second exclusive create does not overwrite, and a dangling
    // symbolic link counts as existing.
    // Why it matters: captures must never clobber files or be redirected through links.
    func testPathGuardAndPerms() throws {
        // Arrange: a unique temporary folder, removed again when the test ends.
        let dir = NSTemporaryDirectory() + "cg-\(UUID().uuidString)"
        // Create that folder.
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Cleanup: delete the folder whatever happens.
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // The file path we will write the capture to.
        let p = dir + "/o.h264"
        // Assert: a path that does not exist yet passes the check.
        XCTAssertNil(CaptureGuard.checkPath(p))
        // Act: create the file exclusively; fail the test if that does not succeed.
        guard case .success(let fh) = CaptureGuard.createExclusive(p) else { return XCTFail("create") }
        // Close the handle so the file can be inspected.
        try fh.close()
        // Read the file's permission bits.
        let perms = try FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int
        // Assert: only the owner can read and write (0600).
        XCTAssertEqual(perms, 0o600)
        // Assert: the same path is now reported as already existing.
        XCTAssertEqual(CaptureGuard.checkPath(p), .pathExists(p))
        // Assert: creating it again must not succeed, so the old file is never overwritten.
        if case .success = CaptureGuard.createExclusive(p) { XCTFail("overwrote") }
        // Arrange: a symbolic link that points at a file that does not exist.
        let link = dir + "/link"
        // Create the dangling link.
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir + "/missing")
        // Assert: the link path is refused as existing, so it cannot redirect a write.
        XCTAssertEqual(CaptureGuard.checkPath(link), .pathExists(link))
    }
}
