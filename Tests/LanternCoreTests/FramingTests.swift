// ==============================================================================
// Program: FramingTests.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Unit tests verifying WireMessage and ChannelMessage serialization and deserialization.
//          Inputs: Sample messages, corrupted packet buffers, and truncated byte streams.
//          Outputs: Validation that valid messages roundtrip intact and invalid packets are rejected.
//          Design Rationale: Ensures protocol wire stability and parser robustness against malformed datagrams.
// ==============================================================================
// Area protected: the wire format and delivery rules in LanternCore. It covers the outer
// frame codec (encode and decode with strict size checks), the inner channel messages (video,
// control, input), coordinate clamping, a random-input crash check, the replay window,
// splitting video into fragments and putting them back together, input rate limiting, and the
// host-side gate that keeps mouse state consistent.
// Bad bytes come from the network, so these tests make sure garbage is rejected, never trusted.
import XCTest
import CryptoKit
@testable import LanternCore

// Tests for framing, fragmentation, replay protection and input gating.
final class FramingTests: XCTestCase {
    // Helper: makes a byte array of length n filled with one value (7 by default), for building payloads of exact sizes.
    private func b(_ n: Int, _ v: UInt8 = 7) -> [UInt8] { [UInt8](repeating: v, count: n) }

    // Scenario: encode each kind of wire message and decode it back; then inspect a data frame header.
    // Expected: every message comes back equal; the header begins with the magic bytes, version, type,
    // session id and counter in the expected order; the extra-data (AAD) is 8 bytes.
    // Why it matters: both ends must agree on the exact bytes on the wire.
    func testWireRoundTrips() throws {
        // Arrange: one sample of every message type with the right field sizes.
        let msgs: [WireMessage] = [
            .pairM1(eAndTag: b(48)), .pairM2(e: b(32), encS: b(48), encPayload: b(20)),
            .pairM3(encS: b(48), encPayload: b(16 + 64)),
            .ikM1(e: b(32), encS: b(48), encTs: b(24)), .ikM2(e: b(32), encPayload: b(16)),
            .data(sessionID: 0xDEADBEEF, counter: 0x0102030405060708, sealed: b(100)), .reject,
        ]
        // Act and assert: encode then decode each one and expect the same message.
        for m in msgs { XCTAssertEqual(try FrameCodec.decode(try FrameCodec.encode(m)), m) }
        // Arrange: a small data frame.
        let d = try FrameCodec.encode(.data(sessionID: 1, counter: 2, sealed: b(16)))
        // Assert: the first 16 bytes match the documented header layout.
        XCTAssertEqual(Array(d.prefix(16)), [0x54, 0x57, 1, 0x20, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2])
        // Assert: the AAD for a session is 8 bytes.
        XCTAssertEqual(FrameCodec.dataAAD(sessionID: 1).count, 8)
    }

    // Scenario: invalid frames in both directions.
    // Expected: encoding too-large or reserved-counter data fails; wrong-size pairing fields fail;
    // decoding bad magic, version, type, size, trailing bytes or a reserved counter fails.
    // Why it matters: strict checks stop malformed or hostile frames early.
    func testWireRejects() throws {
        // Encoding: the highest counter value is reserved and must be refused.
        XCTAssertThrowsError(try FrameCodec.encode(.data(sessionID: 1, counter: .max, sealed: b(16))))
        // Encoding: a payload that would exceed the frame limit is refused.
        XCTAssertThrowsError(try FrameCodec.encode(.data(sessionID: 1, counter: 1, sealed: b(1190))))
        // Encoding: pairing message 1 only accepts exactly 48 bytes.
        for n in [0, 31, 32, 47, 49] { XCTAssertThrowsError(try FrameCodec.encode(.pairM1(eAndTag: b(n)))) }
        // Decoding: wrong body sizes for pairing message 1 are refused.
        for n in [0, 32, 47, 49] { XCTAssertThrowsError(try FrameCodec.decode(Data([0x54, 0x57, 1, 0x01] + b(n)))) }
        // Decoding: unknown version is refused.
        XCTAssertThrowsError(try FrameCodec.decode(Data([0x54, 0x57, 2, 0x20])))
        // Decoding: wrong first magic byte is refused.
        XCTAssertThrowsError(try FrameCodec.decode(Data([0x00, 0x57, 1, 0x20])))
        // Decoding: unknown message type is refused.
        XCTAssertThrowsError(try FrameCodec.decode(Data([0x54, 0x57, 1, 0x99])))
        // Decoding: an oversized frame (1201 bytes) is refused.
        XCTAssertThrowsError(try FrameCodec.decode(Data(repeating: 0, count: 1201)))
        // Arrange: a valid reject frame with one extra byte added.
        var d = Array(try FrameCodec.encode(.reject)); d.append(0)
        // Assert: trailing bytes are refused.
        XCTAssertThrowsError(try FrameCodec.decode(Data(d)))
        // Arrange: a data frame whose counter bytes we overwrite.
        var m = Array(try FrameCodec.encode(.data(sessionID: 1, counter: 0, sealed: b(16))))
        // Set all eight counter bytes to 0xff, the reserved value.
        for i in 8..<16 { m[i] = 0xff }
        // Assert: decoding fails with the reservedCounter error.
        XCTAssertThrowsError(try FrameCodec.decode(Data(m))) { XCTAssertEqual($0 as? FramingError, .reservedCounter) }
    }

