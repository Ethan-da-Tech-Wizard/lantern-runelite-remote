// Area protected: VirtualDisplaySpec, the description of a virtual phone-shaped display.
// It covers default size, HiDPI modes, size limits, same-ratio scaling and physical size.
import XCTest
@testable import LanternHostKit

// Pure math only. These tests never create a display.
/// Pure math only. These tests never create a display.
final class VirtualDisplayTests: XCTestCase {
    // Scenario: read the default phone spec.
    // Expected: 2532 x 1170, aspect ratio about 2.164, 60 Hz refresh.
    // Why it matters: other code relies on these defaults matching the phone screen.
    func testPhoneDefault() {
        // Arrange: take the default spec.
        let s = VirtualDisplaySpec.phoneDefault
        // Assert: width and height.
        XCTAssertEqual(s.width, 2532); XCTAssertEqual(s.height, 1170)
        // Assert: aspect ratio within a small tolerance.
        XCTAssertEqual(s.aspectRatio, 2.16410, accuracy: 0.001)
        // Assert: refresh rate.
        XCTAssertEqual(s.refresh, 60)
    }
    // Scenario: a HiDPI spec lists two modes.
    // Expected: logical size is half the pixel size (1266 x 585) and the second mode is that logical size.
    // Why it matters: HiDPI means pixels are doubled, so the display must offer both sizes.
    func testHiDPIPair() {
        // Arrange: the default spec.
        let s = VirtualDisplaySpec.phoneDefault
        // Assert: logical width and height are half the pixel size.
        XCTAssertEqual(s.logicalWidth, 1266); XCTAssertEqual(s.logicalHeight, 585)
        // Assert: there are exactly two modes.
        XCTAssertEqual(s.modes.count, 2)
        // Assert: the second mode is the logical size.
        XCTAssertEqual(s.modes[1].width, 1266); XCTAssertEqual(s.modes[1].height, 585)
    }
    // Scenario: build a spec with HiDPI off.
    // Expected: only one mode, and logical size equals pixel size.
    // Why it matters: without HiDPI there is nothing to halve.
    func testNonHiDPIHasSingleMode() throws {
        // Arrange: create the spec with hiDPI false.
        let s = try VirtualDisplaySpec(width: 2532, height: 1170, hiDPI: false)
        // Assert: one mode only.
        XCTAssertEqual(s.modes.count, 1)
        // Assert: logical width equals the pixel width.
        XCTAssertEqual(s.logicalWidth, 2532)
    }
    // Scenario: feed invalid sizes and refresh rates.
    // Expected: too small, too wide, refresh 0, refresh 240 and an odd width with HiDPI all throw;
    // an odd width without HiDPI is allowed.
    // Why it matters: bad values must be rejected before a display is requested.
    func testBounds() {
        // Too small: rejected.
        XCTAssertThrowsError(try VirtualDisplaySpec(width: 100, height: 100))
        // Too wide: rejected.
        XCTAssertThrowsError(try VirtualDisplaySpec(width: 9000, height: 1000))
        // Refresh of zero: rejected.
        XCTAssertThrowsError(try VirtualDisplaySpec(width: 2532, height: 1170, refresh: 0))
        // Refresh too high: rejected.
        XCTAssertThrowsError(try VirtualDisplaySpec(width: 2532, height: 1170, refresh: 240))
        // Odd width with HiDPI cannot be halved evenly: rejected.
        XCTAssertThrowsError(try VirtualDisplaySpec(width: 2533, height: 1170, hiDPI: true))
        // Odd width without HiDPI: accepted.
        XCTAssertNoThrow(try VirtualDisplaySpec(width: 2533, height: 1170, hiDPI: false))
    }
    // Scenario: scale the default spec to a new width.
    // Expected: height follows (1404) and the aspect ratio stays the same.
    // Why it matters: scaling must not stretch the picture.
    func testScaledSameRatio() throws {
        // Act: scale to width 3036.
        let big = try VirtualDisplaySpec.phoneDefault.scaledSameRatio(width: 3036)
        // Assert: the height matches the same ratio.
        XCTAssertEqual(big.height, 1404)
        // Assert: the result reports the same aspect as the default.
        XCTAssertTrue(big.sameAspect(as: .phoneDefault))
    }
    // Scenario: ask for the physical size in millimeters.
    // Expected: width divided by height equals the pixel ratio.
    // Why it matters: wrong physical size would make the system scale things oddly.
    func testMillimeters() {
        // Act: get the size in millimeters.
        let mm = VirtualDisplaySpec.phoneDefault.sizeInMillimeters
        // Assert: the millimeter ratio matches 2532 / 1170.
        XCTAssertEqual(mm.width / mm.height, 2532.0 / 1170.0, accuracy: 0.0001)
    }
}
