import Foundation
import Combine
import KeibordCore

/// App-wide state backed by the shared store.
///
/// Settings and details are written shortly after a change (debounced: dragging a slider or a colour
/// picker no longer rewrites the file dozens of times per second) and immediately when the app leaves
/// the foreground (`saveNow`). The learned data can be several megabytes: it is loaded, sorted, edited,
/// exported and imported on a serial background queue, so the UI never waits for it, and every write
/// to it is a coordinated read-modify-write, so learning the keyboard saved in the meantime is kept.
final class AppModel: ObservableObject {
    let store = KeibordStore.shared

    @Published var settings: KeibordSettings { didSet { if settings != oldValue { scheduleSave() } } }
    @Published var profile: PersonalProfile { didSet { if profile != oldValue { scheduleSave() } } }
    @Published private(set) var userModel = UserModel()
    /// Learned words, most used first (sorted in the background, not on every render).
    @Published private(set) var learnedWords: [String] = []
    /// Blocked lookup keys, alphabetically.
    @Published private(set) var blockedWords: [String] = []
    @Published private(set) var isLoadingUserModel = false
    @Published private(set) var state: KeyboardRuntimeState
    @Published private(set) var cards: [StoredCard]

    /// What the files contain (as far as this process knows); `saveNow` writes only what differs.
    private var savedSettings: KeibordSettings
    private var savedProfile: PersonalProfile
    private var pendingSave: DispatchWorkItem?
    /// Modification date of the learned data that was last requested or loaded.
    private var userModelDate: Date?
    private var userModelRequested = false
    private let userModelQueue = DispatchQueue(label: "com.keibord.app.user-model", qos: .userInitiated)
    static let saveDelay: TimeInterval = 0.4

    init() {
        let loadedSettings = store.loadSettings()
        let loadedProfile = store.loadProfile()
        settings = loadedSettings
        profile = loadedProfile
        savedSettings = loadedSettings
        savedProfile = loadedProfile
        state = store.loadState()
        cards = CardVault.shared.cards()
        reloadUserModel(force: true)
    }

