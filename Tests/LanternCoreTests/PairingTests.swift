// ==============================================================================
// Program: PairingTests.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Tests for pairing code generation, parsing, rate-limiting, and key storage.
//          Inputs: Ephemeral pairing tokens, mock Keychain stores, and pairing requests.
//          Outputs: Assertions validating correct key persistence and authorization outcomes.
//          Design Rationale: Prevents regressions in pairing security policy and credential storage.
// ==============================================================================
// Area protected: pairing and key storage in LanternCore. It covers the pairing code
// (format, randomness, parsing), the QR payload, constant-time comparison, the pairing
// policy (expiry, single use, lockout after repeated failures, QR secrets), the key stores
// (in-memory and system keychain), that stored peer data never holds a private key, and the
// short check number (SAS) both sides compare.
// These rules decide who may connect, so each test guards a security property.
import XCTest
import CryptoKit
@testable import LanternCore

// Test helper: a clock the test can move forward by hand, so expiry tests need no real waiting.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

// Tests for pairing codes, policy and key stores.
final class PairingTests: XCTestCase {
    // Scenario: generate 3000 codes and inspect them, then check parsing.
    // Expected: each code is 10 characters from the allowed alphabet with no look-alike letters
    // (I, L, O, U); the display form has 11 characters (with a separator); all codes are unique;
    // all 32 symbols appear about evenly; entropy is 50 bits; parsing accepts lowercase and alias
    // characters and rejects bad input; printing a code does not reveal it.
    // Why it matters: a guessable or biased code weakens pairing security.
    func testCodeFormatAndEntropySanity() throws {
        // Arrange: containers to track unique codes and how often each symbol appears.
        var seen = Set<String>(); var counts = [Character: Int]()
        // Number of codes to sample.
        let n = 3000
        // Act: generate many codes and check each one.
        for _ in 0..<n {
            let c = PairingCode.generate()
            // Assert: the code text is 10 characters.
            XCTAssertEqual(c.text.count, 10)
            // Assert: every character is in the allowed alphabet.
            XCTAssertTrue(c.text.allSatisfy { PairingCode.alphabet.contains($0) })
            // Assert: no confusing letters are used.
            XCTAssertFalse(c.text.contains { "ILOU".contains($0) })
            // Assert: the display string adds one separator character.
            XCTAssertEqual(c.displayString.count, 11)
            // Remember the code to check uniqueness later.
            seen.insert(c.text)
            // Count each symbol.
            for ch in c.text { counts[ch, default: 0] += 1 }
        }
        // Assert: no duplicates in 3000 codes.
        XCTAssertEqual(seen.count, n)
        // Assert: all 32 symbols appeared.
        XCTAssertEqual(counts.count, 32)
        // Each symbol should appear about this many times if the choice is even.
        let expected = Double(n * 10) / 32
        // Assert: each symbol is within 20 percent of the expected count.
        for (_, v) in counts { XCTAssertEqual(Double(v), expected, accuracy: expected * 0.2) }
        // Assert: the code carries 50 bits of entropy.
        XCTAssertEqual(PairingCode.bitsOfEntropy, 50)
        // parse round trip incl. Crockford aliases and separators
        // Generate one more code for the parsing checks.
        let c = PairingCode.generate()
        // Assert: the lowercase display form parses and matches the original.
        XCTAssertTrue(try PairingCode(parsing: c.displayString.lowercased()).matches(c))
        // Assert: look-alike characters are mapped to the right digits and the separator is dropped.
        XCTAssertEqual(try PairingCode(parsing: "oi1l0-ABCDE").text, "01110ABCDE")
        // Assert: a too-short code is rejected.
        XCTAssertThrowsError(try PairingCode(parsing: "ABC"))
        // Assert: a code with a forbidden letter is rejected.
        XCTAssertThrowsError(try PairingCode(parsing: "ABCDE-FGHIU"))
        // Assert: printing the code object does not leak the secret text.
        XCTAssertFalse("\(c)".contains(c.text))
    }

