import Foundation

/// Contents of an export file. Payment cards are never exported.
public struct BackupPayload: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var appVersion: String
    public var settings: KeibordSettings
    /// Personal info + shortcuts (optional; the user can exclude it from an export).
    public var profile: PersonalProfile?
    public var userModel: UserModel

    public init(formatVersion: Int = 1, createdAt: Date, appVersion: String, settings: KeibordSettings, profile: PersonalProfile?, userModel: UserModel) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.settings = settings
        self.profile = profile
        self.userModel = userModel
    }
}

/// Password-based encryption used for encrypted exports. Implemented on iOS with
/// PBKDF2-SHA256 (CommonCrypto) + AES-GCM-256 (CryptoKit); tests use a fake.
public protocol BackupCipher {
    /// Derives a 32-byte key from the password.
    func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data
    /// AES-GCM seal; returns the "combined" representation (nonce ‖ ciphertext ‖ tag).
    func seal(_ plaintext: Data, key: Data) throws -> Data
    func open(_ combined: Data, key: Data) throws -> Data
    func randomBytes(_ count: Int) -> Data
}

public enum BackupError: Error, Equatable {
    case notAKeibordBackup
    case unsupportedVersion(Int)
    case passwordRequired
    case wrongPassword
    case corrupted(String)
}

/// How an imported backup is applied.
public enum ImportMode: String, Codable, CaseIterable, Sendable {
    /// Combine learned data with what is on this device; imported settings replace current ones.
    case merge
    /// Replace everything on this device with the backup.
    case replace
}