    /// Real XXpsk3 message 1 length decides the wire size (e + tag = 48), not a doc assumption.
    // Scenario: run a real handshake and take its first message.
    // Expected: the message is 48 bytes, matches the codec's size constant, and wraps to 52 bytes on the wire and back.
    // Why it matters: the size rule should come from the real protocol output, not an assumption.
    func testPairM1MatchesRealNoiseOutput() throws {
        // Arrange: a fresh key.
        let key = Curve25519.KeyAgreement.PrivateKey()
        // Create an initiator handshake with a pre-shared key and a prologue.
        var i = try NoiseHandshake(pattern: .xxPsk3, role: .initiator, staticKey: key,
                                   psk: Data(repeating: 9, count: 32), prologue: Data("p".utf8))
        // Act: write the first handshake message.
        let m1 = try i.writeMessage()
        // Assert: its size equals the codec constant.
        XCTAssertEqual(m1.count, FrameCodec.pairM1Size)
        // Assert: it is 48 bytes.
        XCTAssertEqual(m1.count, 48)
        // Act: wrap it in a frame.
        let wire = try FrameCodec.encode(.pairM1(eAndTag: Array(m1)))
        // Assert: the frame is 52 bytes (4 header bytes plus 48).
        XCTAssertEqual(wire.count, 52)
        // Assert: decoding gives the same message back.
        XCTAssertEqual(try FrameCodec.decode(wire), .pairM1(eAndTag: Array(m1)))
    }

    // Scenario: encode and decode every inner channel message (video, control, input).
    // Expected: sequence number and flags survive; input values are in range and close to the original; others are equal.
    // Why it matters: this is the common language between phone and host.
    func testChannelRoundTrips() throws {
        // Arrange: a sample video fragment.
        let frag = VideoFragment(frameID: 9, index: 1, count: 3, ptsUs: 123456789, isKeyframe: true, data: b(50))
        // Arrange: one example of each message kind, including text with a non-ASCII character.
        let cases: [ChannelMessage] = [
            .video(frag), .control(.ack(seq: 5)), .control(.nack(frameID: 8)), .control(.requestIDR),
            .control(.windowInfo(width: 1280, height: 720)), .control(.bitrate(4_000_000)),
            .control(.ping), .control(.bye),
            .input(.tap(x: 0, y: 1)), .input(.longPress(x: 0.5, y: 0.25)), .input(.dragStart(x: 0.1, y: 0.2)),
            .input(.dragMove(x: 0.3, y: 0.4)), .input(.dragEnd(x: 0.9, y: 0.8)),
            .input(.scroll(dx: -1, dy: 1)), .input(.zoom(delta: -0.5)), .input(.key(text: "héllo", mods: 3)),
            .input(.camStart(x: 0.2, y: 0.3)), .input(.camMove(x: 0.6, y: 0.7)), .input(.camEnd(x: 0.9, y: 0.1)),
        ]
        // Act: encode each case with a sequence number and flags.
        for c in cases {
            let enc = try ChannelMessage.encode(c, seq: 77, flags: 2)
            // Decode it again.
            let (m, seq, fl) = try ChannelMessage.decode(enc)
            // Assert: sequence and flags are preserved.
            XCTAssertEqual(seq, 77); XCTAssertEqual(fl, 2)
            // Compare by kind: input events allow tiny float error, everything else must be exactly equal.
            switch (m, c) {
            case (.input(let a), .input(let e)):
                // Assert: decoded input is already clamped into range.
                XCTAssertEqual(a.clamped, a)
                // Assert: values are close to the original.
                assertClose(a, e)
            // Everything else must match exactly.
            default: XCTAssertEqual(m, c)
            }
        }
    }

