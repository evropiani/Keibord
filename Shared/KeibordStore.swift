import Foundation
import KeibordCore

/// JSON files shared between the app and the keyboard (in the app-group container).
///
/// Writes are atomic and coordinated (`NSFileCoordinator`) so the other process never sees a half-written
/// file. Files that both processes change (`user-model.json`, `cards.json`) are only changed through
/// coordinated read-modify-write cycles (`update`, `updateUserModel`, `flush`), so neither process can
/// overwrite what the other one just wrote.
final class KeibordStore {
    static let shared = KeibordStore()

    let directory: URL
    /// False when the app group is unavailable and each process uses its own container.
    let isShared: Bool
    /// One lock per file: serialises read-modify-write cycles between threads of this process (the file
    /// coordinator serialises them between processes) without making unrelated files wait for each other.
    /// Not reentrant: never call back into the store from a `transform` closure.
    private let locks: [KeibordFile: NSLock] = Dictionary(uniqueKeysWithValues: KeibordFile.allCases.map { ($0, NSLock()) })

    private init() {
        if let container = AppGroup.containerURL {
            directory = container.appendingPathComponent("Keibord", isDirectory: true)
            isShared = true
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            directory = base.appendingPathComponent("Keibord", isDirectory: true)
            isShared = false
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ file: KeibordFile) -> URL { directory.appendingPathComponent(file.rawValue) }

    func modificationDate(of file: KeibordFile) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(file).path))?[.modificationDate] as? Date
    }

    private func withLock<R>(_ file: KeibordFile, _ body: () throws -> R) rethrows -> R {
        guard let lock = locks[file] else { return try body() }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Generic coordinated IO

    func readData(_ file: KeibordFile) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url(file), options: [], error: &error) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    /// Replaces the file atomically. Returns false when nothing was written.
    @discardableResult
    func writeData(_ data: Data, _ file: KeibordFile) -> Bool {
        withLock(file) { () -> Bool in
            var ok = false
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url(file), options: .forReplacing, error: &error) { u in
                ok = Self.atomicWrite(data, to: u)
            }
            return ok
        }
    }

    func read<T: Decodable>(_ type: T.Type, _ file: KeibordFile) -> T? {
        guard let data = readData(file) else { return nil }
        return try? KeibordJSON.decoder().decode(T.self, from: data)
    }

    @discardableResult
    func write<T: Encodable>(_ value: T, _ file: KeibordFile) -> Bool {
        guard let data = try? KeibordJSON.encoder().encode(value) else { return false }
        return writeData(data, file)
    }

    /// Coordinated read → transform → write of one JSON file, atomic with respect to the other process
    /// and to other threads. Returns the value that was written, or nil when nothing was written:
    /// the coordinator failed, the file exists but could not be read (never overwrite data that could
    /// not be seen), or the write failed. A file that is readable but not decodable is moved aside
    /// (`<name>.corrupt-<time>.json`, kept for recovery) and `defaultValue` is used instead.
    @discardableResult
    func update<T: Codable>(_ type: T.Type, _ file: KeibordFile, default defaultValue: @autoclosure () -> T,
                            _ transform: (inout T) -> Void) -> T? {
        withLock(file) { () -> T? in
            var result: T?
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url(file), options: .forMerging, error: &error) { u in
                var value: T
                switch Self.load(T.self, at: u) {
                case .missing:
                    value = defaultValue()
                case .unreadable:
                    return
                case .corrupt:
                    guard self.moveAside(u, file: file) else { return }
                    value = defaultValue()
                case .loaded(let loaded):
                    value = loaded
                }
                transform(&value)
                guard let data = try? KeibordJSON.encoder().encode(value), Self.atomicWrite(data, to: u) else { return }
                result = value
            }
            return result
        }
    }

    private enum LoadResult<T> {
        case missing, unreadable, corrupt
        case loaded(T)
    }

    private static func load<T: Decodable>(_ type: T.Type, at url: URL) -> LoadResult<T> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // A file that exists but cannot be read (data protection, I/O error …) is not an empty file.
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        guard let value = try? KeibordJSON.decoder().decode(T.self, from: data) else { return .corrupt }
        return .loaded(value)
    }

    private static func atomicWrite(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    private func moveAside(_ fileURL: URL, file: KeibordFile) -> Bool {
        let base = (file.rawValue as NSString).deletingPathExtension
        let stamp = Int(Date().timeIntervalSince1970)
        var aside = directory.appendingPathComponent("\(base).corrupt-\(stamp).json")
        if FileManager.default.fileExists(atPath: aside.path) {
            aside = directory.appendingPathComponent("\(base).corrupt-\(stamp)-\(UUID().uuidString).json")
        }
        return (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil
    }

    /// Copies of unreadable files kept by `update` (they may contain learned words or personal data).
    func removeCorruptCopies() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.contains(".corrupt-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Typed accessors

    func loadSettings() -> KeibordSettings { read(KeibordSettings.self, .settings) ?? KeibordSettings() }
    @discardableResult func saveSettings(_ s: KeibordSettings) -> Bool { write(s, .settings) }

    func loadProfile() -> PersonalProfile { read(PersonalProfile.self, .profile) ?? PersonalProfile() }
    @discardableResult func saveProfile(_ p: PersonalProfile) -> Bool { write(p, .profile) }

    func loadState() -> KeyboardRuntimeState { read(KeyboardRuntimeState.self, .state) ?? KeyboardRuntimeState() }
    @discardableResult func saveState(_ s: KeyboardRuntimeState) -> Bool { write(s, .state) }

    /// Read-only: an unreadable file yields an empty model and is left untouched (the next
    /// `updateUserModel`/`flush` moves it aside, so learning continues in a fresh file).
    func loadUserModel() -> UserModel {
        read(UserModel.self, .userModel) ?? UserModel()
    }

    /// Replaces the learned data (reset / import replace). Learning edits go through `updateUserModel`.
    @discardableResult func saveUserModel(_ m: UserModel) -> Bool { write(m, .userModel) }

    /// Applies keyboard-side learning increments to the file (read → apply → prune → write).
    /// Returns false when nothing was written (e.g. no Full Access, unreadable file).
    @discardableResult
    func flush(_ delta: UserModelDelta) -> Bool {
        guard !delta.isEmpty else { return true }
        return updateUserModel { $0.apply(delta) } != nil
    }

    /// Coordinated read → transform → prune → write of the learned data. Returns the model that was
    /// written, or nil when nothing was written.
    @discardableResult
    func updateUserModel(_ transform: (inout UserModel) -> Void) -> UserModel? {
        update(UserModel.self, .userModel, default: UserModel()) { model in
            transform(&model)
            model.prune()
        }
    }

    /// Deletes settings, details, learned data and cards (plus kept copies of unreadable files).
    func resetAll() {
        for file in [KeibordFile.settings, .profile, .userModel, .cards] {
            withLock(file) { () -> Void in
                var error: NSError?
                NSFileCoordinator().coordinate(writingItemAt: url(file), options: .forDeleting, error: &error) { u in
                    try? FileManager.default.removeItem(at: u)
                }
            }
        }
        removeCorruptCopies()
    }
}
