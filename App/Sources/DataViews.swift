import SwiftUI
import UniformTypeIdentifiers
import KeibordCore

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var search = ""

    /// Rows shown at once. Up to 30,000 learned words would make every change of the list slow; the
    /// others are found with the search.
    static let rowLimit = 500

    private func matching(_ words: [String]) -> [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return words }
        return words.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    Text("Learned (\(model.learnedWords.count))").tag(0)
                    Text("Blocked (\(model.blockedWords.count))").tag(1)
                }
                .pickerStyle(.segmented)
                AddWordRow(blocking: tab == 1)
            } footer: {
                Text("\(model.userModel.bigrams.count) word pairs · \(model.userModel.touchSampleCount) touch samples")
            }
            if tab == 0 {
                let words = matching(model.learnedWords)
                Section {
                    ForEach(Array(words.prefix(DictionaryView.rowLimit)), id: \.self) { word in
                        let info = model.userModel.words[word]
                        HStack {
                            Text(word)
                            if info?.addedManually == true { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text("\(info?.count ?? 0)×").foregroundStyle(.secondary).font(.callout)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.editUserModel(hiding: [word]) { $0.removeWord(word) } }
                            Button("Block") { model.editUserModel(hiding: [word]) { $0.block(word) } }.tint(.orange)
                        }
                    }
                } footer: {
                    if words.count > DictionaryView.rowLimit {
                        Text("Showing the \(DictionaryView.rowLimit) most used of \(words.count) words. Search to find the others.")
                    } else if words.isEmpty && model.isLoadingUserModel {
                        ProgressView()
                    }
                }
            } else {
                let words = matching(model.blockedWords)
                Section {
                    ForEach(Array(words.prefix(DictionaryView.rowLimit)), id: \.self) { word in
                        Text(word)
                            .swipeActions {
                                Button("Unblock") { model.editUserModel(hiding: [word]) { $0.unblock(word) } }.tint(.green)
                            }
                    }
                } footer: {
                    if words.count > DictionaryView.rowLimit {
                        Text("Showing \(DictionaryView.rowLimit) of \(words.count) words. Search to find the others.")
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Dictionary")
        .onAppear { model.reloadUserModel() }
        .alert("Keibord", isPresented: Binding(get: { model.storageError != nil }, set: { if !$0 { model.storageError = nil } })) {
            Button("OK", role: .cancel) { model.storageError = nil }
        } message: {
            Text(model.storageError ?? "")
        }
    }
}

/// The "add / block a word" field. A view of its own so typing in it does not re-render the word list.
private struct AddWordRow: View {
    @EnvironmentObject var model: AppModel
    let blocking: Bool
    @State private var text = ""

    private var word: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack {
            TextField(blocking ? "Block a word" : "Add a word", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { add() }
            Button(blocking ? "Block" : "Add") { add() }
                .disabled(word.isEmpty)
        }
    }

    private func add() {
        let newWord = word
        guard !newWord.isEmpty else { return }
        if blocking {
            model.editUserModel(hiding: [newWord]) { $0.block(newWord) }
        } else {
            model.editUserModel { $0.addWord(newWord) }
        }
        text = ""
    }
}

// MARK: - Text replacements

struct ShortcutsView: View {
    @EnvironmentObject var model: AppModel
    @State private var shortcut = ""
    @State private var phrase = ""

    private var trimmedShortcut: String { shortcut.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                TextField("Phrase (e.g. On my way!)", text: $phrase)
                TextField("Shortcut (e.g. omw)", text: $shortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") { add() }
                    .disabled(trimmedShortcut.isEmpty || phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("Adding a shortcut that exists already changes its phrase. Your iOS text replacements (Settings → General → Keyboard → Text Replacement) work in Keibord too.")
            }
            Section {
                ForEach(model.profile.shortcuts) { s in
                    NavigationLink {
                        ShortcutEditView(shortcutID: s.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(s.phrase)
                            Text(s.shortcut).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { model.profile.shortcuts.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Text Replacements")
    }

    private func add() {
        let newShortcut = trimmedShortcut
        guard !newShortcut.isEmpty else { return }
        // Shortcuts are matched like typed words (case and apostrophe style ignored): one entry per shortcut.
        let key = TextUnits.lookupKey(newShortcut)
        if let i = model.profile.shortcuts.firstIndex(where: { TextUnits.lookupKey($0.shortcut.trimmingCharacters(in: .whitespacesAndNewlines)) == key }) {
            model.profile.shortcuts[i].phrase = phrase
        } else {
            model.profile.shortcuts.append(TextShortcut(shortcut: newShortcut, phrase: phrase))
        }
        shortcut = ""
        phrase = ""
    }
}

/// Edits one text replacement in place (looked up by id, so a deleted entry is never written back).
struct ShortcutEditView: View {
    @EnvironmentObject var model: AppModel
    let shortcutID: UUID

    private func binding(_ keyPath: WritableKeyPath<TextShortcut, String>) -> Binding<String> {
        Binding(
            get: { model.profile.shortcuts.first(where: { $0.id == shortcutID })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let i = model.profile.shortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
                model.profile.shortcuts[i][keyPath: keyPath] = newValue
            }
        )
    }

    var body: some View {
        Form {
            Section("Phrase") {
                TextField("Phrase", text: binding(\.phrase), axis: .vertical)
            }
            Section("Shortcut") {
                TextField("Shortcut", text: binding(\.shortcut))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle("Text Replacement")
    }
}

// MARK: - Personal info

struct PersonalInfoView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Name") {
                TextField("First name", text: $model.profile.info.givenName)
                TextField("Middle name", text: $model.profile.info.middleName)
                TextField("Last name", text: $model.profile.info.familyName)
                TextField("Nickname", text: $model.profile.info.nickname)
                TextField("Company", text: $model.profile.info.organization)
                TextField("Job title", text: $model.profile.info.jobTitle)
            }
            ValueListSection(title: "Emails", placeholder: "name@example.com", values: $model.profile.info.emails, keyboard: .emailAddress)
            ValueListSection(title: "Phone numbers", placeholder: "+43 …", values: $model.profile.info.phones, keyboard: .phonePad)
            ValueListSection(title: "Usernames", placeholder: "username", values: $model.profile.info.usernames, keyboard: .default)
            Section("Address") {
                TextField("Street", text: $model.profile.info.street1)
                TextField("Street (line 2)", text: $model.profile.info.street2)
                TextField("Postal code", text: $model.profile.info.postalCode)
                TextField("City", text: $model.profile.info.city)
                TextField("State / Region", text: $model.profile.info.region)
                TextField("Country", text: $model.profile.info.country)
            }
            Section {
                TextField("Website", text: $model.profile.info.website)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("Keibord offers these values in matching fields (email, phone, address …). They never leave this iPhone unless you include them in an export.")
            }
        }
        .navigationTitle("My Details")
    }
}

struct ValueListSection: View {
    let title: String
    let placeholder: String
    @Binding var values: [String]
    let keyboard: UIKeyboardType

    var body: some View {
        Section(title) {
            ForEach(values.indices, id: \.self) { i in
                TextField(placeholder, text: Binding(
                    get: { i < values.count ? values[i] : "" },
                    set: { if i < values.count { values[i] = $0 } }
                ))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .onDelete { values.remove(atOffsets: $0) }
            Button("Add") { values.append("") }
        }
    }
}

// MARK: - Cards

struct CardsView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(model.cards) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(card.title).font(.headline)
                            if card.requiresCVV { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                        }
                        Text(detail(card)).font(.caption).foregroundStyle(card.isExpired() ? Color.orange : Color.secondary)
                        if card.isLockedOut {
                            Button("Locked after wrong CVVs — Reset") {
                                CardVault.shared.resetAttempts(id: card.id)
                                model.reloadCards()
                            }
                            .font(.caption)
                        }
                    }
                }
                .onDelete { offsets in
                    // Resolve the ids first (and only for valid rows); deletion is by id.
                    let ids = offsets.filter { $0 < model.cards.count }.map { model.cards[$0].id }
                    for id in ids { CardVault.shared.delete(id: id) }
                    model.reloadCards()
                }
            } footer: {
                Text("Card numbers are encrypted on this device. The security code (CVV) is never stored: with “Require CVV” the number can only be unlocked by typing the CVV in the keyboard. Cards are never included in exports.")
            }
        }
        .navigationTitle("Cards")
        .toolbar {
            Button { adding = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { AddCardView { model.reloadCards() } }
        }
        .onAppear { model.reloadCards() }
    }

    private func detail(_ card: StoredCard) -> String {
        let expiry = (card.isExpired() ? "expired " : "expires ") + card.expiry
        return [card.holderName, expiry].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct AddCardView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void
    @State private var nickname = ""
    @State private var holder = ""
    @State private var number = ""
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var year = Calendar.current.component(.year, from: Date()) + 3
    @State private var requiresCVV = true
    @State private var cvv = ""
    @State private var error: String?

    /// ASCII digits only, exactly like the vault (other numerals are not part of a card number).
    private var digits: String { CardBrand.digits(in: number) }
    private var brand: CardBrand { CardBrand.detect(digits) }
    private var cvvDigits: String { CardBrand.digits(in: cvv) }
    private var isExpired: Bool {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        guard let thisYear = now.year, let thisMonth = now.month else { return false }
        return year < thisYear || (year == thisYear && month < thisMonth)
    }

    /// The keyboard's unlock pad takes exactly `cvvLength` digits, so only such a code can be used.
    private var canSave: Bool {
        CardBrand.luhnValid(digits) && (!requiresCVV || cvvDigits.count == brand.cvvLength)
    }

    var body: some View {
        Form {
            Section("Card") {
                TextField("Nickname (optional)", text: $nickname)
                TextField("Name on card", text: $holder)
                    .textContentType(.creditCardName)
                TextField("Card number", text: $number)
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardNumber)
                if !digits.isEmpty {
                    Text("\(brand.displayName)\(CardBrand.luhnValid(digits) ? "" : " · number not valid yet")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Expiry month", selection: $month) {
                    ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                let thisYear = Calendar.current.component(.year, from: Date())
                Picker("Expiry year", selection: $year) {
                    ForEach(thisYear...(thisYear + 15), id: \.self) { Text(String($0)).tag($0) }
                }
                if isExpired {
                    Text("This expiry date is in the past.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("Require CVV to unlock", isOn: $requiresCVV)
                if requiresCVV {
                    SecureField("CVV (\(brand.cvvLength) digits, only used to lock the card)", text: $cvv)
                        .keyboardType(.numberPad)
                }
            } footer: {
                Text("The CVV is not saved. It is used to derive the key that encrypts the card number, so you must type it in the keyboard to unlock the card.")
            }
            if let error = error {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Add Card")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try CardVault.shared.add(nickname: nickname, holderName: holder, number: digits, expMonth: month, expYear: year,
                                                 requiresCVV: requiresCVV, cvv: requiresCVV ? cvvDigits : nil)
                        onSave()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(!canSave)
            }
        }
    }
}

// MARK: - Data (export / import)

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = d
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// What the keyboard wrote to its log (opening, sizes, stalls; never typed text), to copy and send
/// when the keyboard misbehaves.
struct KeyboardLogView: View {
    @State private var log = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(log.isEmpty ? "Nothing logged yet. Open the keyboard (with Full Access on), then come back." : log)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Keyboard Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = log
                    copied = true
                }
                .disabled(log.isEmpty)
                Button("Clear", role: .destructive) {
                    KeyboardLog.shared.clear()
                    log = ""
                }
                .disabled(log.isEmpty)
            }
        }
        .onAppear { log = KeyboardLog.shared.read() }
        .refreshable { log = KeyboardLog.shared.read() }
    }
}

