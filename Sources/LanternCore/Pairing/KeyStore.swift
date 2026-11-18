// ==============================================================================
// Program: KeyStore.swift
// Programmer: Ethan-da-Tech-Wizard
// Course: CIS 156 / Advanced Systems
// Last Modified: November 18, 2026
// Purpose: Stores local device identity keys and trusted paired peer keys in Keychain or memory.
//          Inputs: Device keypairs and peer public identity tokens.
//          Outputs: Securely stored cryptographic keys and lookup queries.
//          Design Rationale: Uses Apple Keychain Services on iOS/macOS for secure hardware-backed
//          key protection with memory-only fallbacks for testing.
// ==============================================================================
// =====================================================================================
// KeyStore.swift
//
// PURPOSE
//   Remembers two things between app launches: this device's own long-term private key, and
//   the list of other devices it has been paired with (their public keys and names).
//
// WHO CALLS IT
//   The pairing and reconnect code ask the store for the device key (`loadOrCreateDeviceKey`),
//   save new peers after a successful pairing (`addPeer`), check `isPaired`, and `revoke` peers
//   the user removes. Tests use the in-memory version; the real apps use the Keychain version.
//
// KEY IDEAS (in plain English)
//   - A KEYCHAIN is the operating system's locked safe for secrets. Items stored there are
//     encrypted and protected by the device passcode.
//   - "This device only, never synced" means the secrets do not leave this device through iCloud.
//   - A `protocol` is a list of abilities; both stores promise the same abilities so the rest of
//     the app does not care which one it gets.
// =====================================================================================

import Foundation
import CryptoKit
import Security

// MARK: - Data types

/// Paired peer metadata. Public information only; never contains private keys.
public struct PairedPeerRecord: Codable, Sendable, Equatable {
    /// A human-friendly label for the other device.
    public var name: String
    public var publicKey: Data   // X25519, 32 bytes
    /// When pairing happened.
    public var pairedAt: Date
    public init(name: String, publicKey: Data, pairedAt: Date) {
        self.name = name; self.publicKey = publicKey; self.pairedAt = pairedAt
    }
}

/// Things that can go wrong when storing or loading keys.
public enum KeyStoreError: Error, Equatable, Sendable {
    /// The Keychain returned an error code (the raw OS status is kept for debugging).
    case keychain(OSStatus)
    /// Stored data could not be understood (damaged or the wrong format).
    case corrupt
}

// MARK: - Protocol

/// The abilities every key store provides.
public protocol KeyStore: Sendable {
    /// Returns the saved private key bytes, or nil if none was saved yet.
    func loadDevicePrivateKey() throws -> Data?
    /// Saves (or overwrites) the device private key bytes.
    func saveDevicePrivateKey(_ raw: Data) throws
    /// Lists every paired peer.
    func peers() throws -> [PairedPeerRecord]
    /// Adds, or replaces an entry with the same public key.
    func addPeer(_ peer: PairedPeerRecord) throws
    /// Removes a peer so it can no longer connect.
    func revoke(_ peer: PairedPeerRecord) throws
}

/// Extra helpers built on top of the basic abilities, shared by every store.
public extension KeyStore {
    /// Revoke by public key: finds the matching record, if any, and removes it.
    func revoke(publicKey: Data) throws {
        if let p = try peers().first(where: { $0.publicKey == publicKey }) { try revoke(p) }
    }
    /// True if a peer with this public key is in the list (compared in constant time).
    func isPaired(publicKey: Data) throws -> Bool {
        try peers().contains { constantTimeEquals($0.publicKey, publicKey) }
    }
    /// Returns the device static key, creating and storing a fresh X25519 key on first use.
    func loadOrCreateDeviceKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        // If a key was saved before, rebuild it from the stored bytes.
        if let raw = try loadDevicePrivateKey() {
            do { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) }
            catch { throw KeyStoreError.corrupt }
        }
        // First run: make a brand-new key and save it for next time.
        let k = Curve25519.KeyAgreement.PrivateKey()
        try saveDevicePrivateKey(k.rawRepresentation)
        return k
    }
}

// MARK: - JSON helpers

/// Turns a peer record into JSON text (dates as ISO-8601, keys sorted so output is stable).
private let peerEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
/// Reads JSON text back into a peer record.
private let peerDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

// MARK: - In-memory store

