// Program: Lantern - HostInfoTests.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Smoke test for the host version string.
//
// Area protected: the LanternHostKit version string (HostInfo). A tiny smoke test that
// the host side reports a non-empty version.
import XCTest
@testable import LanternHostKit
// Scenario: read HostInfo.version. Expected: it is not empty.
// Why it matters: an empty version would mean the build metadata is broken.
final class HostInfoTests: XCTestCase { func testVersion() { XCTAssertFalse(HostInfo.version.isEmpty) } }
