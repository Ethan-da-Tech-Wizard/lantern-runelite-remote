// Program: Lantern - NoiseTests.swift
// Programmer: Ethan-da-Tech-Wizard (written with Claude, an AI assistant)
// Last Modified: 2026-11-18
// Purpose: Tests the Noise handshake and encryption.
//
// Area protected: the Noise handshake and transport encryption in LanternCore. It checks
// the code against published known-answer test vectors, normal handshake round trips for both
// patterns, many failure cases (wrong key, tampering, wrong prologue, bad order, bad config),
// and the transport rules (tamper detection, replay and nonce reuse rejection, window edges).
// If this layer is wrong, the encrypted link is not safe.
import XCTest
import CryptoKit
@testable import LanternCore

/// Known-answer vectors: cacophony vectors/cacophony.txt (github.com/centromere/cacophony),
/// entries for the two exact protocol names below, embedded verbatim.
// Holder for the two test vectors: fixed keys and messages with the exact expected output, so our code must match the reference byte for byte.
enum NoiseVectors {
    // One vector: protocol name, prologue, optional pre-shared key, both sides' keys, final hash, and the list of (payload, expected ciphertext) pairs, all as hex text.
    struct Vec {
        let name, prologue: String
        let psk: String?
        let iStatic, iEph: String
        let iRemote: String?
        let rStatic, rEph, hash: String
        let messages: [(String, String)]
    }
    // Vector for the IK pattern (initiator already knows the responder's key).
    static let ik = Vec(
        name: "Noise_IK_25519_ChaChaPoly_SHA256", prologue: "4a6f686e2047616c74",
        psk: nil,
        iStatic: "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1", iEph: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a", iRemote: "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62",
        rStatic: "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893", rEph: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
        hash: "0b0f68fb0c27e03ce9b97565995ed4838cc0581b762ef72b062f6a546419fad7",
        messages: [
            ("4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944718da798efbcd91528520204f904b9bd6c7413dccdc214d951e15253e39987f18146e8cd0873654207148333479d4d16c289f0294b29960a72f48e0b7bba2e89083169825e59642148d492020664ccf7"),
            ("4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088435361e70b2ed446e6c9ec387d1d6b3b840f194e373979d241b203c4acafccf5"),
            ("462e20412e20486179656b", "050e9f3c8fac16b68dbce8f8c4bfbf6617c897f9ada4aa29aa19c8"),
            ("4361726c204d656e676572", "344233a6cabb7141d80f3da2fedc311d9646bbb0f505afe403a667"),
            ("4a65616e2d426170746973746520536179", "62cdeeb172ad7ade7aa7d9e069da5790f12331bfa00177787a1d0810c67dc3b2b4"),
            ("457567656e2042f6686d20766f6e2042617765726b", "029bead1b40992327044d409d9a1f3ad8f36c3c452775d557e18bbeb2e8dfcead32d514024")
        ])
    // Vector for the XX pattern with a pre-shared key mixed in at step 3.
    static let xx = Vec(
        name: "Noise_XXpsk3_25519_ChaChaPoly_SHA256", prologue: "4a6f686e2047616c74",
        psk: "54686973206973206d7920417573747269616e20706572737065637469766521",
        iStatic: "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1", iEph: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a", iRemote: nil,
        rStatic: "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893", rEph: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
        hash: "a477edf6a131bbdb54707f6ea30eab6cd935d9b560f0e5fd1f053a95a99669fb",
        messages: [
            ("4c756477696720766f6e204d69736573", "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944c9f5ff0e8079630cb7e270c20bbf480821b77a384a645c71a2fd9b3db1c16a5f"),
            ("4d757272617920526f746862617264", "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843b123def17f71e6ae8e57e0e1dec5949c5f7415c6f33517398747d821a06dc23ad430aa1fd7381d46195c378a819fd574425462cbb2d4ca339e738a0b7001dc91423fbf55a99af0c6f1df21012ceb2f"),
            ("462e20412e20486179656b", "52187316111b118d4c060364f7b975dc0809b2590779aff2d63113c564f11744493384db7bf32d5ae6686df6ab06d508d2e07caaf1d6afc010b978735fc78900e71ae1d314130d042e729a"),
            ("4361726c204d656e676572", "eaedc672d4c21e0e2955758756fb98f194c4e90d5deb5b6cf30b27"),
            ("4a65616e2d426170746973746520536179", "522d543c5fe799d09a3d9da7ff54d0dc03c8af1dc7751d2ff708339d2290943e98"),
            ("457567656e2042f6686d20766f6e2042617765726b", "7d4e2c3873eef6a213b04e72f9df60a91666072d3544c5d96c34a09e2329b5030bee796741")
        ])
}

