import Foundation

/// Contents of an export file. Each part is optional (the user picks what to export: typing data,
/// settings, details); an import changes only the parts the file contains. Payment cards are never
/// exported.
public struct BackupPayload: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var appVersion: String
    public var settings: KeibordSettings?
    /// Personal info + shortcuts.
    public var profile: PersonalProfile?
    /// Learned words, word pairs, touch model, emoji history ("typing data").
    public var userModel: UserModel?

    public init(formatVersion: Int = 1, createdAt: Date, appVersion: String, settings: KeibordSettings?, profile: PersonalProfile?, userModel: UserModel?) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.settings = settings
        self.profile = profile
        self.userModel = userModel
    }

    /// The payload with only the chosen parts (an import or export of a selection); parts it does not
    /// contain stay absent.
    public func selecting(settings: Bool, profile: Bool, userModel: Bool) -> BackupPayload {
        BackupPayload(formatVersion: formatVersion, createdAt: createdAt, appVersion: appVersion,
                      settings: settings ? self.settings : nil, profile: profile ? self.profile : nil,
                      userModel: userModel ? self.userModel : nil)
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, createdAt, appVersion, settings, profile, userModel }

    /// Tolerant like every persisted model; only a payload without any data is rejected.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.settings) || c.contains(.userModel) || c.contains(.profile) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Backup payload without data"))
        }
        formatVersion = c.value(.formatVersion, default: 1)
        createdAt = c.value(.createdAt, default: Date(timeIntervalSince1970: 0))
        appVersion = c.value(.appVersion, default: "")
        // A part that is present but damaged decodes as empty (as before); a missing part stays nil.
        settings = c.contains(.settings) ? c.value(.settings, default: KeibordSettings()) : nil
        profile = c.optionalValue(.profile, as: PersonalProfile.self)
        userModel = c.contains(.userModel) ? c.value(.userModel, default: UserModel()) : nil
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

extension BackupError: CustomStringConvertible, LocalizedError {
    /// A message for the user (also used when the error is interpolated into a string).
    public var description: String {
        switch self {
        case .notAKeibordBackup: return "This file is not a Keibord backup."
        case .unsupportedVersion(let v): return "This backup was made by a newer version of Keibord (format \(v)). Update Keibord to import it."
        case .passwordRequired: return "This backup is encrypted. Enter its password."
        case .wrongPassword: return "Wrong password."
        case .corrupted(let detail): return "The backup file is damaged (\(detail))."
        }
    }

    public var errorDescription: String? { description }
}

/// How an imported backup is applied.
public enum ImportMode: String, Codable, CaseIterable, Sendable {
    /// Combine learned data with what is on this device; imported settings replace current ones.
    case merge
    /// Replace everything on this device with the backup.
    case replace
}
