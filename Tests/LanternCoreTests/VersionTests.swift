// Area protected: the LanternCore version string. This is a tiny smoke test that the
// version constant exists, so about screens and handshakes never show a blank version.
import XCTest
@testable import LanternCore
// Scenario: read the version string. Expected: it is not empty.
// Why it matters: an empty version would mean the build metadata is broken.
final class VersionTests: XCTestCase { func testVersion() { XCTAssertFalse(LanternVersion.string.isEmpty) } }