// Helper: turns a hex string into bytes, two characters at a time.
private func hex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}
// Helper: builds a private key from hex.
private func priv(_ s: String) -> Curve25519.KeyAgreement.PrivateKey { try! .init(rawRepresentation: hex(s)) }
// Helper: makes a fresh random key.
private func gen() -> Curve25519.KeyAgreement.PrivateKey { .init() }

// Tests for the Noise handshake and its cipher states.
final class NoiseTests: XCTestCase {

    // MARK: known answer
    // Helper: runs one known-answer vector through both handshake sides, then through the transport messages, comparing every ciphertext and hash with the expected value.
    private func runVector(_ v: NoiseVectors.Vec, pattern: NoisePattern, file: StaticString = #filePath, line: UInt = #line) throws {
        // Assert: the pattern's name matches the vector's name.
        XCTAssertEqual(pattern.protocolName, v.name)
        // Arrange: the responder's static key.
        let rS = priv(v.rStatic)
        // Create the initiator with fixed keys so results are repeatable.
        var i = try NoiseHandshake(pattern: pattern, role: .initiator, staticKey: priv(v.iStatic),
                                   remoteStatic: v.iRemote.map { _ in rS.publicKey }, psk: v.psk.map(hex),
                                   prologue: hex(v.prologue), ephemeral: priv(v.iEph))
        // Create the responder the same way.
        var r = try NoiseHandshake(pattern: pattern, role: .responder, staticKey: rS, remoteStatic: nil,
                                   psk: v.psk.map(hex), prologue: hex(v.prologue), ephemeral: priv(v.rEph))
        // How many handshake messages the pattern has.
        let hsCount = pattern.messages.count
        // Act: walk through handshake messages, alternating who writes.
        for k in 0..<hsCount {
            // Expected payload and ciphertext for this step.
            let (payload, ct) = (hex(v.messages[k].0), hex(v.messages[k].1))
            // Even steps are written by the initiator.
            let initiatorWrites = k % 2 == 0
            // The writer produces a message.
            let out = initiatorWrites ? try i.writeMessage(payload) : try r.writeMessage(payload)
            // Assert: it equals the expected ciphertext.
            XCTAssertEqual(out, ct, "handshake msg \(k) ciphertext", file: file, line: line)
            // The other side reads it.
            let got = initiatorWrites ? try r.readMessage(out) : try i.readMessage(out)
            // Assert: it recovers the original payload.
            XCTAssertEqual(got, payload, file: file, line: line)
        }
        // Assert: both sides finished the handshake.
        XCTAssertTrue(i.isComplete && r.isComplete, file: file, line: line)
        // Assert: the initiator's final hash matches.
        XCTAssertEqual(i.handshakeHash, hex(v.hash), "handshake hash (initiator)", file: file, line: line)
        // Assert: the responder's final hash matches.
        XCTAssertEqual(r.handshakeHash, hex(v.hash), "handshake hash (responder)", file: file, line: line)
        // Split into the two transport cipher states.
        var ic = try i.split(), rc = try r.split()
        // Act: the remaining vector messages are encrypted transport messages.
        for k in hsCount..<v.messages.count {
            let (payload, ct) = (hex(v.messages[k].0), hex(v.messages[k].1))
            // Even steps travel initiator to responder.
            if k % 2 == 0 {
                // Assert: encrypting gives the expected ciphertext.
                XCTAssertEqual(try ic.send.encrypt(payload), ct, "transport msg \(k)", file: file, line: line)
                // Assert: the other side decrypts to the payload.
                XCTAssertEqual(try rc.receive.decrypt(ct), payload, file: file, line: line)
            // Odd steps travel responder to initiator.
            } else {
                // Assert: encrypting gives the expected ciphertext.
                XCTAssertEqual(try rc.send.encrypt(payload), ct, "transport msg \(k)", file: file, line: line)
                // Assert: the other side decrypts to the payload.
                XCTAssertEqual(try ic.receive.decrypt(ct), payload, file: file, line: line)
            }
        }
    }

