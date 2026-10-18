import Foundation
import KeibordCore

/// JSON files shared between the app and the keyboard (in the app-group container).
final class KeibordStore {
    static let shared = KeibordStore()

    let directory: URL
    /// False when the app group is unavailable and each process uses its own container.
    let isShared: Bool
    private let lock = NSLock()

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

    // MARK: Generic coordinated IO

    func readData(_ file: KeibordFile) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url(file), options: [], error: &error) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    func writeData(_ data: Data, _ file: KeibordFile) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url(file), options: .forReplacing, error: &error) { u in
            try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func read<T: Decodable>(_ type: T.Type, _ file: KeibordFile) -> T? {
        guard let data = readData(file) else { return nil }
        return try? KeibordJSON.decoder().decode(T.self, from: data)
    }

    func write<T: Encodable>(_ value: T, _ file: KeibordFile) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? KeibordJSON.encoder().encode(value) else { return }
        writeData(data, file)
    }

    // MARK: Typed accessors

    func loadSettings() -> KeibordSettings { read(KeibordSettings.self, .settings) ?? KeibordSettings() }
    func saveSettings(_ s: KeibordSettings) { write(s, .settings) }

    func loadProfile() -> PersonalProfile { read(PersonalProfile.self, .profile) ?? PersonalProfile() }
    func saveProfile(_ p: PersonalProfile) { write(p, .profile) }

    func loadState() -> KeyboardRuntimeState { read(KeyboardRuntimeState.self, .state) ?? KeyboardRuntimeState() }
    func saveState(_ s: KeyboardRuntimeState) { write(s, .state) }

    func loadUserModel() -> UserModel {
        guard let data = readData(.userModel) else { return UserModel() }
        if let model = try? KeibordJSON.decoder().decode(UserModel.self, from: data) { return model }
        // Never overwrite unreadable learning data: keep a copy aside.
        let aside = directory.appendingPathComponent("user-model.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: aside)
        return UserModel()
    }

    func saveUserModel(_ m: UserModel) { write(m, .userModel) }

    /// Applies keyboard-side learning increments to the file (read → apply → prune → write).
    func flush(_ delta: UserModelDelta) {
        guard !delta.isEmpty else { return }
        updateUserModel { $0.apply(delta) }
    }

    func updateUserModel(_ transform: (inout UserModel) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url(.userModel), options: .forMerging, error: &error) { u in
            var model = UserModel()
            if let data = try? Data(contentsOf: u) {
                if let decoded = try? KeibordJSON.decoder().decode(UserModel.self, from: data) {
                    model = decoded
                } else {
                    // Unreadable file: keep a copy aside and start over. Returning here (as before) made
                    // every later flush fail silently, so the keyboard never saved learning again.
                    let aside = directory.appendingPathComponent("user-model.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                    try? data.write(to: aside)
                }
            }
            transform(&model)
            model.prune()
            if let out = try? KeibordJSON.encoder().encode(model) {
                try? out.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }

    func resetAll() {
        for file in [KeibordFile.settings, .profile, .userModel, .cards] {
            try? FileManager.default.removeItem(at: url(file))
        }
    }
}
