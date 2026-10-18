import Foundation
import Combine
import UIKit
import KeibordCore

/// App-wide state backed by the shared store.
///
/// Settings and details are written shortly after a change (debounced: dragging a slider or a colour
/// picker no longer rewrites the file dozens of times per second) and immediately when the app leaves
/// the foreground (`saveNow`). The learned data can be several megabytes: it is loaded, sorted, edited,
/// exported and imported on a serial background queue, so the UI never waits for it, and every write
/// to it is a coordinated read-modify-write, so learning the keyboard saved in the meantime is kept.
/// Background work is protected by a background task, so the app is never suspended halfway through
/// a write (the keyboard would otherwise wait for the coordinated file).
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
    /// Set when the learned data could not be written; shown by the dictionary.
    @Published var storageError: String? = nil

    /// What the files contain (as far as this process knows); `saveNow` writes only what differs.
    private var savedSettings: KeibordSettings
    private var savedProfile: PersonalProfile
    private var pendingSave: DispatchWorkItem?
    /// Modification date of the learned data that was last requested or loaded.
    private var userModelDate: Date?
    private var userModelRequested = false
    /// Changes to the learned data that are queued or running. Results of older work are not shown
    /// while newer changes are pending (they would briefly undo what the user just did).
    private var pendingUserModelChanges = 0
    private let userModelQueue = DispatchQueue(label: "com.keibord.app.user-model", qos: .userInitiated)
    static let saveDelay: TimeInterval = 0.4

    typealias SortedLists = (learned: [String], blocked: [String])

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
        let diskState = store.loadState()
        if diskState != state { state = diskState }
        reloadCards()
        reloadUserModel()
    }

    func reloadCards() {
        let current = CardVault.shared.cards()
        if current != cards { cards = current }
    }

    // MARK: Learned data

    /// Loads the learned data in the background, unless the file has not changed since the last request.
    func reloadUserModel(force: Bool = false) {
        let date = store.modificationDate(of: .userModel)
        if !force, userModelRequested, date == userModelDate { return }
        userModelRequested = true
        userModelDate = date
        isLoadingUserModel = true
        let store = self.store
        performUserModelWork(isChange: false, protected: false) {
            let model = store.loadUserModel()
            return (model, AppModel.sortedLists(model), date)
        }
    }

    /// Edits the learned data in the background by a coordinated read → transform → write of the
    /// current file (so learning saved by the keyboard meanwhile is kept). `hiding` names words that
    /// disappear from the lists at once (a swiped-away row must not come back until the write is done).
    func editUserModel(hiding hidden: Set<String> = [], _ transform: @escaping (inout UserModel) -> Void) {
        if !hidden.isEmpty {
            learnedWords.removeAll { hidden.contains($0) }
            blockedWords.removeAll { hidden.contains($0) }
        }
        let store = self.store
        performUserModelWork(isChange: true) { [weak self] in
            let written = store.updateUserModel(transform)
            if written == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.storageError = "The learned words could not be saved. Try again after unlocking your iPhone."
                }
            }
            let model = written ?? store.loadUserModel()
            return (model, AppModel.sortedLists(model), store.modificationDate(of: .userModel))
        }
    }

    /// Deletes everything learned (and kept copies of unreadable learning files).
    func deleteLearnedData() {
        learnedWords = []
        blockedWords = []
        userModel = UserModel()
        let store = self.store
        performUserModelWork(isChange: true) {
            store.saveUserModel(UserModel())
            store.removeCorruptCopies()
            let model = store.loadUserModel()
            return (model, AppModel.sortedLists(model), store.modificationDate(of: .userModel))
        }
    }

    /// Runs `work` on the learned-data queue and publishes the model it returns, unless newer changes
    /// are pending by then. Reads (`protected: false`) need no background task.
    private func performUserModelWork(isChange: Bool, protected: Bool = true, _ work: @escaping () -> (UserModel, SortedLists, Date?)) {
        if isChange { pendingUserModelChanges += 1 }
        let body: () -> Void = { [weak self] in
            let (model, lists, date) = work()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if isChange { self.pendingUserModelChanges -= 1 }
                guard self.pendingUserModelChanges == 0 else { return }
                self.publish(model, lists, date: date)
            }
        }
        if protected {
            performInBackground(body)
        } else {
            userModelQueue.async { body() }
        }
    }

    private func publish(_ model: UserModel, _ lists: SortedLists, date: Date?) {
        userModel = model
        learnedWords = lists.learned
        blockedWords = lists.blocked
        userModelDate = date
        userModelRequested = true
        isLoadingUserModel = false
    }

    static func sortedLists(_ model: UserModel) -> SortedLists {
        let learned = model.words
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { $0.key }
        return (learned: learned, blocked: model.blocked.sorted())
    }

    /// Runs `work` on the serial learned-data queue inside a background task: if the user leaves the
    /// app meanwhile, iOS gives the write time to finish instead of suspending the app halfway through
    /// a coordinated write (which would make the keyboard wait for the file).
    private func performInBackground(_ work: @escaping () -> Void) {
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        let finish: () -> Void = {
            guard task != .invalid else { return }
            application.endBackgroundTask(task)
            task = .invalid
        }
        // The expiration handler runs on the main thread and must end the task before it returns.
        task = application.beginBackgroundTask(withName: "Keibord.saveLearnedData") { finish() }
        userModelQueue.async {
            work()
            DispatchQueue.main.async { finish() }
        }
    }

    // MARK: Export / import / reset

    /// Builds an export file in the background from the saved data (not the copy shown in the app).
    /// An empty password means "not encrypted".
    func makeBackup(includePersonal: Bool, password: String?, completion: @escaping (Result<Data, Error>) -> Void) {
        saveNow()
        let settings = self.settings
        let profile: PersonalProfile? = includePersonal ? self.profile : nil
        let version = KeibordVersion.display
        let store = self.store
        performInBackground {
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
        pendingUserModelChanges += 1
        performInBackground { [weak self] in
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
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pendingUserModelChanges -= 1
                if self.pendingUserModelChanges == 0 { self.publish(model, lists, date: date) }
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
        pendingUserModelChanges += 1
        performInBackground { [weak self] in
            store.resetAll()
            let state = store.loadState()
            let cards = CardVault.shared.cards()
            let date = store.modificationDate(of: .userModel)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pendingUserModelChanges -= 1
                self.pendingSave?.cancel()
                self.pendingSave = nil
                self.savedSettings = KeibordSettings()
                self.savedProfile = PersonalProfile()
                self.settings = KeibordSettings()
                self.profile = PersonalProfile()
                self.state = state
                self.cards = cards
                if self.pendingUserModelChanges == 0 { self.publish(UserModel(), (learned: [], blocked: []), date: date) }
                completion?()
            }
        }
    }
}
