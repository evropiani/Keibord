import Foundation
import Security
import KeibordCore

/// Automatic backups: the Shortcuts action "Back Up Keibord" (`BackUpKeibordIntent`, e.g. in a daily
/// automation) writes an encrypted backup of the typing data, all settings and the details into the
/// backup file the user saved once from the app (`Keibord-Backup.json`, in a folder such as iCloud
/// Drive), replacing its contents. The password is in the keychain (readable after the first unlock, so
/// a night-time automation runs while the iPhone is locked) and the file is a bookmark, so the action
/// needs no input. Cards are never backed up.
final class AutoBackup {
    static let shared = AutoBackup()
    static let fileName = "Keibord-Backup.json"

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private enum Key {
        static let file = "autoBackup.fileBookmark"
        static let location = "autoBackup.fileLocation"
        static let lastDate = "autoBackup.lastDate"
        static let lastSummary = "autoBackup.lastSummary"
        static let lastError = "autoBackup.lastError"
    }
    private static let keychainService = "com.keibord.backup-password"

    enum Failure: LocalizedError {
        case noPassword, noFile, fileUnavailable, learnedDataUnreadable, passwordNotSaved
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPassword: return "Set a backup password in Keibord first (Data › Automatic Backup)."
            case .noFile: return "Choose where to save the backup in Keibord first (Data › Automatic Backup)."
            case .fileUnavailable: return "The backup file was moved or deleted. Choose where to save it again in Keibord (Data › Automatic Backup)."
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

    /// The first backup in a temporary file, to be put in its place with the Save dialog (`setFile`).
    func makeFirstFile() throws -> URL {
        let backup = try makeBackup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName)
        try backup.data.write(to: url)
        firstSummary = backup.summary
        return url
    }
    private var firstSummary: String?

    /// Where the Save dialog put the first backup (a security-scoped URL): later backups replace it there.
    func setFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            defaults.set(try url.bookmarkData(), forKey: Key.file)
        } catch {
            throw Failure.fileUnavailable
        }
        defaults.set(url.deletingLastPathComponent().lastPathComponent, forKey: Key.location)
        recordSuccess(firstSummary ?? "")
    }

    /// The folder the backup file is in ("Keibord").
    var location: String? { defaults.data(forKey: Key.file) == nil ? nil : defaults.string(forKey: Key.location) }
    var isSetUp: Bool { hasPassword && location != nil }

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
            let backup = try makeBackup()
            try write(backup.data)
            recordSuccess(backup.summary)
            return backup.summary
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

    /// Replaces the saved backup file's contents. Only that file is accessible (not its folder), so it is
    /// written in place, not through a temporary file next to it; coordinated, so iCloud Drive and other
    /// file providers see the change.
    private func write(_ data: Data) throws {
        guard let bookmark = defaults.data(forKey: Key.file) else { throw Failure.noFile }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
              !url.path.contains("/.Trash/") else { throw Failure.fileUnavailable }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: Key.file) }
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { target in
            do { try data.write(to: target) } catch { writeError = error }
        }
        if let error = coordinatorError ?? writeError { throw Failure.writeFailed(error.localizedDescription) }
    }
}
