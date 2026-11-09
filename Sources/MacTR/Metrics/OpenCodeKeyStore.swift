// OpenCodeKeyStore.swift — encrypted-at-rest storage for the OpenCode Zen API key
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
// different, throwaway domain there):
//   opencode.apiKey.payload   Data    salt(16B) || AES.GCM sealedBox.combined
//   opencode.apiKey.md5       String  lowercase hex MD5 of the trimmed key (fingerprint)
//   opencode.apiKey.revision  Int     bumped on every set/clear (drives refreshes)
//   opencode.kdf.secret       Data    32-byte random KDF secret, generated lazily once
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

enum OpenCodeKeyStore {

    // MARK: - Keys

    private static let suiteName = "com.beret21.MacTR"
    private static let payloadKey = "opencode.apiKey.payload"
    private static let fingerprintKey = "opencode.apiKey.md5"
    private static let revisionKey = "opencode.apiKey.revision"
    private static let secretKey = "opencode.kdf.secret"

    private static let saltByteCount = 16
    private static let secretByteCount = 32
    private static let fingerprintLength = 32

    /// Serialises reads/writes: the metrics loop decrypts from a background queue
    /// while the settings UI may be saving a new key on the main thread.
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

    // MARK: - Public API

    /// True when a payload exists AND decrypts to a non-empty key.
    static var isConfigured: Bool {
        apiKey() != nil
    }

    /// Bumped on every successful set/clear; lets the usage client detect key edits.
    static var revision: Int {
        lock.lock()
        defer { lock.unlock() }
        return defaults.integer(forKey: revisionKey)
    }

    /// 32 lowercase hex chars — a stable, non-reversible identifier the settings UI
    /// can show instead of the key itself. Nil when no key is stored.
    static var fingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = defaults.string(forKey: fingerprintKey) else { return nil }
        let hex = raw.lowercased()
        guard hex.count == fingerprintLength,
              hex.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return hex
    }

    /// Decrypts and trims the stored key. Any failure (missing payload, corrupt
    /// ciphertext, changed KDF secret) reads as "not configured" — never throws,
    /// never logs.
    static func apiKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let payload = defaults.data(forKey: payloadKey),
              payload.count > saltByteCount,
              let secret = storedSecretLocked()
        else { return nil }

        let salt = payload.prefix(saltByteCount)
        let combined = payload.dropFirst(saltByteCount)
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
    static func setKey(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let plaintext = trimmed.data(using: .utf8) else { return false }

        lock.lock()
        defer { lock.unlock() }

        guard let secret = storedSecretLocked() else { return false }

        var salt = Data(count: saltByteCount)
        let randomStatus = salt.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltByteCount, base)
        }
        guard randomStatus == errSecSuccess else { return false }

        let key = SymmetricKey(data: Data(Insecure.MD5.hash(data: kdfInput(secret, salt))))
        guard let sealed = try? AES.GCM.seal(plaintext, using: key),
              let combined = sealed.combined
        else { return false }

        var payload = salt
        payload.append(combined)

        let defaults = defaults
        defaults.set(payload, forKey: payloadKey)
        defaults.set(fingerprintHex(trimmed), forKey: fingerprintKey)
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
        // Push to disk promptly so a separate CLI process sees the new key without
        // waiting for the next periodic flush.
        defaults.synchronize()
        return true
    }

    /// Removes the payload + fingerprint and bumps the revision so the usage client
    /// drops its cached numbers. The KDF secret is intentionally retained.
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        let defaults = defaults
        defaults.removeObject(forKey: payloadKey)
        defaults.removeObject(forKey: fingerprintKey)
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
        defaults.synchronize()
    }

    // MARK: - Internals (always called with `lock` held)

    /// Key material for the AES cipher: MD5 over secret || salt.
    private static func kdfInput(_ secret: Data, _ salt: Data) -> Data {
        var material = secret
        material.append(salt)
        return material
    }

    /// Reads the KDF secret, generating a 32-byte random one on first use. Secret
    /// rotation is not attempted when the stored value has the wrong length — that
    /// would silently invalidate an existing payload; callers treat it as "not
    /// configured" instead, which prompts the user to re-enter the key.
    private static func storedSecretLocked() -> Data? {
        let defaults = defaults
        if let existing = defaults.data(forKey: secretKey), existing.count == secretByteCount {
            return existing
        }
        var secret = Data(count: secretByteCount)
        let status = secret.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, secretByteCount, base)
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
