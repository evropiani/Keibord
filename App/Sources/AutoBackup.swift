import Foundation
import Security
import KeibordCore

/// Automatic backups: the Shortcuts action "Back Up Keibord" (`BackUpKeibordIntent`, e.g. in a daily
/// automation) writes an encrypted backup of the typing data, all settings and the details as
/// `Keibord-Backup.json` into the app's Documents folder (Files: On My iPhone › Keibord), replacing the
/// last one, and hands the file to Shortcuts (a "Save File" after it can keep a copy in iCloud Drive).
/// Places outside the app failed on the user's iPhone: a picked folder ignored Open (1.0.27) and a
/// bookmark of a saved file did not resolve (1.0.28); the app's own folder needs no permission. The
/// password is in the keychain (readable after the first unlock, so a night-time automation runs while
/// the iPhone is locked), so the action needs no input. Cards are never backed up.
final class AutoBackup {
    static let shared = AutoBackup()
    static let fileName = "Keibord-Backup.json"

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private enum Key {
        static let lastDate = "autoBackup.lastDate"
        static let lastSummary = "autoBackup.lastSummary"
        static let lastError = "autoBackup.lastError"
    }
    private static let keychainService = "com.keibord.backup-password"

    enum Failure: LocalizedError {
        case noPassword, learnedDataUnreadable, passwordNotSaved
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPassword: return "Set a backup password in Keibord first (Data › Automatic Backup)."
            case .learnedDataUnreadable: return "The learned words cannot be read right now. Unlock your iPhone and try again."
            case .passwordNotSaved: return "The password could not be saved on this iPhone."
            case .writeFailed(let reason): return "The backup could not be written: \(reason)"
            }
        }
    }

    // MARK: Setup

    var hasPassword: Bool { readPassword() != nil }

    func setPassword(_ password: String) throws {
        var query = Self.keychainQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw Failure.passwordNotSaved }
    }

    private func readPassword() -> String? {
        var query = Self.keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return password
    }

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "auto-backup"]
    }

    /// The backup file: in the app's Documents folder, which Files shows as On My iPhone › Keibord.
    var fileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(Self.fileName)
    }

    var isSetUp: Bool { hasPassword }

    // MARK: Status

    var lastDate: Date? { defaults.object(forKey: Key.lastDate) as? Date }
    /// "12,345 words" after a backup, or why the last one failed.
    var lastSummary: String? { defaults.string(forKey: Key.lastSummary) }
    var lastError: String? { defaults.string(forKey: Key.lastError) }

    // MARK: Backing up

    /// Writes the backup now, replacing the last one. Returns the backup and a short summary
    /// ("12,345 words"). Runs off the main thread (the encryption takes a moment).
    @discardableResult
    func run() throws -> (data: Data, summary: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let backup = try makeBackup()
            do {
                try backup.data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                throw Failure.writeFailed(error.localizedDescription)
            }
            recordSuccess(backup.summary)
            return backup
        } catch {
            defaults.set(error.localizedDescription, forKey: Key.lastError)
            throw error
        }
    }

    private func recordSuccess(_ summary: String) {
        defaults.set(Date(), forKey: Key.lastDate)
        defaults.set(summary, forKey: Key.lastSummary)
        defaults.removeObject(forKey: Key.lastError)
    }

    private func makeBackup() throws -> (data: Data, summary: String) {
        guard let password = readPassword() else { throw Failure.noPassword }
        let store = KeibordStore.shared
        // Never back up an empty model in place of learned data that merely cannot be read now.
        guard let userModel = store.loadUserModelIfReadable() else { throw Failure.learnedDataUnreadable }
        let payload = BackupPayload(createdAt: Date(), appVersion: KeibordVersion.display, settings: store.loadSettings(),
                                    profile: store.loadProfile(), userModel: userModel)
        let data = try BackupFile.encode(payload, password: password, cipher: PasswordBackupCipher())
        return (data, "\(userModel.words.count.formatted()) words")
    }
}