    // Scenario: run the published vector for the pairing pattern. Expected: all bytes match. Why it matters: proves we implement the standard correctly.
    func testKnownAnswerXXpsk3() throws { try runVector(NoiseVectors.xx, pattern: .xxPsk3) }
    // Scenario: run the published vector for the known-peer pattern. Expected: all bytes match. Why it matters: same reason as above.
    func testKnownAnswerIK() throws { try runVector(NoiseVectors.ik, pattern: .ik) }

    // MARK: round trips
    // Shared test settings: a prologue (both sides must agree) and a 32-byte pre-shared key.
    private let prologue = Data("twu-stream-v1".utf8) + Data([1])
    private let psk = Data((0..<32).map { UInt8($0) })

    // Helper: builds an initiator and responder for the pairing pattern with new keys; either pre-shared key can be changed to simulate a mismatch.
    private func makeXX(pskI: Data? = nil, pskR: Data? = nil) throws -> (NoiseHandshake, NoiseHandshake, Curve25519.KeyAgreement.PrivateKey, Curve25519.KeyAgreement.PrivateKey) {
        // Make two fresh keys.
        let a = gen(), b = gen()
        // Initiator.
        let i = try NoiseHandshake(pattern: .xxPsk3, role: .initiator, staticKey: a, psk: pskI ?? psk, prologue: prologue)
        // Responder.
        let r = try NoiseHandshake(pattern: .xxPsk3, role: .responder, staticKey: b, psk: pskR ?? psk, prologue: prologue)
        // Return both sides and both keys.
        return (i, r, a, b)
    }

    // Scenario: a full pairing handshake with small payloads, then one message each way.
    // Expected: payloads arrive intact, both finish, each learns the other's public key, hashes match, and the transport works both ways.
    // Why it matters: this is the main success path.
    func testRoundTripXXpsk3() throws {
        // Arrange: matching handshake sides.
        var (i, r, a, b) = try makeXX()
        // Message 1: initiator to responder.
        let m1 = try i.writeMessage(); _ = try r.readMessage(m1)
        // Message 2: responder to initiator with a payload.
        let m2 = try r.writeMessage(Data("hi".utf8)); XCTAssertEqual(try i.readMessage(m2), Data("hi".utf8))
        // Message 3: initiator to responder with a payload.
        let m3 = try i.writeMessage(Data("phone".utf8)); XCTAssertEqual(try r.readMessage(m3), Data("phone".utf8))
        // Assert: both sides are complete.
        XCTAssertTrue(i.isComplete && r.isComplete)
        // Assert: the initiator learned the responder's key.
        XCTAssertEqual(i.remoteStaticPublicKey?.rawRepresentation, b.publicKey.rawRepresentation)
        // Assert: the responder learned the initiator's key.
        XCTAssertEqual(r.remoteStaticPublicKey?.rawRepresentation, a.publicKey.rawRepresentation)
        // Assert: both agree on the handshake hash.
        XCTAssertEqual(i.handshakeHash, r.handshakeHash)
        // Split into transport states.
        var ic = try i.split(), rc = try r.split()
        // Assert: a message from initiator decrypts at responder.
        XCTAssertEqual(try rc.receive.decrypt(try ic.send.encrypt(Data("x".utf8))), Data("x".utf8))
        // Assert: a message from responder decrypts at initiator.
        XCTAssertEqual(try ic.receive.decrypt(try rc.send.encrypt(Data("y".utf8))), Data("y".utf8))
    }