    // Helper: compares two input events, allowing a tiny difference in decimal values since coordinates are stored in 16 bits.
    private func assertClose(_ a: InputEvent, _ b: InputEvent) {
        // Pull out the numbers of an event; keys have none.
        func f(_ e: InputEvent) -> [Float]? {
            switch e {
            case .tap(let x, let y), .longPress(let x, let y), .dragStart(let x, let y),
                 .dragMove(let x, let y), .dragEnd(let x, let y), .scroll(let x, let y),
                 .camStart(let x, let y), .camMove(let x, let y), .camEnd(let x, let y): return [x, y]
            case .zoom(let d): return [d]
            case .key: return nil
            }
        }
        // If both have numbers, compare each number and the kind of event.
        if let p = f(a), let q = f(b) {
            XCTAssertEqual(p.count, q.count)
            for (u, v) in zip(p, q) { XCTAssertEqual(u, v, accuracy: 1e-4) }
            XCTAssertEqual(String(describing: a).prefix(4), String(describing: b).prefix(4))
        // Otherwise (keys), they must be equal.
        } else { XCTAssertEqual(a, b) }
    }

    // Scenario: send out-of-range and invalid coordinates, then check decoded values and limits.
    // Expected: decoded coordinates are always in 0 to 1; raw 0xFFFF becomes exactly 1; helper clamping works; empty or 33-character key text is refused.
    // Why it matters: bad coordinates must never reach the click code.
    func testCoordinateClamping() throws {
        // Encode out-of-range / NaN values: decode must land in range.
        // Try below-range, above-range, not-a-number and infinite values.
        for v: Float in [-5, 5, .nan, .infinity, -.infinity] {
            // Act: encode a tap with that value.
            let enc = try ChannelMessage.encode(.input(.tap(x: v, y: v)), seq: 0)
            // Act: decode it, failing if it is not a tap.
            guard case .input(.tap(let x, let y)) = try ChannelMessage.decode(enc).message else { return XCTFail() }
            // Assert: both values are within 0 to 1.
            XCTAssertTrue((0...1).contains(x) && (0...1).contains(y))
        }
        // Arrange: a tap encoded normally.
        // Raw 0xFFFF decodes to exactly 1.0.
        var enc = Array(try ChannelMessage.encode(.input(.tap(x: 0, y: 0)), seq: 0))
        // Act: overwrite both coordinates with the maximum raw value.
        enc[11] = 0xff; enc[12] = 0xff; enc[13] = 0xff; enc[14] = 0xff   // after sentMs u32
        // Decode the edited bytes.
        guard case .input(.tap(let x, let y)) = try ChannelMessage.decode(Data(enc)).message else { return XCTFail() }
        // Assert: both decode to exactly 1.
        XCTAssertEqual(x, 1); XCTAssertEqual(y, 1)
        // Assert: scroll values clamp to minus one and one.
        XCTAssertEqual(InputEvent.scroll(dx: 9, dy: -9).clamped, .scroll(dx: 1, dy: -1))
        // Assert: tap values clamp into 0 to 1.
        XCTAssertEqual(InputEvent.tap(x: 2, y: -1).clamped, .tap(x: 1, y: 0))
        // Assert: empty key text cannot be encoded.
        XCTAssertThrowsError(try ChannelMessage.encode(.input(.key(text: "", mods: 0)), seq: 0))
        // Assert: key text over 32 characters cannot be encoded.
        XCTAssertThrowsError(try ChannelMessage.encode(.input(.key(text: String(repeating: "a", count: 33), mods: 0)), seq: 0))
    }

