// Program: Lantern - VersionTests.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Smoke test for the LanternCore version string.
//
// Area protected: the LanternCore version string. This is a tiny smoke test that the
// version constant exists, so about screens and handshakes never show a blank version.
import XCTest
@testable import LanternCore
// Scenario: read the version string. Expected: it is not empty.
// Why it matters: an empty version would mean the build metadata is broken.
final class VersionTests: XCTestCase { func testVersion() { XCTAssertFalse(LanternVersion.string.isEmpty) } }