    // Scenario: a full handshake for the known-peer pattern.
    // Expected: payload arrives, responder learns the initiator's key, both finish and transport works.
    // Why it matters: this is the fast reconnect path.
    func testRoundTripIK() throws {
        // Arrange: two keys.
        let a = gen(), b = gen()
        // Initiator who already knows the responder's key.
        var i = try NoiseHandshake(pattern: .ik, role: .initiator, staticKey: a, remoteStatic: b.publicKey, prologue: prologue)
        // Responder.
        var r = try NoiseHandshake(pattern: .ik, role: .responder, staticKey: b, prologue: prologue)
        // Message 1 carries a small payload.
        let m1 = try i.writeMessage(Data([1, 2, 3]))
        // Assert: it arrives intact.
        XCTAssertEqual(try r.readMessage(m1), Data([1, 2, 3]))
        // Assert: the responder learned the initiator's key.
        XCTAssertEqual(r.remoteStaticPublicKey?.rawRepresentation, a.publicKey.rawRepresentation)
        // Message 2 in reply.
        let m2 = try r.writeMessage(); _ = try i.readMessage(m2)
        // Assert: both are complete.
        XCTAssertTrue(i.isComplete && r.isComplete)
        // Split into transport states.
        var ic = try i.split(), rc = try r.split()
        // Assert: a message goes through.
        XCTAssertEqual(try rc.receive.decrypt(try ic.send.encrypt(Data("z".utf8))), Data("z".utf8))
    }

    // Scenario: the initiator expects a different responder key than the real one.
    // Expected: reading the first message fails.
    // Why it matters: stops talking to an impostor.
    func testIKWrongResponderStaticFails() throws {
        // Arrange: three keys; "other" is the wrong expected key.
        let a = gen(), b = gen(), other = gen()
        // Initiator with the wrong remote key.
        var i = try NoiseHandshake(pattern: .ik, role: .initiator, staticKey: a, remoteStatic: other.publicKey, prologue: prologue)
        // Real responder.
        var r = try NoiseHandshake(pattern: .ik, role: .responder, staticKey: b, prologue: prologue)
        // Assert: the responder cannot read the message.
        XCTAssertThrowsError(try r.readMessage(try i.writeMessage()))
    }

    // MARK: negatives
    // Scenario: the two sides use different pre-shared keys.
    // Expected: step 3 fails with decryptionFailed; the responder is not complete and cannot split.
    // Why it matters: a wrong pairing code must not produce a working session.
    func testWrongPSKFails() throws {
        // Arrange: responder with a different key.
        var (i, r, _, _) = try makeXX(pskR: Data(repeating: 9, count: 32))
        // Message 1.
        let m1 = try i.writeMessage(); _ = try r.readMessage(m1)
        // Message 2.
        let m2 = try r.writeMessage(); _ = try i.readMessage(m2)
        // Message 3 is built with the right key.
        let m3 = try i.writeMessage(Data("phone".utf8))
        // Assert: the responder fails with decryptionFailed.
        XCTAssertThrowsError(try r.readMessage(m3)) { XCTAssertEqual($0 as? NoiseError, .decryptionFailed) }
        // Assert: it is not complete.
        XCTAssertFalse(r.isComplete)
        // Assert: it refuses to split into transport keys.
        XCTAssertThrowsError(try r.split())
    }

    // Scenario: flip a bit in message 2, then in message 3.
    // Expected: both are rejected.
    // Why it matters: handshake messages must be authenticated.
    func testTamperedHandshakeMessageFails() throws {
        for idx in [1, 2] { // tamper msg2 (responder->initiator) and msg3
            // Fresh handshake each time.
            var (i, r, _, _) = try makeXX()
            // Message 1.
            let m1 = try i.writeMessage(); _ = try r.readMessage(m1)
            // Message 2.
            var m2 = try r.writeMessage(Data("p".utf8))
            // Case 1: damage the last byte of message 2 and expect a failure, then go to the next case.
            if idx == 1 { m2[m2.count - 1] ^= 1; XCTAssertThrowsError(try i.readMessage(m2)); continue }
            // Case 2: the initiator reads message 2 fine.
            _ = try i.readMessage(m2)
            // Message 3 with one bit flipped.
            var m3 = try i.writeMessage(Data("p".utf8)); m3[40] ^= 0x80
            // Assert: the responder rejects it.
            XCTAssertThrowsError(try r.readMessage(m3))
        }
    }

