// ==============================================================================
// Program: OSRSZonesTests.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Unit tests for OSRS window touch zone classification.
//          Inputs: Coordinate test points across fixed classic layout boundaries.
//          Outputs: Zone classification assertions verifying world vs UI region detection.
//          Design Rationale: Confirms accurate separation between camera rotation zones and interface interaction zones.
// ==============================================================================
// Area protected: OSRSZones, the helper that decides whether a point on the
// streamed picture lies over the game world (where a tap means "walk/click in
// the world") or over an interface area such as inventory, chat, minimap or a
// side panel. Getting this wrong would send taps to the wrong kind of target.
import XCTest
@testable import LanternCore

// Tests for the fixed-layout world-versus-interface zone classifier.
final class OSRSZonesTests: XCTestCase {
    // Setup note (existing): the window is 1038 x 531 points, captured at 2x scale.
    // 1038 x 531 pt window (765x503 canvas + 28 pt title bar + sidebar/panel) captured at 2x.
    // The captured video size in pixels (twice the point size, matching the 2x capture).
    let px = (w: 2076.0, h: 1062.0)
    // Helper: turns a canvas point (x, y) into a fraction of the whole picture,
    // so tests can say where they tap in canvas terms. The 28 shifts y down past the title bar.
    func f(_ x: Double, _ y: Double) -> (Float, Float) { (Float(x / 1038), Float((y + 28) / 531)) }   // canvas pt -> picture fraction
    // Scenario: probe one spot in the world and several spots in interface areas.
    // Expected: only the middle of the viewport counts as world; inventory, chatbox,
    // plugin panel and minimap do not.
    // Why it matters: world taps and interface taps are handled differently, so
    // the zone boundaries must be right.
    func testWorldVsInterface() {
        // Arrange/act/assert: convert a point in the middle of the viewport, then ask if it is world.
        // Expect true.
        var p = f(260, 170); XCTAssertTrue(OSRSZones.isWorld(nx: p.0, ny: p.1, videoPixels: px))     // middle of the viewport
        // Same steps for the inventory column; expect false (not world).
        p = f(650, 300);     XCTAssertFalse(OSRSZones.isWorld(nx: p.0, ny: p.1, videoPixels: px))    // inventory column
        // Chatbox area; expect false.
        p = f(260, 420);     XCTAssertFalse(OSRSZones.isWorld(nx: p.0, ny: p.1, videoPixels: px))    // chatbox
        // Plugin panel area; expect false.
        p = f(900, 100);     XCTAssertFalse(OSRSZones.isWorld(nx: p.0, ny: p.1, videoPixels: px))    // plugin panel
        // Minimap area; expect false.
        p = f(600, 60);      XCTAssertFalse(OSRSZones.isWorld(nx: p.0, ny: p.1, videoPixels: px))    // minimap
    }
    // Scenario: the video has a size that does not match the fixed game layout (2400 x 1800).
    // Expected: no point is treated as world.
    // Why it matters: when the layout is not the known fixed one, the code must not guess
    // and wrongly call something world.
    func testNonFixedLayoutHasNoWorldZone() {
        // Act and assert: a point that would be mid-picture still reports false for this size.
        XCTAssertFalse(OSRSZones.isWorld(nx: 0.3, ny: 0.3, videoPixels: (w: 2400, h: 1800)))
    }
}
