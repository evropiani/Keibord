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
    /// Smallest possible AES-GCM "combined" box: 12-byte nonce + 16-byte tag (empty plaintext).
    static let minimumBoxSize = 28

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

    /// Whether `decode` needs a password for this file. False for anything this version cannot read
    /// (not a backup, or from a newer version) so no password is asked for before the error is shown.
    public static func isEncrypted(_ data: Data) -> Bool {
        guard let env = try? KeibordJSON.decoder().decode(ParsedEnvelope.self, from: data), env.isKeibordBackup, !env.isNewer else { return false }
        return env.isEncrypted
    }

    /// Decodes an export file.
    /// * `notAKeibordBackup`: not JSON or not a Keibord export (format marker missing)
    /// * `unsupportedVersion`: written by a newer Keibord
    /// * `passwordRequired` / `wrongPassword`: encrypted and no or the wrong password
    /// * `corrupted`: a Keibord export whose content is damaged or cut short
    public static func decode(_ data: Data, password: String?, cipher: BackupCipher?) throws -> BackupPayload {
        let decoder = KeibordJSON.decoder()
        let parsed = try? decoder.decode(ParsedEnvelope.self, from: data)
        guard let env = parsed, env.isKeibordBackup else {
            if parsed == nil, looksLikeCutShortExport(data) { throw BackupError.corrupted("Incomplete file") }
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
        // Shorter than nonce + tag: no password can open it, so do not report a wrong password.
        guard box.count >= minimumBoxSize else { throw BackupError.corrupted("Truncated encrypted data") }
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

    /// Whether data that is no valid JSON is a Keibord export cut short (an incomplete download or
    /// copy), so it is reported as damaged instead of as a foreign file: it contains the format marker,
    /// or it starts with the "box" key that opens an encrypted export (keys are sorted, so the marker
    /// only follows the encrypted data).
    static func looksLikeCutShortExport(_ data: Data) -> Bool {
        if data.range(of: Data("\"\(format)\"".utf8)) != nil { return true }
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
        let head = data.prefix(64).drop(while: isSpace)
        guard head.first == UInt8(ascii: "{") else { return false }
        return head.dropFirst().drop(while: isSpace).starts(with: Array("\"box\"".utf8))
    }

    /// Combines an imported payload with the current data. Parts the backup does not contain stay as
    /// they are (a settings-only export never touches the learned data, and the other way round).
    /// * `.replace`: settings, details and learned data come from the backup.
    /// * `.merge`: imported settings replace the current ones; details already on this device are kept
    ///   and only empty fields are filled; shortcuts are added unless their shortcut exists already;
    ///   learned data is summed (`UserModel.merged(with:)`).
    /// Imported learned data is pruned to the usual limits.
    public static func apply(_ payload: BackupPayload, mode: ImportMode, to current: (settings: KeibordSettings, profile: PersonalProfile, model: UserModel)) -> (KeibordSettings, PersonalProfile, UserModel) {
        let settings = payload.settings ?? current.settings
        switch mode {
        case .replace:
            guard let imported = payload.userModel else { return (settings, payload.profile ?? current.profile, current.model) }
            // Merged into an empty model so the imported data is cleaned up the same way: no learned
            // words or word pairs of blocked words, no unused entries.
            var model = UserModel().merged(with: imported)
            model.prune()
            return (settings, payload.profile ?? current.profile, model)
        case .merge:
            let profile = payload.profile.map { current.profile.merged(with: $0) } ?? current.profile
            guard let imported = payload.userModel else { return (settings, profile, current.model) }
            var model = current.model.merged(with: imported)
            model.prune()
            return (settings, profile, model)
        }
    }
}