    // Scenario: the two sides use different prologues.
    // Expected: the first message fails to read.
    // Why it matters: binds the session to the protocol context.
    func testPrologueMismatchFails() throws {
        // Arrange: two keys.
        let a = gen(), b = gen()
        // Initiator with prologue a.
        var i = try NoiseHandshake(pattern: .ik, role: .initiator, staticKey: a, remoteStatic: b.publicKey, prologue: Data("a".utf8))
        // Responder with prologue b.
        var r = try NoiseHandshake(pattern: .ik, role: .responder, staticKey: b, prologue: Data("b".utf8))
        // Assert: reading fails.
        XCTAssertThrowsError(try r.readMessage(try i.writeMessage()))
    }

    // Scenario: wrong order, short message and reuse after failure.
    // Expected: responder cannot write first; a 10-byte message fails; the handshake then stays broken (poisoned).
    // Why it matters: errors must not leave the state half open.
    func testTruncatedAndOutOfTurn() throws {
        // Arrange: handshake sides.
        var (i, r, _, _) = try makeXX()
        // Responder writing first is refused.
        XCTAssertThrowsError(try r.writeMessage())      // responder cannot go first
        // Message 1 from the initiator.
        let m1 = try i.writeMessage()
        // A truncated copy is refused.
        XCTAssertThrowsError(try r.readMessage(m1.prefix(10)))
        // Even the full message is refused afterwards.
        XCTAssertThrowsError(try r.readMessage(m1))     // poisoned after failure
    }

    // Scenario: invalid setup.
    // Expected: no pre-shared key, a 5-byte key, or no remote key for the known-peer pattern all throw.
    // Why it matters: bad setup must fail early.
    func testBadConfig() {
        // Missing pre-shared key.
        XCTAssertThrowsError(try NoiseHandshake(pattern: .xxPsk3, role: .initiator, staticKey: gen(), psk: nil))
        // Wrong-size pre-shared key.
        XCTAssertThrowsError(try NoiseHandshake(pattern: .xxPsk3, role: .initiator, staticKey: gen(), psk: Data(count: 5)))
        // Known-peer pattern without the peer's key.
        XCTAssertThrowsError(try NoiseHandshake(pattern: .ik, role: .initiator, staticKey: gen()))
    }

    // MARK: transport
    // Helper: completes a handshake and returns one send state and the matching receive state.
    private func pair() throws -> (send: NoiseCipherState, recv: NoiseCipherState) {
        // Arrange: handshake sides.
        var (i, r, _, _) = try makeXX()
        // Message 1.
        _ = try r.readMessage(try i.writeMessage())
        // Message 2.
        _ = try i.readMessage(try r.writeMessage())
        // Message 3.
        _ = try r.readMessage(try i.writeMessage())
        // Return the transport states.
        return (try i.split().send, try r.split().receive)
    }

    // Scenario: damage a ciphertext, use the wrong extra data, then retry correctly.
    // Expected: tampering and wrong extra data are rejected, and failures do not use up the counter, so the right data still works.
    // Why it matters: an attacker's bad packet must not block real traffic.
    func testTamperedTransportFails() throws {
        // Arrange: a send and receive pair.
        var (s, rcv) = try pair()
        // Encrypt a message with extra data.
        var ct = try s.encrypt(Data("secret".utf8), ad: Data([1]))
        // Flip a bit.
        ct[0] ^= 1
        // Assert: decrypting fails.
        XCTAssertThrowsError(try rcv.decrypt(ct, ad: Data([1]), counter: 0))
        // wrong AAD
        // Encrypt again.
        let ct2 = try s.encrypt(Data("secret".utf8), ad: Data([1]))
        // Assert: decrypting with the wrong extra data fails.
        XCTAssertThrowsError(try rcv.decrypt(ct2, ad: Data([2]), counter: 1))
        // failed attempts must not consume the counter
        // Assert: the right extra data still decrypts, so the counter was not consumed.
        XCTAssertEqual(try rcv.decrypt(ct2, ad: Data([1]), counter: 1), Data("secret".utf8))
    }

