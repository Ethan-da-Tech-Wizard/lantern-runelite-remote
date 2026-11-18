// ==============================================================================
// Program: HostInfoTests.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Smoke test for host package information and metadata.
//          Inputs: HostInfo module queries.
//          Outputs: Assertions verifying correct host version strings.
//          Design Rationale: Verifies consistency in host metadata reporting.
// ==============================================================================
// Area protected: the LanternHostKit version string (HostInfo). A tiny smoke test that
// the host side reports a non-empty version.
import XCTest
@testable import LanternHostKit
// Scenario: read HostInfo.version. Expected: it is not empty.
// Why it matters: an empty version would mean the build metadata is broken.
final class HostInfoTests: XCTestCase { func testVersion() { XCTAssertFalse(HostInfo.version.isEmpty) } }
