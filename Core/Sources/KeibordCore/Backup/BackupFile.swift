import Foundation

/// Reads and writes Keibord export files (optionally password-encrypted).
public enum BackupFile {
    public static let format = "keibord-backup"
    public static let version = 1
    public static let kdfName = "PBKDF2-SHA256"
    public static let cipherName = "AES-GCM-256"
    /// Iteration counts accepted when decoding. Bounds a damaged or hostile file: the iOS cipher
    /// converts the count to `UInt32` (a negative value would crash) and huge counts would hang.
    public static let acceptedIterations: ClosedRange<Int> = 1...10_000_000

    /// The envelope as written by `encode`.
    private struct Envelope: Encodable {
        var format: String
        var version: Int
        var encrypted: Bool
        var payload: BackupPayload?
        var kdf: KDF?
        var cipher: String?
        var box: String?
    }

    /// The envelope as read by `decode`, in one pass and tolerantly: the format marker and version are
    /// checked first, and the payload is only decoded for a file this version can read (so a newer
    /// version is reported as such even if its payload has a different structure).
    private struct ParsedEnvelope: Decodable {
        var format: String?
        var version: Int?
        var encrypted: Bool?
        var payload: BackupPayload?
        var kdf: KDF?
        var cipher: String?
        var box: String?

        private enum CodingKeys: String, CodingKey { case format, version, encrypted, payload, kdf, cipher, box }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = c.optionalValue(.format, as: String.self)
            version = c.optionalValue(.version, as: Int.self)
            encrypted = c.optionalValue(.encrypted, as: Bool.self)
            kdf = c.optionalValue(.kdf, as: KDF.self)
            cipher = c.optionalValue(.cipher, as: String.self)
            box = c.optionalValue(.box, as: String.self)
            guard isKeibordBackup, !isNewer, !isEncrypted else { return }
            payload = c.optionalValue(.payload, as: BackupPayload.self)
        }

        var isKeibordBackup: Bool { format == BackupFile.format && version != nil }
        var isNewer: Bool { (version ?? 0) > BackupFile.version }
        var isEncrypted: Bool { encrypted ?? (box != nil) }
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
            guard acceptedIterations ~= iterations else { throw BackupError.corrupted("Invalid iteration count") }
            let salt = cipher.randomBytes(16)
            let key = try cipher.deriveKey(password: password, salt: salt, iterations: iterations)
            let plain = try KeibordJSON.encoder().encode(payload)
            let box = try cipher.seal(plain, key: key)
            let env = Envelope(format: format, version: version, encrypted: true, payload: nil,
                               kdf: KDF(name: kdfName, iterations: iterations, salt: salt.base64EncodedString()),
                               cipher: cipherName, box: box.base64EncodedString())
            return try encoder.encode(env)
        }
        return try encoder.encode(Envelope(format: format, version: version, encrypted: false, payload: payload, kdf: nil, cipher: nil, box: nil))
    }

    public static func isEncrypted(_ data: Data) -> Bool {
        guard let env = try? KeibordJSON.decoder().decode(ParsedEnvelope.self, from: data), env.isKeibordBackup else { return false }
        return env.isEncrypted
    }

    /// Decodes an export file.
    /// * `notAKeibordBackup`: not JSON or not a Keibord export (format marker missing)
    /// * `unsupportedVersion`: written by a newer Keibord
    /// * `passwordRequired` / `wrongPassword`: encrypted and no or the wrong password
    /// * `corrupted`: a Keibord export whose content is damaged
    public static func decode(_ data: Data, password: String?, cipher: BackupCipher?) throws -> BackupPayload {
        let decoder = KeibordJSON.decoder()
        guard let env = try? decoder.decode(ParsedEnvelope.self, from: data), env.isKeibordBackup else {
            throw BackupError.notAKeibordBackup
        }
        if let v = env.version, env.isNewer { throw BackupError.unsupportedVersion(v) }
        if !env.isEncrypted {
            guard let payload = env.payload else { throw BackupError.corrupted("Missing payload") }
            return payload
        }
        guard let password = password, !password.isEmpty else { throw BackupError.passwordRequired }
        guard let cipher = cipher, let kdf = env.kdf, let salt = Data(base64Encoded: kdf.salt), !salt.isEmpty,
              let boxString = env.box, let box = Data(base64Encoded: boxString), !box.isEmpty else {
            throw BackupError.corrupted("Missing encryption parameters")
        }
        guard kdf.name == kdfName, env.cipher.map({ $0 == cipherName }) ?? true else {
            throw BackupError.corrupted("Unsupported encryption")
        }
        guard acceptedIterations ~= kdf.iterations else { throw BackupError.corrupted("Invalid iteration count") }
        let key = try cipher.deriveKey(password: password, salt: salt, iterations: kdf.iterations)
        let plain: Data
        do {
            plain = try cipher.open(box, key: key)
        } catch {
            throw BackupError.wrongPassword
        }
        do {
            return try decoder.decode(BackupPayload.self, from: plain)
        } catch {
            throw BackupError.corrupted("Unreadable payload")
        }
    }

    /// Combines an imported payload with the current data.
    /// * `.replace`: settings and learned data come from the backup; the profile too unless the backup
    ///   was exported without it.
    /// * `.merge`: imported settings replace the current ones; details already on this device are kept
    ///   and only empty fields are filled; shortcuts are added unless their shortcut exists already;
    ///   learned data is summed (`UserModel.merged(with:)`).
    /// The resulting model is pruned to the usual limits.
    public static func apply(_ payload: BackupPayload, mode: ImportMode, to current: (settings: KeibordSettings, profile: PersonalProfile, model: UserModel)) -> (KeibordSettings, PersonalProfile, UserModel) {
        switch mode {
        case .replace:
            var model = payload.userModel
            model.prune()
            return (payload.settings, payload.profile ?? current.profile, model)
        case .merge:
            let profile = payload.profile.map { current.profile.merged(with: $0) } ?? current.profile
            var model = current.model.merged(with: payload.userModel)
            model.prune()
            return (payload.settings, profile, model)
        }
    }
}