    // Scenario: feed 10,000 random byte strings, some shaped like real frames, to both decoders.
    // Expected: no crash, and at least some inputs decode.
    // Why it matters: parsers must survive any input.
    func testFuzzNeverCrashes() {
        // Random source.
        var g = SystemRandomNumberGenerator()
        // Count of inputs that decoded successfully.
        var ok = 0
        // Act: run many rounds.
        for i in 0..<10_000 {
            // Pick a random length.
            let n = Int.random(in: 0...1300, using: &g)
            // Fill with random bytes.
            var bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
            // Half the time, make the start look like a valid frame header.
            if i % 2 == 0, n >= 4 { bytes[0] = 0x54; bytes[1] = 0x57; bytes[2] = 1; bytes[3] = [1, 2, 3, 0x10, 0x11, 0x20, 0x30].randomElement()! }
            // Sometimes set the first byte to a small value.
            if i % 3 == 0, n >= 6 { bytes[0] = UInt8.random(in: 0...3) }
            // Decode as a frame; count if it worked.
            if (try? FrameCodec.decode(Data(bytes))) != nil { ok += 1 }
            // Decode as a channel message; count if it worked.
            if (try? ChannelMessage.decode(Data(bytes))) != nil { ok += 1 }
        }
        // Assert: the test did exercise some valid decodes.
        XCTAssertGreaterThan(ok, 0)
    }

    // Scenario: feed packet numbers to the replay window in many orders.
    // Expected: new numbers are ok; repeats are duplicates; slightly out-of-order is ok; numbers too far behind are too old; the reserved maximum is refused; check never changes state; a big jump clears old state.
    // Why it matters: stops an attacker from replaying captured packets while allowing normal reordering.
    func testReplayWindow() {
        // Arrange: an empty window.
        var w = ReplayWindow()
        // First packet is accepted.
        XCTAssertEqual(w.commit(0), .ok)
        // Checking it again says duplicate.
        XCTAssertEqual(w.check(0), .duplicate)
        // Packet 5 is accepted.
        XCTAssertEqual(w.commit(5), .ok)
        XCTAssertEqual(w.commit(3), .ok)               // out of order
        XCTAssertEqual(w.commit(3), .duplicate)
        XCTAssertEqual(w.commit(5), .duplicate)
        XCTAssertEqual(w.check(.max), .reserved)
        // Jump to 3000 and accept.
        XCTAssertEqual(w.commit(3000), .ok)
        XCTAssertEqual(w.check(5), .tooOld)            // 2995 behind
        XCTAssertEqual(w.check(3000 - 2047), .ok)      // edge of window
        XCTAssertEqual(w.check(3000 - 2048), .tooOld)
        // Accept the packet at the window's far edge, then again as a duplicate.
        XCTAssertEqual(w.commit(3000 - 2047), .ok)
        XCTAssertEqual(w.commit(3000 - 2047), .duplicate)
        // A newer packet slides the window.
        XCTAssertEqual(w.commit(3001), .ok)
        XCTAssertEqual(w.check(3000 - 2047), .tooOld)  // slid out
        XCTAssertEqual(w.check(3000), .duplicate)
        // check does not mutate
        XCTAssertEqual(w.check(3002), .ok); XCTAssertEqual(w.check(3002), .ok)
        // big jump resets bits; ring slots must not alias old state
        XCTAssertEqual(w.commit(100_000), .ok)
        XCTAssertEqual(w.check(100_000 - 1), .ok)
        XCTAssertEqual(w.check(100_000), .duplicate)
        // The largest allowed counter can still be committed.
        XCTAssertEqual(w.commit(UInt64.max - 1), .ok)
    }

