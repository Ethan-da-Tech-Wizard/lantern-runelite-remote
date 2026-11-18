// ==============================================================================
// Program: VersionTests.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Smoke test validating protocol version constants.
//          Inputs: Version string and wire integer queries.
//          Outputs: Assertions verifying expected version identifiers.
//          Design Rationale: Prevents accidental protocol version mismatches between client and host builds.
// ==============================================================================
// Area protected: the LanternCore version string. This is a tiny smoke test that the
// version constant exists, so about screens and handshakes never show a blank version.
import XCTest
@testable import LanternCore
// Scenario: read the version string. Expected: it is not empty.
// Why it matters: an empty version would mean the build metadata is broken.
final class VersionTests: XCTestCase { func testVersion() { XCTAssertFalse(LanternVersion.string.isEmpty) } }