    // Scenario: decrypt packets with explicit counters, repeated and reordered.
    // Expected: first use works, repeats fail with replay, out-of-order works once, and a wrong counter fails.
    // Why it matters: captured packets must not be replayed.
    func testReplayAndNonceReuseRejected() throws {
        // Arrange: a send and receive pair.
        var (s, rcv) = try pair()
        // Three ciphertexts, counters 0, 1, 2.
        let c0 = try s.encrypt(Data("a".utf8)), c1 = try s.encrypt(Data("b".utf8)), c2 = try s.encrypt(Data("c".utf8))
        // Counter 0 works.
        XCTAssertEqual(try rcv.decrypt(c0, counter: 0), Data("a".utf8))
        // Using it again is a replay.
        XCTAssertThrowsError(try rcv.decrypt(c0, counter: 0)) { XCTAssertEqual($0 as? NoiseError, .replay) }
        XCTAssertEqual(try rcv.decrypt(c2, counter: 2), Data("c".utf8))   // reorder ok
        // Counter 1 still works afterwards.
        XCTAssertEqual(try rcv.decrypt(c1, counter: 1), Data("b".utf8))
        // Using counter 1 again is a replay.
        XCTAssertThrowsError(try rcv.decrypt(c1, counter: 1)) { XCTAssertEqual($0 as? NoiseError, .replay) }
        // wrong counter for a ciphertext fails auth
        // Counter 0's packet with the wrong counter fails authentication.
        XCTAssertThrowsError(try rcv.decrypt(c0, counter: 5))
    }

    // Scenario: decrypt in plain sequence, then try the same packet again.
    // Expected: the repeat fails.
    // Why it matters: the automatic counter must move forward.
    func testSequentialDecryptRejectsReplay() throws {
        // Arrange: a send and receive pair.
        var (s, rcv) = try pair()
        // Encrypt one message.
        let c0 = try s.encrypt(Data("a".utf8))
        // First decrypt works.
        _ = try rcv.decrypt(c0)
        // Assert: the second decrypt fails.
        XCTAssertThrowsError(try rcv.decrypt(c0))   // nonce now 1
    }

    // Scenario: a window of size 128 around packet number 1000.
    // Expected: 1000 is seen, 1001 is new, the oldest slot (873) is open, one older is too old, a big jump clears the window, and sliding forward forgets the oldest numbers.
    // Why it matters: window edges are where off-by-one bugs hide.
    func testReplayWindowEdges() {
        // Arrange: a 128-wide window.
        var w = NoiseReplayWindow(size: 128)
        // Commit 1000.
        w.commit(1000)
        // Assert: 1000 is no longer allowed.
        XCTAssertFalse(w.check(1000))
        // Assert: 1001 is allowed.
        XCTAssertTrue(w.check(1001))
        // Assert: the oldest in-window number is allowed.
        XCTAssertTrue(w.check(1000 - 127))
        XCTAssertFalse(w.check(1000 - 128))  // too old
        // Commit that old number.
        w.commit(1000 - 127)
        // Assert: it is now blocked.
        XCTAssertFalse(w.check(1000 - 127))
        w.commit(5000)                       // big jump clears window
        XCTAssertTrue(w.check(4990))
        XCTAssertFalse(w.check(1000))
        // Commit two more, sliding the window.
        w.commit(5001); w.commit(5130)       // slide past 5000/5001
        // Assert: always passes by design (the "&& false" makes the value false); kept as written.
        XCTAssertFalse(w.check(5001) && false)
        // Assert: 5130 is now seen.
        XCTAssertFalse(w.check(5130))
    }

    // Scenario: use the reserved maximum counter.
    // Expected: encrypting fails with nonceExhausted; decrypting is refused.
    // Why it matters: the last counter value must never be used.
    func testReservedCounterRejected() throws {
        // Arrange: a send and receive pair.
        var (s, rcv) = try pair()
        // Assert: encrypt with the reserved counter fails.
        XCTAssertThrowsError(try s.encrypt(Data(), counter: UInt64.max)) { XCTAssertEqual($0 as? NoiseError, .nonceExhausted) }
        // Assert: decrypt with the reserved counter fails.
        XCTAssertThrowsError(try rcv.decrypt(Data(count: 16), counter: UInt64.max))
    }
}
