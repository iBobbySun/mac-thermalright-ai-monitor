// AgentKeyStore.swift — encrypted-at-rest storage for the API-backed agents' keys
//
// Threat model: this is LOCAL OBFUSCATION, not strong key protection. The KDF
// secret lives in the same UserDefaults domain as the ciphertext, so anything
// that can read this defaults plist can also decrypt the key. The goal is
// narrower: the API key is never stored as plaintext on disk, never logged, and
// never exposed by casual `defaults read` / plist inspection.
//
// Storage — UserDefaults(suiteName: "com.beret21.MacTR"). That suite is the same
// persisted domain the GUI app writes (its bundle id), and it also works from the
// CLI binary, which has no bundle identity (plain `.standard` would land in a
// different, throwaway domain there). Every agent gets its own namespace, so a
// key edit for one agent never touches another:
//   <agent>.apiKey.payload   Data    salt(16B) || AES.GCM sealedBox.combined
//   <agent>.apiKey.md5       String  lowercase hex MD5 of the trimmed key (fingerprint)
//   <agent>.apiKey.revision  Int     bumped on every set/clear (drives refreshes)
//   <agent>.kdf.secret       Data    32-byte random KDF secret, generated lazily once
//
// `<agent>` is the `APIKeyAgent` raw value ("opencode", "ollama"), so the keys
// written by the pre-generalisation OpenCode store keep their exact spelling and
// no migration (or re-entry) is needed.
//
// Cipher: AES-128-GCM under key = MD5(kdfSecret || salt). MD5 is used here only as
// a fixed-size key-derivation hash, never as an authentication primitive — GCM
// supplies integrity via its tag. `sealedBox.combined` already carries the nonce,
// ciphertext and tag, so the payload is just salt + combined.
//
// The KDF secret is deliberately NOT removed by clear(): it is device-local
// material, and keeping it means editing/clearing a key never re-keys the store.

import CryptoKit
import Foundation
import Security

// MARK: - Namespaces

/// Agents whose credentials are an API key rather than local session transcripts.
enum APIKeyAgent: String, CaseIterable, Sendable {
    case opencode
    case ollama
}

// MARK: - Store

struct AgentKeyStore: Sendable {

    let agent: APIKeyAgent

    static let openCode = AgentKeyStore(agent: .opencode)
    static let ollama = AgentKeyStore(agent: .ollama)

    // MARK: Constants

    private static let suiteName = "com.beret21.MacTR"
    private static let saltByteCount = 16
    private static let secretByteCount = 32
    private static let fingerprintLength = 32

    /// Serialises reads/writes across every namespace: the metrics loop decrypts
    /// from a background queue while the settings UI may be saving a new key on
    /// the main thread. One lock (not one per agent) keeps the shared defaults
    /// domain single-writer.
    private static let lock = NSLock()

    private static var defaults: UserDefaults {
        // Handing `UserDefaults(suiteName:)` the app's OWN bundle id makes macOS log
        // "Using your own bundle identifier as an NSUserDefaults suite name does not
        // make sense" and leaves the behavior undefined, even though reads happen to
        // work today. In that case `.standard` already IS the com.beret21.MacTR domain,
        // so use it. The suite branch still matters for the raw SwiftPM debug binary,
        // which has no bundle identity and would otherwise read a throwaway domain.
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: Defaults keys

    private var payloadKey: String { "\(agent.rawValue).apiKey.payload" }
    private var fingerprintKey: String { "\(agent.rawValue).apiKey.md5" }
    private var revisionKey: String { "\(agent.rawValue).apiKey.revision" }
    private var secretKey: String { "\(agent.rawValue).kdf.secret" }

    // MARK: Public API

    /// True when a payload exists AND decrypts to a non-empty key.
    var isConfigured: Bool {
        apiKey() != nil
    }

    /// Bumped on every successful set/clear; lets the usage client detect key edits.
    var revision: Int {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.defaults.integer(forKey: revisionKey)
    }

    /// 32 lowercase hex chars — a stable, non-reversible identifier the settings UI
    /// can show instead of the key itself. Nil when no key is stored.
    var fingerprint: String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let raw = Self.defaults.string(forKey: fingerprintKey) else { return nil }
        let hex = raw.lowercased()
        guard hex.count == Self.fingerprintLength,
              hex.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return hex
    }

    /// Decrypts and trims the stored key. Any failure (missing payload, corrupt
    /// ciphertext, changed KDF secret) reads as "not configured" — never throws,
    /// never logs.
    func apiKey() -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let payload = Self.defaults.data(forKey: payloadKey),
              payload.count > Self.saltByteCount,
              let secret = storedSecretLocked()
        else { return nil }

        let salt = payload.prefix(Self.saltByteCount)
        let combined = payload.dropFirst(Self.saltByteCount)
        let key = SymmetricKey(data: Data(Insecure.MD5.hash(data: kdfInput(secret, salt))))

        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(box, using: key),
              let decoded = String(data: plaintext, encoding: .utf8)
        else { return nil }

        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Encrypts and stores `raw`. Whitespace-only input is rejected without writing
    /// anything (so a stray Enter in the settings field cannot wipe a working key).
    @discardableResult
    func setKey(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let plaintext = trimmed.data(using: .utf8) else { return false }

        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard let secret = storedSecretLocked() else { return false }

        var salt = Data(count: Self.saltByteCount)
        let randomStatus = salt.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, Self.saltByteCount, base)
        }
        guard randomStatus == errSecSuccess else { return false }

        let key = SymmetricKey(data: Data(Insecure.MD5.hash(data: kdfInput(secret, salt))))
        guard let sealed = try? AES.GCM.seal(plaintext, using: key),
              let combined = sealed.combined
        else { return false }

        var payload = salt
        payload.append(combined)

        let defaults = Self.defaults
        defaults.set(payload, forKey: payloadKey)
        defaults.set(Self.fingerprintHex(trimmed), forKey: fingerprintKey)
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
        // Push to disk promptly so a separate CLI process sees the new key without
        // waiting for the next periodic flush.
        defaults.synchronize()
        return true
    }

    /// Removes the payload + fingerprint and bumps the revision so the usage client
    /// drops its cached numbers. The KDF secret is intentionally retained.
    func clear() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let defaults = Self.defaults
        defaults.removeObject(forKey: payloadKey)
        defaults.removeObject(forKey: fingerprintKey)
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
        defaults.synchronize()
    }

    // MARK: - Internals (always called with `lock` held)

    /// Key material for the AES cipher: MD5 over secret || salt.
    private func kdfInput(_ secret: Data, _ salt: Data) -> Data {
        var material = secret
        material.append(salt)
        return material
    }

    /// Reads the KDF secret, generating a 32-byte random one on first use. Secret
    /// rotation is not attempted when the stored value has the wrong length — that
    /// would silently invalidate an existing payload; callers treat it as "not
    /// configured" instead, which prompts the user to re-enter the key.
    private func storedSecretLocked() -> Data? {
        let defaults = Self.defaults
        if let existing = defaults.data(forKey: secretKey),
           existing.count == Self.secretByteCount {
            return existing
        }
        var secret = Data(count: Self.secretByteCount)
        let status = secret.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, Self.secretByteCount, base)
        }
        guard status == errSecSuccess else { return nil }
        defaults.set(secret, forKey: secretKey)
        defaults.synchronize()
        return secret
    }

    private static func fingerprintHex(_ value: String) -> String {
        Data(Insecure.MD5.hash(data: Data(value.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