struct DataView: View {
    @EnvironmentObject var model: AppModel
    @State private var includeTypingData = true
    @State private var includeSettings = true
    @State private var includePersonal = true
    @State private var exportPassword = ""
    @State private var exportPasswordRepeat = ""
    @State private var exportDocument: BackupDocument?
    @State private var exportFilename = ""
    @State private var showExporter = false
    @State private var importData: Data?
    @State private var importPassword = ""
    @State private var askPassword = false
    @State private var passwordWasWrong = false
    @State private var pendingPayload: BackupPayload?
    @State private var showImportOptions = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmReset = false
    @State private var confirmResetAll = false

    /// A mistyped password would make the backup impossible to open, so it is asked for twice.
    private var passwordsMatch: Bool { exportPassword.isEmpty || exportPassword == exportPasswordRepeat }

    private var exportsSomething: Bool { includeTypingData || includeSettings || includePersonal }
    private var exportsOnlySettings: Bool { includeSettings && !includeTypingData && !includePersonal }

    private static func filename(for date: Date, onlySettings: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return "Keibord-\(onlySettings ? "Settings" : "Backup")-\(f.string(from: date))"
    }

    /// "settings, typing data and details" – what a backup file contains.
    static func contents(of payload: BackupPayload) -> String {
        var parts: [String] = []
        if payload.settings != nil { parts.append("settings") }
        if let model = payload.userModel { parts.append("typing data (\(model.words.count) words)") }
        if payload.profile != nil { parts.append("details & text replacements") }
        switch parts.count {
        case 0: return "nothing"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    var body: some View {
        Form {
            Section {
                SecureField("Password (optional)", text: $exportPassword)
                if !exportPassword.isEmpty {
                    SecureField("Repeat Password", text: $exportPasswordRepeat)
                }
                Button("Export All…") { export(all: true) }
                    .disabled(busy || !passwordsMatch)
            } header: {
                Text("Export")
            } footer: {
                Text((passwordsMatch ? "" : "The passwords do not match. ") + "Export All saves your typing data, all settings and your details in one file. With a password it is encrypted (AES-256) and cannot be opened without it. Cards are never exported.")
            }
            Section {
                Toggle("Typing Data", isOn: $includeTypingData)
                Toggle("All Settings", isOn: $includeSettings)
                Toggle("My Details & Text Replacements", isOn: $includePersonal)
                Button(exportsOnlySettings ? "Export Settings…" : "Export Selected…") { export(all: false) }
                    .disabled(busy || !passwordsMatch || !exportsSomething)
            } header: {
                Text("Export Selected")
            } footer: {
                Text("Typing data: learned words, word pairs, your touch model and emoji history. All settings: languages, layouts, appearance, colours, tinted keys and every option.")
            }
            Section {
                Button("Import…") { pickImportFile() }
                    .disabled(busy)
            } header: {
                Text("Import")
            } footer: {
                Text("After choosing a file you can import all of it or only some parts; only what you import changes on this iPhone.")
            }
            Section("Reset") {
                Button("Delete Learned Data", role: .destructive) { confirmReset = true }
                    .disabled(busy)
                Button("Reset Everything", role: .destructive) { confirmResetAll = true }
                    .disabled(busy)
            }
            Section("Diagnostics") {
                LabeledContent("Version", value: KeibordVersion.display)
                LabeledContent("Shared storage", value: model.store.isShared ? "Yes" : "No")
                LabeledContent("Learned words", value: "\(model.userModel.words.count)")
                LabeledContent("Keyboard last active", value: model.state.lastActive?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                LabeledContent("Keyboard Full Access", value: model.state.hasFullAccess ? "Yes" : "No")
                LabeledContent("Keyboard app group", value: model.state.appGroupIdentifier ?? "unknown")
                Text(AppGroup.diagnostics).font(.caption.monospaced()).foregroundStyle(.secondary)
                NavigationLink("Keyboard Log") { KeyboardLogView() }
            }
        }
        .navigationTitle("Data")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if busy { ProgressView() }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: exportFilename) { result in
            switch result {
            case .success:
                message = "Backup exported."
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { message = error.localizedDescription }
            }
            exportDocument = nil
        }
        .alert(passwordWasWrong ? "Wrong Password" : "Backup Password", isPresented: $askPassword) {
            SecureField("Password", text: $importPassword)
            Button("Cancel", role: .cancel) { importData = nil }
            Button("Open") { decodeImport(password: importPassword) }
        } message: {
            Text("This backup is encrypted. Enter the password that was used to export it.")
        }
        .sheet(isPresented: $showImportOptions) {
            if let payload = pendingPayload {
                ImportOptionsView(payload: payload, onImport: { selection, mode in
                    showImportOptions = false
                    applyImport(selection, mode: mode)
                }, onCancel: {
                    showImportOptions = false
                    pendingPayload = nil
                })
            }
        }
        .confirmationDialog("Delete everything Keibord has learned?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Delete Learned Data", role: .destructive) { model.deleteLearnedData() }
        }
        .confirmationDialog("Reset all settings, learned data, details and cards?", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) {
                busy = true
                model.resetEverything {
                    busy = false
                    message = "Keibord was reset."
                }
            }
        }
        .alert("Keibord", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    /// The backup is built and encrypted in the background (key derivation and encoding several
    /// megabytes of learned data would freeze the screen).
    private func export(all: Bool) {
        busy = true
        let onlySettings = !all && exportsOnlySettings
        model.makeBackup(includeTypingData: all || includeTypingData, includeSettings: all || includeSettings,
                         includePersonal: all || includePersonal, password: exportPassword.isEmpty ? nil : exportPassword) { result in
            busy = false
            switch result {
            case .success(let data):
                exportFilename = DataView.filename(for: Date(), onlySettings: onlySettings)
                exportDocument = BackupDocument(data: data)
                showExporter = true
            case .failure(let error):
                message = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func pickImportFile() {
        DocumentPicker.shared.pickFile { url in
            guard let url = url else { return }
            // The picker hands over a copy of the file; it is not needed after reading.
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let data = try Data(contentsOf: url)
                importData = data
                if BackupFile.isEncrypted(data) {
                    importPassword = ""
                    passwordWasWrong = false
                    askPassword = true
                } else {
                    decodeImport(password: nil)
                }
            } catch {
                message = "The file could not be read: \(error.localizedDescription)"
            }
        }
    }

    private func decodeImport(password: String?) {
        guard let data = importData else { return }
        busy = true
        model.decodeBackup(data, password: password) { result in
            busy = false
            switch result {
            case .success(let payload):
                importData = nil
                pendingPayload = payload
                showImportOptions = true
            case .failure(let error):
                let backupError = error as? BackupError
                if backupError == .wrongPassword || backupError == .passwordRequired {
                    // Ask again instead of making the user pick the file again.
                    importPassword = ""
                    passwordWasWrong = backupError == .wrongPassword
                    askPassword = true
                } else {
                    importData = nil
                    message = error is BackupError ? error.localizedDescription : "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyImport(_ payload: BackupPayload, mode: ImportMode) {
        pendingPayload = nil
        busy = true
        model.applyBackup(payload, mode: mode) { ok in
            busy = false
            if ok {
                message = "Imported \(DataView.contents(of: payload)) from \(payload.createdAt.formatted(date: .abbreviated, time: .omitted))."
            } else {
                message = "The backup could not be imported because the learned words could not be saved. Nothing was changed."
            }
        }
    }
}

/// What to take from a backup file: all of it, or the chosen parts (every part the file contains is on
/// by default); typing data is merged or replaced.
struct ImportOptionsView: View {
    let payload: BackupPayload
    let onImport: (BackupPayload, ImportMode) -> Void
    let onCancel: () -> Void
    @State private var typingData = true
    @State private var settings = true
    @State private var details = true
    @State private var mode: ImportMode = .merge

    private var hasTypingData: Bool { payload.userModel != nil }
    private var hasSettings: Bool { payload.settings != nil }
    private var hasDetails: Bool { payload.profile != nil }
    private var wordCount: Int { payload.userModel?.words.count ?? 0 }

    private var selection: BackupPayload {
        payload.selecting(settings: settings, profile: details, userModel: typingData)
    }

    private var selectsSomething: Bool {
        (typingData && hasTypingData) || (settings && hasSettings) || (details && hasDetails)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasTypingData {
                        Picker("Typing Data", selection: $mode) {
                            Text("Merge").tag(ImportMode.merge)
                            Text("Replace").tag(ImportMode.replace)
                        }
                        .pickerStyle(.segmented)
                    }
                    Button("Import All") { onImport(payload, mode) }
                } footer: {
                    Text("This file from \(payload.createdAt.formatted(date: .abbreviated, time: .omitted)) contains \(DataView.contents(of: payload)). Only what you import changes on this iPhone."
                         + (hasTypingData ? " Merge keeps what this iPhone has learned and adds the file's typing data; Replace deletes it first." : ""))
                }
                Section {
                    if hasTypingData { Toggle("Typing Data (\(wordCount) words)", isOn: $typingData) }
                    if hasSettings { Toggle("All Settings", isOn: $settings) }
                    if hasDetails { Toggle("My Details & Text Replacements", isOn: $details) }
                    Button("Import Selected") { onImport(selection, mode) }
                        .disabled(!selectsSomething)
                } header: {
                    Text("Import Selected")
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}
