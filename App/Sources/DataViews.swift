import SwiftUI
import UniformTypeIdentifiers
import KeibordCore

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var search = ""
    @State private var newWord = ""

    private var learned: [(String, LearnedWord)] {
        model.userModel.words
            .filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private var blocked: [String] {
        model.userModel.blocked.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.sorted()
    }

    var body: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    Text("Learned (\(model.userModel.words.count))").tag(0)
                    Text("Blocked (\(model.userModel.blocked.count))").tag(1)
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField(tab == 0 ? "Add a word" : "Block a word", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(tab == 0 ? "Add" : "Block") {
                        let word = newWord.trimmingCharacters(in: .whitespaces)
                        guard !word.isEmpty else { return }
                        if tab == 0 { model.editUserModel { $0.addWord(word) } } else { model.editUserModel { $0.block(word) } }
                        newWord = ""
                    }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("\(model.userModel.bigrams.count) word pairs · \(model.userModel.touchSampleCount) touch samples")
            }
            if tab == 0 {
                Section {
                    ForEach(learned, id: \.0) { word, info in
                        HStack {
                            Text(word)
                            if info.addedManually { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text("\(info.count)×").foregroundStyle(.secondary).font(.callout)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.editUserModel { $0.removeWord(word) } }
                            Button("Block") { model.editUserModel { $0.block(word) } }.tint(.orange)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(blocked, id: \.self) { word in
                        Text(word)
                            .swipeActions {
                                Button("Unblock") { model.editUserModel { $0.unblock(word) } }.tint(.green)
                            }
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Dictionary")
        .onAppear { model.refresh() }
    }
}

// MARK: - Text replacements

struct ShortcutsView: View {
    @EnvironmentObject var model: AppModel
    @State private var shortcut = ""
    @State private var phrase = ""

    var body: some View {
        List {
            Section {
                TextField("Phrase (e.g. On my way!)", text: $phrase)
                TextField("Shortcut (e.g. omw)", text: $shortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") {
                    model.profile.shortcuts.append(TextShortcut(shortcut: shortcut.trimmingCharacters(in: .whitespaces), phrase: phrase))
                    shortcut = ""
                    phrase = ""
                }
                .disabled(shortcut.trimmingCharacters(in: .whitespaces).isEmpty || phrase.isEmpty)
            } footer: {
                Text("Your iOS text replacements (Settings → General → Keyboard → Text Replacement) work in Keibord too.")
            }
            Section {
                ForEach(model.profile.shortcuts) { s in
                    VStack(alignment: .leading) {
                        Text(s.phrase)
                        Text(s.shortcut).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { model.profile.shortcuts.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Text Replacements")
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
                        Text("\(card.holderName) · expires \(card.expiry)").font(.caption).foregroundStyle(.secondary)
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
                    for i in offsets { CardVault.shared.delete(id: model.cards[i].id) }
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

    private var digits: String { number.filter { $0.isNumber } }

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
                    Text("\(CardBrand.detect(digits).displayName)\(CardBrand.luhnValid(digits) ? "" : " · number not valid yet")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Expiry month", selection: $month) {
                    ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                let thisYear = Calendar.current.component(.year, from: Date())
                Picker("Expiry year", selection: $year) {
                    ForEach(thisYear...(thisYear + 15), id: \.self) { Text(String($0)).tag($0) }
                }
            }
            Section {
                Toggle("Require CVV to unlock", isOn: $requiresCVV)
                if requiresCVV {
                    SecureField("CVV (only used to lock the card)", text: $cvv)
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
                                                 requiresCVV: requiresCVV, cvv: requiresCVV ? cvv : nil)
                        onSave()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(digits.count < 12 || (requiresCVV && cvv.count < 3))
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

struct DataView: View {
    @EnvironmentObject var model: AppModel
    @State private var includePersonal = true
    @State private var exportPassword = ""
    @State private var exportDocument: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importData: Data?
    @State private var importPassword = ""
    @State private var askPassword = false
    @State private var pendingPayload: BackupPayload?
    @State private var askMode = false
    @State private var message: String?
    @State private var confirmReset = false
    @State private var confirmResetAll = false

    private var filename: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "Keibord-Backup-\(f.string(from: Date()))"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Include My Details & Text Replacements", isOn: $includePersonal)
                SecureField("Password (optional)", text: $exportPassword)
                Button("Export Typing Data…") { export() }
            } header: {
                Text("Export")
            } footer: {
                Text("Exports learned words, word pairs, your touch model, emoji history and all settings as a JSON file. With a password it is encrypted (AES-256). Cards are never exported.")
            }
            Section {
                Button("Import Backup…") { showImporter = true }
            } header: {
                Text("Import")
            } footer: {
                Text("Merge combines the backup with what this iPhone has learned; Replace overwrites it.")
            }
            Section("Reset") {
                Button("Delete Learned Data", role: .destructive) { confirmReset = true }
                Button("Reset Everything", role: .destructive) { confirmResetAll = true }
            }
            Section("Diagnostics") {
                LabeledContent("Version", value: KeibordVersion.display)
                LabeledContent("Shared storage", value: model.store.isShared ? "Yes" : "No")
                LabeledContent("Learned words", value: "\(model.userModel.words.count)")
                LabeledContent("Keyboard last active", value: model.state.lastActive?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                LabeledContent("Keyboard Full Access", value: model.state.hasFullAccess ? "Yes" : "No")
                Text(AppGroup.diagnostics).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Data")
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: filename) { result in
            if case .failure(let error) = result { message = error.localizedDescription } else { message = "Backup exported." }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    importData = data
                    if BackupFile.isEncrypted(data) {
                        importPassword = ""
                        askPassword = true
                    } else {
                        decodeImport(password: nil)
                    }
                } catch {
                    message = error.localizedDescription
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .alert("Backup Password", isPresented: $askPassword) {
            SecureField("Password", text: $importPassword)
            Button("Cancel", role: .cancel) { importData = nil }
            Button("Open") { decodeImport(password: importPassword) }
        }
        .confirmationDialog("Import Backup", isPresented: $askMode, titleVisibility: .visible) {
            Button("Merge with This iPhone") { applyImport(.merge) }
            Button("Replace Everything", role: .destructive) { applyImport(.replace) }
            Button("Cancel", role: .cancel) { pendingPayload = nil }
        }
        .confirmationDialog("Delete everything Keibord has learned?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Delete Learned Data", role: .destructive) { model.replaceUserModel(UserModel()) }
        }
        .confirmationDialog("Reset all settings, learned data, details and cards?", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) {
                model.store.resetAll()
                model.settings = KeibordSettings()
                model.profile = PersonalProfile()
                model.refresh()
            }
        }
        .alert("Keibord", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func export() {
        model.refresh()
        let payload = BackupPayload(createdAt: Date(), appVersion: KeibordVersion.display, settings: model.settings,
                                    profile: includePersonal ? model.profile : nil, userModel: model.userModel)
        do {
            let data = try BackupFile.encode(payload, password: exportPassword.isEmpty ? nil : exportPassword, cipher: PasswordBackupCipher())
            exportDocument = BackupDocument(data: data)
            showExporter = true
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func decodeImport(password: String?) {
        guard let data = importData else { return }
        do {
            pendingPayload = try BackupFile.decode(data, password: password, cipher: PasswordBackupCipher())
            askMode = true
        } catch BackupError.wrongPassword {
            message = "Wrong password."
        } catch BackupError.notAKeibordBackup {
            message = "This file is not a Keibord backup."
        } catch {
            message = "Import failed: \(error)"
        }
        importData = nil
    }

    private func applyImport(_ mode: ImportMode) {
        guard let payload = pendingPayload else { return }
        let result = BackupFile.apply(payload, mode: mode, to: (settings: model.settings, profile: model.profile, model: model.userModel))
        model.settings = result.0
        model.profile = result.1
        model.replaceUserModel(result.2)
        pendingPayload = nil
        message = "Imported \(payload.userModel.words.count) words from \(payload.createdAt.formatted(date: .abbreviated, time: .omitted))."
    }
}