    // Scenario: encode a QR payload and parse it back, plus malformed payloads.
    // Expected: the secret and address hint survive, the host key check passes only for the right
    // key, and bad prefixes or shapes throw.
    // Why it matters: the QR carries the pairing secret, so round-tripping and validation must be exact.
    func testQRPayloadRoundTrip() throws {
        // Arrange: a host public key.
        let host = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        // Act: generate a payload with an address hint.
        let p = PairingQRPayload.generate(hostPublicKey: host, addressHint: "192.168.1.20:7777")
        // Act: encode it to text and parse it back.
        let q = try PairingQRPayload(parsing: p.encoded())
        // Assert: the secret is unchanged.
        XCTAssertEqual(q.secret, p.secret)
        // Assert: the address hint is unchanged.
        XCTAssertEqual(q.addressHint, "192.168.1.20:7777")
        // Assert: the real host key matches.
        XCTAssertTrue(q.matchesHostKey(host))
        // Assert: a different key does not match.
        XCTAssertFalse(q.matchesHostKey(Data(repeating: 1, count: 32)))
        // Assert: a payload with too few parts is rejected.
        XCTAssertThrowsError(try PairingQRPayload(parsing: "LNT1.x.y"))
        // Assert: a payload with the wrong prefix is rejected.
        XCTAssertThrowsError(try PairingQRPayload(parsing: "XXX1.AA.BB.CC"))
    }

