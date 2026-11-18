// Area protected: the LanternHostKit version string (HostInfo). A tiny smoke test that
// the host side reports a non-empty version.
import XCTest
@testable import LanternHostKit
// Scenario: read HostInfo.version. Expected: it is not empty.
// Why it matters: an empty version would mean the build metadata is broken.
final class HostInfoTests: XCTestCase { func testVersion() { XCTAssertFalse(HostInfo.version.isEmpty) } }
