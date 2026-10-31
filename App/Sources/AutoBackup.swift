import Foundation
import Security
import KeibordCore

/// Automatic backups: the Shortcuts action "Back Up Keibord" (`BackUpKeibordIntent`, e.g. in a daily
/// automation) writes an encrypted backup of the typing data, all settings and the details as
/// `Keibord-Backup.json` into the folder chosen in the app, replacing the last one. The password is in
/// the keychain (readable after the first unlock, so a night-time automation runs while the iPhone is
/// locked) and the folder is a bookmark, so the action needs no input. Cards are never backed up.
final class AutoBackup {
    static let shared = AutoBackup()
    static let fileName = "Keibord-Backup.json"

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private enum Key {
        static let folder = "autoBackup.folderBookmark"
        static let folderName = "autoBackup.folderName"
        static let lastDate = "autoBackup.lastDate"
        static let lastSummary = "autoBackup.lastSummary"
        static let lastError = "autoBackup.lastError"
    }
    private static let keychainService = "com.keibord.backup-password"

    enum Failure: LocalizedError {
        case noPassword, noFolder, folderUnavailable, learnedDataUnreadable, passwordNotSaved
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPassword: return "Set a backup password in Keibord first (Data › Automatic Backup)."
            case .noFolder: return "Choose a backup folder in Keibord first (Data › Automatic Backup)."
            case .folderUnavailable: return "The backup folder cannot be opened. Choose it again in Keibord (Data › Automatic Backup)."
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

    /// The folder picked in the app (a security-scoped URL from the document picker).
    func setFolder(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            defaults.set(try url.bookmarkData(), forKey: Key.folder)
            defaults.set(url.lastPathComponent, forKey: Key.folderName)
        } catch {
            throw Failure.folderUnavailable
        }
    }

    var folderName: String? { defaults.data(forKey: Key.folder) == nil ? nil : defaults.string(forKey: Key.folderName) }
    var isSetUp: Bool { hasPassword && folderName != nil }

    // MARK: Status

    var lastDate: Date? { defaults.object(forKey: Key.lastDate) as? Date }
    /// "12,345 words" after a backup, or why the last one failed.
    var lastSummary: String? { defaults.string(forKey: Key.lastSummary) }
    var lastError: String? { defaults.string(forKey: Key.lastError) }

    // MARK: Backing up

    /// Writes the backup now, replacing the last one. Returns a short summary ("12,345 words").
    /// Runs off the main thread (the encryption takes a moment).
    @discardableResult
    func run() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        do {
            let summary = try write()
            defaults.set(Date(), forKey: Key.lastDate)
            defaults.set(summary, forKey: Key.lastSummary)
            defaults.removeObject(forKey: Key.lastError)
            return summary
        } catch {
            defaults.set(error.localizedDescription, forKey: Key.lastError)
            throw error
        }
    }

    private func write() throws -> String {
        guard let password = readPassword() else { throw Failure.noPassword }
        guard let bookmark = defaults.data(forKey: Key.folder) else { throw Failure.noFolder }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { throw Failure.folderUnavailable }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? folder.bookmarkData() { defaults.set(fresh, forKey: Key.folder) }

        let store = KeibordStore.shared
        // Never back up an empty model in place of learned data that merely cannot be read now.
        guard let userModel = store.loadUserModelIfReadable() else { throw Failure.learnedDataUnreadable }
        let payload = BackupPayload(createdAt: Date(), appVersion: KeibordVersion.display, settings: store.loadSettings(),
                                    profile: store.loadProfile(), userModel: userModel)
        let data = try BackupFile.encode(payload, password: password, cipher: PasswordBackupCipher())

        // Coordinated, so iCloud Drive and other file providers see one whole file replacing the old one.
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(Self.fileName), options: .forReplacing,
                                       error: &coordinatorError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinatorError ?? writeError { throw Failure.writeFailed(error.localizedDescription) }
        return "\(userModel.words.count.formatted()) words"
    }
}