    // Scenario: compare byte strings with the constant-time helper.
    // Expected: equal data is true; different values, different lengths are false; two empty values are equal.
    // Why it matters: normal comparison can leak timing information about secrets.
    func testConstantTimeCompare() {
        // Equal data returns true.
        XCTAssertTrue(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        // Same length, one byte different returns false.
        XCTAssertFalse(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        // Different length returns false.
        XCTAssertFalse(constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
        // Both empty returns true.
        XCTAssertTrue(constantTimeEquals(Data(), Data()))
    }

    // Scenario: a pairing window lasts 120 seconds on a fake clock.
    // Expected: still active at 119 seconds, expired at 120, with no credential and attempts
    // reported as expired; starting again re-arms it and a valid code works.
    // Why it matters: an old pairing code must not stay usable forever.
    func testTTLExpiry() {
        // Arrange: a controllable clock and a policy that reads it.
        let clock = TestClock()
        var p = PairingPolicy(now: { clock.now() })
        // Assert: a new policy is idle.
        XCTAssertEqual(p.state, .idle)
        // Act: begin pairing and get a code.
        let c = p.begin()
        // Assert: the policy is active.
        XCTAssertTrue(p.isActive)
        // Act: move time forward 119 seconds.
        clock.advance(119)
        // Assert: still active.
        XCTAssertTrue(p.isActive)
        // Act: move one more second.
        clock.advance(1)
        // Assert: now expired.
        XCTAssertEqual(p.state, .expired)
        // Assert: there is no active credential.
        XCTAssertNil(p.activeCredential)
        // Assert: using the code now reports expired.
        XCTAssertEqual(p.attempt(code: c.text), .expired)
        // new begin re-arms
        // Act: begin again with a fresh code.
        let c2 = p.begin()
        // Assert: the new code (in display form) is accepted.
        XCTAssertEqual(p.attempt(code: c2.displayString), .accepted)
    }

    // Scenario: use a correct code twice.
    // Expected: the first attempt is accepted and the policy becomes consumed; the second is not active.
    // Why it matters: a pairing code must only work once.
    func testSingleUse() {
        // Arrange: a policy with a fresh code.
        var p = PairingPolicy()
        let c = p.begin()
        // Act and assert: first attempt is accepted.
        XCTAssertEqual(p.attempt(code: c.text), .accepted)
        // Assert: the state is consumed.
        XCTAssertEqual(p.state, .consumed)
        // Assert: reuse is refused.
        XCTAssertEqual(p.attempt(code: c.text), .notActive)
    }

    // Scenario: guess wrongly five times.
    // Expected: attempts 1 to 4 are rejected with the remaining count dropping; the 5th (even a
    // malformed one) locks the policy; after that the right code no longer works. Failures recorded
    // by the handshake also count toward the lock.
    // Why it matters: limits online guessing of the code.
    func testFiveFailureLockout() {
        // Arrange: a policy with an active code.
        var p = PairingPolicy()
        let c = p.begin()
        // Four wrong guesses, each reporting how many tries are left.
        for i in 1...4 { XCTAssertEqual(p.attempt(code: "0000000000"), .rejected(remaining: 5 - i)) }
        // Fifth failure locks; a malformed code counts too.
        XCTAssertEqual(p.attempt(code: "garbage"), .locked)   // 5th failure, malformed counts too
        // Assert: the state is locked.
        XCTAssertEqual(p.state, .locked)
        // Assert: even the correct code is refused once locked.
        XCTAssertEqual(p.attempt(code: c.text), .locked)      // correct code now useless
        // Assert: no credential is available when locked.
        XCTAssertNil(p.activeCredential)
        // recordFailure path (msg3 auth failures)
        // Arrange: a second policy that gets failures reported directly.
        var q = PairingPolicy(); q.begin()
        // Four recorded failures.
        for _ in 0..<4 { _ = q.recordFailure() }
        // Assert: the fifth recorded failure locks.
        XCTAssertEqual(q.recordFailure(), .locked)
    }

    // Scenario: pair using a QR secret instead of a typed code.
    // Expected: a wrong secret is rejected with 4 tries left; the real secret is accepted.
    // Why it matters: the QR path must follow the same attempt limits as the typed path.
    func testQRAttempt() {
        // Arrange: a policy.
        var p = PairingPolicy()
        // A fake host key.
        let host = Data(repeating: 7, count: 32)
        // Act: begin QR pairing and get the payload.
        let qr = p.beginQR(hostPublicKey: host, addressHint: "h:1")
        // Assert: a 16-byte wrong secret is rejected with 4 attempts left.
        XCTAssertEqual(p.attempt(candidate: Data(repeating: 0, count: 16)), .rejected(remaining: 4))
        // Assert: the correct secret is accepted.
        XCTAssertEqual(p.attempt(candidate: qr.secret), .accepted)
    }

    // Scenario: add, update, list and revoke peers in the in-memory key store.
    // Expected: a device key is created once and reused; adding a peer with the same key updates it
    // instead of duplicating; revoking removes it.
    // Why it matters: the key store decides who counts as paired.
    func testInMemoryStoreCRUDAndRevoke() throws {
        // Arrange: an empty store.
        let s = InMemoryKeyStore()
        // Assert: no device key exists yet.
        XCTAssertNil(try s.loadDevicePrivateKey())
        // Act: load or create the key twice.
        let k1 = try s.loadOrCreateDeviceKey()
        let k2 = try s.loadOrCreateDeviceKey()
        // Assert: both calls return the same key.
        XCTAssertEqual(k1.rawRepresentation, k2.rawRepresentation)
        // Arrange: two peer records.
        let a = PairedPeerRecord(name: "iPhone", publicKey: Data(repeating: 1, count: 32), pairedAt: Date(timeIntervalSince1970: 100))
        let b = PairedPeerRecord(name: "iPad", publicKey: Data(repeating: 2, count: 32), pairedAt: Date(timeIntervalSince1970: 200))
        // Act: add both.
        try s.addPeer(a); try s.addPeer(b)
        // Assert: two peers are stored.
        XCTAssertEqual(try s.peers().count, 2)
        // Assert: the first is reported as paired.
        XCTAssertTrue(try s.isPaired(publicKey: a.publicKey))
        // Act: change the first peer's name and add it again.
        var a2 = a; a2.name = "Renamed"
        try s.addPeer(a2)
        // Assert: still two peers (an update, not a duplicate).
        XCTAssertEqual(try s.peers().count, 2)
        // Assert: the name was updated.
        XCTAssertEqual(try s.peers().first { $0.publicKey == a.publicKey }?.name, "Renamed")
        // Act: revoke the first peer.
        try s.revoke(a2)
        // Assert: it is no longer paired.
        XCTAssertFalse(try s.isPaired(publicKey: a.publicKey))
        // Assert: only the second peer remains.
        XCTAssertEqual(try s.peers(), [b])
        // Act: revoke the second by key.
        try s.revoke(publicKey: b.publicKey)
        // Assert: the list is empty.
        XCTAssertTrue(try s.peers().isEmpty)
    }

    // Scenario: encode a stored peer record as JSON.
    // Expected: the JSON does not contain a private key and has only name, public key and date.
    // Why it matters: private keys must never be written into peer records.
    func testPeerJSONHasNoPrivateKey() throws {
        // Arrange: a private key and a peer record built from its public half.
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let rec = PairedPeerRecord(name: "x", publicKey: priv.publicKey.rawRepresentation, pairedAt: Date())
        // Act: encode the record.
        let json = try JSONEncoder().encode(rec)
        // Assert: the private key bytes do not appear in the JSON.
        XCTAssertNil(json.range(of: priv.rawRepresentation))
        // Read the JSON back as a dictionary.
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        // Assert: exactly the three expected fields exist.
        XCTAssertEqual(Set(obj.keys), ["name", "publicKey", "pairedAt"])
    }

    // Scenario: derive the short check number (SAS) from a handshake hash.
    // Expected: same input gives the same output; six digits by default; a one-bit change gives a
    // different result; the digit count is adjustable; display adds a space in the middle.
    // Why it matters: both devices compare this number to detect a man in the middle.
    func testSASDeterminism() {
        // Arrange: a 32-byte sample hash.
        let h = Data((0..<32).map { UInt8($0) })
        // Act: derive the number.
        let a = SAS.derive(handshakeHash: h)
        // Assert: deterministic.
        XCTAssertEqual(a, SAS.derive(handshakeHash: h))
        // Assert: six characters.
        XCTAssertEqual(a.count, 6)
        // Assert: all are digits.
        XCTAssertTrue(a.allSatisfy(\.isNumber))
        // Flip one bit of the hash.
        var h2 = h; h2[0] ^= 1
        // Assert: the number changes.
        XCTAssertNotEqual(a, SAS.derive(handshakeHash: h2))
        // Assert: a custom length of 8 is honoured.
        XCTAssertEqual(SAS.derive(handshakeHash: h, digits: 8).count, 8)
        // Assert: display formatting splits the digits into two groups.
        XCTAssertEqual(SAS.display("012345"), "012 345")
    }

    // Scenario: store a key and a peer in the system keychain, then read and revoke them.
    // Expected: round trip works; if the keychain is unavailable in this environment the test is
    // skipped rather than failed.
    // Why it matters: this is the real storage used on devices, but some runners cannot access it.
    func testKeychainStoreRoundTrip() throws {
        // Arrange: a store under a unique service name so tests never touch real data.
        let store = KeychainKeyStore(service: "org.twu.lantern.test.\(UUID().uuidString)")
        // Probe: try a read to see whether the keychain works here.
        do {
            _ = try store.loadDevicePrivateKey()
        // If the keychain reports an error, skip the test.
        } catch KeyStoreError.keychain(let st) {
            throw XCTSkip("Keychain unavailable in this runner (OSStatus \(st))")
        }
        // Cleanup: remove everything this test stored.
        defer { try? store.removeAll() }
        // Act and assert the round trip.
        do {
            let k = try store.loadOrCreateDeviceKey()
            // Assert: the same device key comes back the second time.
            XCTAssertEqual(try store.loadOrCreateDeviceKey().rawRepresentation, k.rawRepresentation)
            // Arrange: a peer record.
            let p = PairedPeerRecord(name: "iPhone", publicKey: Data(repeating: 9, count: 32), pairedAt: Date(timeIntervalSince1970: 5))
            // Act: add it.
            try store.addPeer(p)
            // Assert: it is listed.
            XCTAssertEqual(try store.peers(), [p])
            // Act: revoke it.
            try store.revoke(p)
            // Assert: the list is empty.
            XCTAssertTrue(try store.peers().isEmpty)
        // A write failure from the keychain also causes a skip.
        } catch KeyStoreError.keychain(let st) {
            throw XCTSkip("Keychain write unavailable in this runner (OSStatus \(st))")
        }
    }
}