    // MARK: Settings & details

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppModel.saveDelay, execute: work)
    }

    /// Writes pending changes to settings and details now (a failed write is retried next time).
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        if settings != savedSettings, store.saveSettings(settings) { savedSettings = settings }
        if profile != savedProfile, store.saveProfile(profile) { savedProfile = profile }
    }

    /// Reloads what may have changed outside the app (called when the app becomes active).
    func refresh() {
        saveNow()
        let diskSettings = store.loadSettings()
        if diskSettings != savedSettings {
            savedSettings = diskSettings
            settings = diskSettings
        }
        let diskProfile = store.loadProfile()
        if diskProfile != savedProfile {
            savedProfile = diskProfile
            profile = diskProfile
        }
        state = store.loadState()
        reloadCards()
        reloadUserModel()
    }

    func reloadCards() { cards = CardVault.shared.cards() }

    // MARK: Learned data

    /// Loads the learned data in the background, unless the file has not changed since the last request.
    func reloadUserModel(force: Bool = false) {
        let date = store.modificationDate(of: .userModel)
        if !force, userModelRequested, date == userModelDate { return }
        userModelRequested = true
        userModelDate = date
        isLoadingUserModel = true
        let store = self.store
        userModelQueue.async { [weak self] in
            let model = store.loadUserModel()
            let lists = AppModel.sortedLists(model)
            DispatchQueue.main.async { self?.publish(model, lists, date: date) }
        }
    }

    /// Edits the learned data: shown at once, then written in the background by a coordinated
    /// read → transform → write of the current file.
    func editUserModel(_ transform: @escaping (inout UserModel) -> Void) {
        var preview = userModel
        transform(&preview)
        userModel = preview
        learnedWords.removeAll { preview.words[$0] == nil }
        blockedWords = preview.blocked.sorted()
        let store = self.store
        userModelQueue.async { [weak self] in
            let model = store.updateUserModel(transform) ?? store.loadUserModel()
            let date = store.modificationDate(of: .userModel)
            let lists = AppModel.sortedLists(model)
            DispatchQueue.main.async { self?.publish(model, lists, date: date) }
        }
    }

    /// Deletes everything learned (and kept copies of unreadable learning files).
    func deleteLearnedData() {
        publish(UserModel(), (learned: [], blocked: []), date: userModelDate)
        let store = self.store
        userModelQueue.async { [weak self] in
            store.saveUserModel(UserModel())
            store.removeCorruptCopies()
            let model = store.loadUserModel()
            let date = store.modificationDate(of: .userModel)
            let lists = AppModel.sortedLists(model)
            DispatchQueue.main.async { self?.publish(model, lists, date: date) }
        }
    }

    private func publish(_ model: UserModel, _ lists: (learned: [String], blocked: [String]), date: Date?) {
        userModel = model
        learnedWords = lists.learned
        blockedWords = lists.blocked
        userModelDate = date
        isLoadingUserModel = false
    }

    static func sortedLists(_ model: UserModel) -> (learned: [String], blocked: [String]) {
        let learned = model.words
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { $0.key }
        return (learned: learned, blocked: model.blocked.sorted())
    }

    // MARK: Export / import / reset

    /// Builds an export file in the background from the saved data (not the copy shown in the app).
    func makeBackup(includePersonal: Bool, password: String?, completion: @escaping (Result<Data, Error>) -> Void) {
        saveNow()
        let settings = self.settings
        let profile: PersonalProfile? = includePersonal ? self.profile : nil
        let version = KeibordVersion.display
        let store = self.store
        userModelQueue.async {
            let payload = BackupPayload(createdAt: Date(), appVersion: version, settings: settings,
                                        profile: profile, userModel: store.loadUserModel())
            let result: Result<Data, Error> = Result {
                try BackupFile.encode(payload, password: password, cipher: PasswordBackupCipher())
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Decodes (and decrypts) a backup file in the background; key derivation takes a moment.
    func decodeBackup(_ data: Data, password: String?, completion: @escaping (Result<BackupPayload, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<BackupPayload, Error> = Result {
                try BackupFile.decode(data, password: password, cipher: PasswordBackupCipher())
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Applies an imported backup. The learned data is merged with (or replaced in) the file as it is
    /// now, in one coordinated read-modify-write, so nothing the keyboard learned meanwhile is lost.
    /// Settings and details are only applied when the learned data could be written.
    func applyBackup(_ payload: BackupPayload, mode: ImportMode, completion: @escaping (Bool) -> Void) {
        saveNow()
        let currentSettings = settings
        let currentProfile = profile
        let store = self.store
        userModelQueue.async { [weak self] in
            var imported: (settings: KeibordSettings, profile: PersonalProfile)?
            let written = store.updateUserModel { model in
                let result = BackupFile.apply(payload, mode: mode, to: (settings: currentSettings, profile: currentProfile, model: model))
                imported = (settings: result.0, profile: result.1)
                model = result.2
            }
            let model = written ?? store.loadUserModel()
            let date = store.modificationDate(of: .userModel)
            let lists = AppModel.sortedLists(model)
            let applied = written != nil ? imported : nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.publish(model, lists, date: date)
                guard let applied = applied else {
                    completion(false)
                    return
                }
                self.settings = applied.settings
                self.profile = applied.profile
                self.saveNow()
                completion(true)
            }
        }
    }

    /// Deletes settings, details, learned data and cards.
    func resetEverything(completion: (() -> Void)? = nil) {
        saveNow()
        let store = self.store
        userModelQueue.async { [weak self] in
            store.resetAll()
            let state = store.loadState()
            let cards = CardVault.shared.cards()
            let date = store.modificationDate(of: .userModel)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingSave?.cancel()
                self.pendingSave = nil
                self.savedSettings = KeibordSettings()
                self.savedProfile = PersonalProfile()
                self.settings = KeibordSettings()
                self.profile = PersonalProfile()
                self.state = state
                self.cards = cards
                self.publish(UserModel(), (learned: [], blocked: []), date: date)
                completion?()
            }
        }
    }
}