    // Scenario: split a 5000-byte frame, shuffle and duplicate fragments, drop fragments, wrap frame ids, and overflow pending frames.
    // Expected: 5 fragments each fitting the size limit; rebuilt frame is identical in any order; a lost fragment drops that frame and requests one keyframe; late fragments are ignored; frame ids wrap safely; bad sizes are refused; too many unfinished frames are evicted.
    // Why it matters: video goes over an unreliable link and must recover without hanging or growing without bound.
    func testFragmentationLossAndReorder() throws {
        // Random source for test data.
        var g = SystemRandomNumberGenerator()
        // Arrange: a random 5000-byte frame.
        let frame = Data((0..<5000).map { _ in UInt8.random(in: 0...255, using: &g) })
        // Act: fragment it.
        let frags = try VideoFragmenter.fragment(frameID: 1, ptsUs: 42, isKeyframe: true, annexB: frame)
        // Assert: five fragments.
        XCTAssertEqual(frags.count, 5)
        // Assert: each fragment, with its overhead, fits within 1200 bytes.
        for f in frags { XCTAssertLessThanOrEqual(try ChannelMessage.encode(.video(f), seq: 0).count + FrameCodec.dataHeaderSize + 16, 1200) }

        // Part 1: fragments arrive shuffled, with one duplicate.
        // reordered + duplicated
        // Arrange: a new reassembler.
        var r = VideoReassembler()
        var got: ReassembledFrame?
        // Act: ingest everything, keeping the finished frame.
        for f in (frags + [frags[2]]).shuffled() { if let x = r.ingest(f) { got = x } }
        // Assert: the rebuilt frame matches the original, keyframe flag and time stamp.
        XCTAssertEqual(got?.annexB, frame); XCTAssertEqual(got?.isKeyframe, true); XCTAssertEqual(got?.ptsUs, 42)
        // Assert: no keyframe request was needed.
        XCTAssertFalse(r.takeKeyframeRequest())

        // loss: frame 2 loses a fragment; frame 3 completes -> 2 dropped, keyframe requested
        // Arrange: frame 2 with all fragments.
        let f2 = try VideoFragmenter.fragment(frameID: 2, ptsUs: 1, isKeyframe: false, annexB: frame)
        // Arrange: frame 3 as a smaller frame.
        let f3 = try VideoFragmenter.fragment(frameID: 3, ptsUs: 2, isKeyframe: false, annexB: Data(frame.prefix(2000)))
        // Feed all but fragment 3 of frame 2; nothing finishes.
        for f in f2 where f.index != 3 { XCTAssertNil(r.ingest(f)) }
        var out: ReassembledFrame?
        // Feed frame 3 completely.
        for f in f3 { if let x = r.ingest(f) { out = x } }
        // Assert: frame 3 finished.
        XCTAssertEqual(out?.frameID, 3)
        // Assert: one frame was counted as dropped.
        XCTAssertEqual(r.droppedFrames, 1)
        // Assert: a keyframe is requested once, and the request clears after being taken.
        XCTAssertTrue(r.takeKeyframeRequest()); XCTAssertFalse(r.takeKeyframeRequest())
        // late fragment of dropped frame 2 is ignored
        // Assert: the stale fragment produces nothing.
        XCTAssertNil(r.ingest(f2[3]))
        // frame-id wraparound
        // Arrange: a fresh reassembler for wraparound.
        var r2 = VideoReassembler()
        // Frame ids around the maximum and zero.
        for id in [UInt32.max - 1, UInt32.max, 0, 1] {
            // Act: fragment a tiny frame.
            let fs = try VideoFragmenter.fragment(frameID: id, ptsUs: 0, isKeyframe: false, annexB: Data(b(10)))
            // Assert: it completes right away.
            XCTAssertNotNil(r2.ingest(fs[0]))
        }
        // Assert: wraparound did not look like loss.
        XCTAssertFalse(r2.takeKeyframeRequest())
        // oversize / inconsistent
        // Assert: an empty frame is refused.
        XCTAssertThrowsError(try VideoFragmenter.fragment(frameID: 0, ptsUs: 0, isKeyframe: false, annexB: Data()))
        // Assert: a 2 MB frame is refused as too big.
        XCTAssertThrowsError(try VideoFragmenter.fragment(frameID: 0, ptsUs: 0, isKeyframe: false, annexB: Data(count: 2_000_000)))
        // pending overflow evicts and requests keyframe
        // Arrange: a reassembler that never gets the second fragment.
        var r3 = VideoReassembler()
        // Start twelve incomplete frames.
        for id in 1...12 { _ = r3.ingest(VideoFragment(frameID: UInt32(id), index: 0, count: 2, ptsUs: 0, isKeyframe: false, data: b(4))) }
        // Assert: old ones were evicted and a keyframe is requested.
        XCTAssertGreaterThan(r3.droppedFrames, 0); XCTAssertTrue(r3.takeKeyframeRequest())
    }