/// A store that keeps everything in RAM (lost when the app quits); used for tests and demos.
/// A lock makes it safe to use from several threads at once.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    /// Guards the two fields below against simultaneous access.
    private let lock = NSLock()
    private var privateKey: Data?
    private var list: [PairedPeerRecord] = []
    public init() {}

    // Each method takes the lock, does its work, and `defer` guarantees the lock is released.
    public func loadDevicePrivateKey() throws -> Data? { lock.lock(); defer { lock.unlock() }; return privateKey }
    public func saveDevicePrivateKey(_ raw: Data) throws { lock.lock(); defer { lock.unlock() }; privateKey = raw }
    public func peers() throws -> [PairedPeerRecord] { lock.lock(); defer { lock.unlock() }; return list }
    public func addPeer(_ peer: PairedPeerRecord) throws {
        lock.lock(); defer { lock.unlock() }
        // Remove any old entry for the same key first, so adding twice just replaces it.
        list.removeAll { $0.publicKey == peer.publicKey }
        list.append(peer)
    }
    public func revoke(_ peer: PairedPeerRecord) throws {
        lock.lock(); defer { lock.unlock() }
        list.removeAll { $0.publicKey == peer.publicKey }
    }
}

// MARK: - Keychain store

/// Keychain-backed store: generic-password items, this-device-only, never synced.
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    /// Groups all our items together in the Keychain.
    private let service: String
    /// Whether to use the modern "data protection" Keychain (needed on some platforms).
    private let useDataProtection: Bool
    /// The item name under which the device private key is stored.
    private let keyAccount = "device-static-private-key"
    /// Peer items are named "peer." plus a fingerprint, so they can be told apart from the device key.
    private let peerPrefix = "peer."

    public init(service: String = "org.twu.lantern", useDataProtectionKeychain: Bool = true) {
        self.service = service; self.useDataProtection = useDataProtectionKeychain
    }

    /// Builds the common search/identity dictionary for Keychain calls.
    /// Passing `account: nil` matches every item under our service.
    private func base(account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,   // a plain secret item
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,         // never sync to other devices
        ]
        if let a = account { q[kSecAttrAccount as String] = a }
        if useDataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Saves bytes under an account name: adds a new item, or updates it if it already exists.
    private func put(account: String, data: Data) throws {
        var add = base(account: account)
        add[kSecValueData as String] = data
        // Readable only while the device is unlocked, and never moved to another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var st = SecItemAdd(add as CFDictionary, nil)
        // Item already there: change its value instead.
        if st == errSecDuplicateItem {
            st = SecItemUpdate(base(account: account) as CFDictionary,
                               [kSecValueData as String: data] as CFDictionary)
        }
        guard st == errSecSuccess else { throw KeyStoreError.keychain(st) }
    }

    /// Reads the bytes stored under an account name; nil if there is no such item.
    private func get(account: String) throws -> Data? {
        var q = base(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw KeyStoreError.keychain(st) }
        return d
    }

    /// Deletes one item (or all items of the service when `account` is nil). Missing is fine.
    private func remove(account: String?) throws {
        let st = SecItemDelete(base(account: account) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw KeyStoreError.keychain(st) }
    }

    /// Item name for a peer: "peer." + hex of the SHA-256 of its public key (same key = same name).
    private func account(for key: Data) -> String {
        peerPrefix + SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    public func loadDevicePrivateKey() throws -> Data? { try get(account: keyAccount) }
    public func saveDevicePrivateKey(_ raw: Data) throws { try put(account: keyAccount, data: raw) }

    public func peers() throws -> [PairedPeerRecord] {
        // Ask for every item of our service, including its name and value.
        var q = base(account: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return [] }
        guard st == errSecSuccess, let items = out as? [[String: Any]] else { throw KeyStoreError.keychain(st) }
        var result: [PairedPeerRecord] = []
        for it in items {
            // Skip items that are not peers (such as the device key).
            guard let acct = it[kSecAttrAccount as String] as? String, acct.hasPrefix(peerPrefix),
                  let d = it[kSecValueData as String] as? Data else { continue }
            // A peer item that will not decode means damaged data.
            guard let rec = try? peerDecoder.decode(PairedPeerRecord.self, from: d) else { throw KeyStoreError.corrupt }
            result.append(rec)
        }
        // Oldest pairing first.
        return result.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func addPeer(_ peer: PairedPeerRecord) throws {
        try put(account: account(for: peer.publicKey), data: try peerEncoder.encode(peer))
    }
    public func revoke(_ peer: PairedPeerRecord) throws { try remove(account: account(for: peer.publicKey)) }

    /// Test cleanup: remove every item under this service.
    public func removeAll() throws { try remove(account: nil) }
}
