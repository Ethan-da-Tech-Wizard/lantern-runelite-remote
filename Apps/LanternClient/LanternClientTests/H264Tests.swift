// Area protected: the H.264 helpers in the client app. It checks splitting a byte stream
// into units (NALs), building a video format from SPS/PPS, refusing bad input, and that the
// display sink survives garbage without crashing and asks for a new keyframe.
// Network video is untrusted, so these helpers must never crash on bad data.
import XCTest
import CoreMedia
@testable import LanternClient

// Tests for H264 parsing and the display layer sink.
final class H264Tests: XCTestCase {
    // Baseline-profile SPS/PPS (small sample stream).
    let sps = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x06, 0xD0, 0xA1, 0x35])
    let pps = Data([0x68, 0xCE, 0x06, 0xE2])

    // Scenario: a stream mixing 4-byte and 3-byte start codes.
    // Expected: three units are found with the start codes removed.
    // Why it matters: both start code styles occur in real streams.
    func testSplitsThreeAndFourByteStartCodes() {
        // Arrange: start code + SPS, short start code + PPS, start code + a picture unit.
        let d = Data([0,0,0,1]) + sps + Data([0,0,1]) + pps + Data([0,0,0,1, 0x65, 1, 2, 3])
        // Act: split into units.
        let n = H264.nalUnits(d)
        // Assert: exactly SPS, PPS and the picture unit.
        XCTAssertEqual(n, [sps, pps, Data([0x65, 1, 2, 3])])
    }
    // Scenario: empty data, data with no start code, and too-short data.
    // Expected: no units in each case.
    // Why it matters: the parser must not invent units from noise.
    func testEmptyAndNoStartCode() {
        // Empty data gives nothing.
        XCTAssertTrue(H264.nalUnits(Data()).isEmpty)
        // No start code gives nothing.
        XCTAssertTrue(H264.nalUnits(Data([1, 2, 3, 4, 5])).isEmpty)
        // Two bytes only gives nothing.
        XCTAssertTrue(H264.nalUnits(Data([0, 0])).isEmpty)
    }
    // Scenario: truncated or random bytes.
    // Expected: no crash; a start code alone or only start codes give nothing; a 1-byte unit counts.
    // Why it matters: broken packets are common and must not crash the app.
    func testTruncatedAndMalformedDoNotCrash() {
        // Start code with no body gives nothing.
        XCTAssertTrue(H264.nalUnits(Data([0, 0, 1])).isEmpty)                 // start code, no body
        // Back-to-back start codes give nothing.
        XCTAssertTrue(H264.nalUnits(Data([0, 0, 0, 1, 0, 0, 0, 1])).isEmpty)  // only start codes
        // A one-byte unit is still one unit.
        XCTAssertEqual(H264.nalUnits(Data([0, 0, 1, 0x65])).count, 1)         // 1-byte NAL
        // Fuzz: 500 random byte strings built from start-code-like pieces.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let len = Int.random(in: 0..<64, using: &rng)
            let bytes = (0..<len).map { _ in [UInt8(0), 0, 1, UInt8.random(in: 0...255)].randomElement()! }
            // Only checking that the call returns without crashing.
            _ = H264.nalUnits(Data(bytes))
        }
    }
    // Scenario: build a video format from valid SPS and PPS.
    // Expected: a format with a positive width and height.
    // Why it matters: without a format the decoder cannot show video.
    func testFormatDescriptionFromSPSPPS() throws {
        // Act: build the format.
        let fd = try XCTUnwrap(H264.formatDescription(sps: sps, pps: pps))
        // Read its dimensions.
        let d = CMVideoFormatDescriptionGetDimensions(fd)
        // Assert: both are positive.
        XCTAssertGreaterThan(d.width, 0); XCTAssertGreaterThan(d.height, 0)
    }
    // Scenario: empty, partial or corrupt SPS/PPS.
    // Expected: no format (nil) each time.
    // Why it matters: bad parameters must be refused instead of producing a broken decoder.
    func testFormatDescriptionRejectsGarbageAndEmpty() {
        // Both empty.
        XCTAssertNil(H264.formatDescription(sps: Data(), pps: Data()))
        // Missing PPS.
        XCTAssertNil(H264.formatDescription(sps: sps, pps: Data()))
        // Too-short SPS and PPS.
        XCTAssertNil(H264.formatDescription(sps: Data([0x67]), pps: Data([0x68])))
        // Corrupt SPS.
        XCTAssertNil(H264.formatDescription(sps: Data([0xFF, 0xFF, 0xFF]), pps: pps))
    }
    // Scenario: build a sample from an empty list of units.
    // Expected: nil.
    // Why it matters: there is nothing to decode, and the code must say so.
    func testSampleBufferEmptyNALsIsNil() throws {
        // Arrange: a valid format.
        let fd = try XCTUnwrap(H264.formatDescription(sps: sps, pps: pps))
        // Assert: no sample is produced.
        XCTAssertNil(H264.sampleBuffer(nals: [], format: fd, ptsUs: 0))
    }
    @MainActor
    // Scenario: feed the display sink bad frames.
    // Expected: no crash, and it asks for a keyframe so it can recover.
    // Why it matters: a stream that starts mid-way must recover cleanly.
    func testSinkSurvivesGarbageAndAsksForKeyframe() {
        // Arrange: a sink.
        let sink = DisplayLayerSink()
        // Expectation: a keyframe request will happen.
        let asked = expectation(description: "keyframe requested")
        // It may be requested more than once, which is fine.
        asked.assertForOverFulfill = false
        // Hook: fulfil the expectation when the sink asks for a keyframe.
        sink.onNeedKeyframe = { asked.fulfill() }
        // Act: a P frame with no parameter sets.
        sink.enqueue(annexB: Data([0, 0, 0, 1, 0x41, 9, 9]), isKey: false, ptsUs: 1)   // P frame, no SPS/PPS
        // Act: a truncated SPS marked as key.
        sink.enqueue(annexB: Data([0, 0, 0, 1, 0x67]), isKey: true, ptsUs: 2)          // truncated SPS
        // Act: empty data marked as key.
        sink.enqueue(annexB: Data(), isKey: true, ptsUs: 3)
        // Assert: wait up to 3 seconds for the keyframe request.
        wait(for: [asked], timeout: 3)
        // Cleanup: reset the sink.
        sink.reset()
    }
}