    // Scenario: send taps too fast and mix event kinds.
    // Expected: the first is allowed; others within 50 ms are dropped and counted, not queued; different kinds have separate timers; a clock that goes backwards drops.
    // Why it matters: flooding input must not build a backlog that replays later.
    func testRateLimiterDropsNotQueues() {
        // Arrange: a limiter.
        var l = InputRateLimiter()
        // First tap is allowed.
        XCTAssertTrue(l.allow(.tap(x: 0, y: 0), nowMs: 1000))
        // A tap 49 ms later is dropped.
        XCTAssertFalse(l.allow(.tap(x: 0, y: 0), nowMs: 1049))
        // Another is dropped too.
        XCTAssertFalse(l.allow(.tap(x: 0, y: 0), nowMs: 1049))
        // Assert: two drops counted.
        XCTAssertEqual(l.droppedCount, 2)
        XCTAssertTrue(l.allow(.longPress(x: 0, y: 0), nowMs: 1010))      // separate class
        XCTAssertTrue(l.allow(.tap(x: 0, y: 0), nowMs: 1050))            // dropped ones did not reset clock, none replayed
        XCTAssertFalse(l.allow(.tap(x: 0, y: 0), nowMs: 1051))
        // Scroll first use is allowed.
        XCTAssertTrue(l.allow(.scroll(dx: 0, dy: 0), nowMs: 0))
        XCTAssertFalse(l.allow(.scroll(dx: 0, dy: 0), nowMs: 0))         // clock going backwards also drops
        // A drag end is its own kind, so it is allowed.
        XCTAssertTrue(l.allow(.dragEnd(x: 0, y: 0), nowMs: 0))
        // Assert: four drops in total.
        XCTAssertEqual(l.droppedCount, 4)
    }

    // Scenario: send drag and tap events in a bad order to the host gate, then release all.
    // Expected: a move without a start is blocked; a start is admitted once; taps are blocked mid-drag; fast moves are dropped; release returns the left button and clears the drag; a second release returns nothing.
    // Why it matters: the host must never leave the mouse button stuck down.
    func testReleaseAllAndGate() {
        // Arrange: a new gate.
        var g = HostInputGate()
        // Blocked: no drag in progress.
        XCTAssertFalse(g.admit(.dragMove(x: 0, y: 0), nowMs: 0))         // move without start
        // Allowed: a drag start.
        XCTAssertTrue(g.admit(.dragStart(x: 0.1, y: 0.1), nowMs: 100))
        // Blocked: already dragging.
        XCTAssertFalse(g.admit(.dragStart(x: 0.1, y: 0.1), nowMs: 500))  // already held
        XCTAssertFalse(g.admit(.tap(x: 0.1, y: 0.1), nowMs: 500))        // no click mid-drag
        XCTAssertTrue(g.admit(.dragMove(x: 0.2, y: 0.2), nowMs: 100))    // separate class from dragStart
        XCTAssertFalse(g.admit(.dragMove(x: 0.2, y: 0.2), nowMs: 120))   // within 50 ms: dropped
        // Assert: the gate believes a drag is in progress.
        XCTAssertTrue(g.state.isDragging)
        // Act: release everything; expect the left button to be released.
        XCTAssertEqual(g.releaseAll(), [.left])
        // Assert: no drag now.
        XCTAssertFalse(g.state.isDragging)
        // Assert: a second release has nothing to do.
        XCTAssertEqual(g.releaseAll(), [])
        // A fresh drag start is allowed.
        XCTAssertTrue(g.admit(.dragStart(x: 0, y: 0), nowMs: 1000))
        // Its end is allowed.
        XCTAssertTrue(g.admit(.dragEnd(x: 0, y: 0), nowMs: 1001))
        // Assert: no drag remains.
        XCTAssertFalse(g.state.isDragging)
    }
}
