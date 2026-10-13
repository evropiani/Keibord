import Foundation

/// Reads and writes Keibord export files (optionally password-encrypted).
public enum BackupFile {
    public static let format = "keibord-backup"
    public static let version = 1

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var encrypted: Bool
        var payload: BackupPayload?
        var kdf: KDF?
        var cipher: String?
        var box: String?
    }

    private struct KDF: Codable {
        var name: String
        var iterations: Int
        var salt: String
    }

    public static func encode(_ payload: BackupPayload, password: String?, cipher: BackupCipher?, iterations: Int = 210_000) throws -> Data {
        let encoder = KeibordJSON.encoder(pretty: true)
        if let password = password, !password.isEmpty {
            guard let cipher = cipher else { throw BackupError.corrupted("No cipher available") }
            let salt = cipher.randomBytes(16)
            let key = try cipher.deriveKey(password: password, salt: salt, iterations: iterations)
            let plain = try KeibordJSON.encoder().encode(payload)
            let box = try cipher.seal(plain, key: key)
            let env = Envelope(format: format, version: version, encrypted: true, payload: nil,
                               kdf: KDF(name: "PBKDF2-SHA256", iterations: iterations, salt: salt.base64EncodedString()),
                               cipher: "AES-GCM-256", box: box.base64EncodedString())
            return try encoder.encode(env)
        }
        return try encoder.encode(Envelope(format: format, version: version, encrypted: false, payload: payload, kdf: nil, cipher: nil, box: nil))
    }

    public static func isEncrypted(_ data: Data) -> Bool {
        (try? KeibordJSON.decoder().decode(Envelope.self, from: data))?.encrypted ?? false
    }

    public static func decode(_ data: Data, password: String?, cipher: BackupCipher?) throws -> BackupPayload {
        let env: Envelope
        do {
            env = try KeibordJSON.decoder().decode(Envelope.self, from: data)
        } catch {
            throw BackupError.notAKeibordBackup
        }
        guard env.format == format else { throw BackupError.notAKeibordBackup }
        guard env.version <= version else { throw BackupError.unsupportedVersion(env.version) }
        if !env.encrypted {
            guard let payload = env.payload else { throw BackupError.corrupted("Missing payload") }
            return payload
        }
        guard let password = password, !password.isEmpty else { throw BackupError.passwordRequired }
        guard let cipher = cipher, let kdf = env.kdf, let salt = Data(base64Encoded: kdf.salt),
              let boxString = env.box, let box = Data(base64Encoded: boxString) else {
            throw BackupError.corrupted("Missing encryption parameters")
        }
        let key = try cipher.deriveKey(password: password, salt: salt, iterations: kdf.iterations)
        let plain: Data
        do {
            plain = try cipher.open(box, key: key)
        } catch {
            throw BackupError.wrongPassword
        }
        do {
            return try KeibordJSON.decoder().decode(BackupPayload.self, from: plain)
        } catch {
            throw BackupError.corrupted("Unreadable payload")
        }
    }

    /// Combines an imported payload with the current data.
    public static func apply(_ payload: BackupPayload, mode: ImportMode, to current: (settings: KeibordSettings, profile: PersonalProfile, model: UserModel)) -> (KeibordSettings, PersonalProfile, UserModel) {
        switch mode {
        case .replace:
            return (payload.settings, payload.profile ?? current.profile, payload.userModel)
        case .merge:
            var profile = current.profile
            if let imported = payload.profile {
                if profile.info.isEmpty { profile.info = imported.info }
                let existing = Set(profile.shortcuts.map { $0.shortcut.lowercased() })
                profile.shortcuts += imported.shortcuts.filter { !existing.contains($0.shortcut.lowercased()) }
            }
            var model = current.model.merged(with: payload.userModel)
            model.prune()
            return (payload.settings, profile, model)
        }
    }
}
