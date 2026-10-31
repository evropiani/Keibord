import SwiftUI
import UIKit
import KeibordCore

/// Sets up automatic backups (`AutoBackup`): the password, the folder, a test backup and the daily
/// automation in Shortcuts (apps cannot create automations, so the steps are shown).
struct AutoBackupView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var passwordRepeat = ""
    @State private var hasPassword = AutoBackup.shared.hasPassword
    @State private var folderName = AutoBackup.shared.folderName
    @State private var lastDate = AutoBackup.shared.lastDate
    @State private var lastSummary = AutoBackup.shared.lastSummary
    @State private var lastError = AutoBackup.shared.lastError
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                SecureField(hasPassword ? "New Password" : "Password", text: $password)
                if !password.isEmpty { SecureField("Repeat Password", text: $passwordRepeat) }
                Button(hasPassword ? "Change Password" : "Save Password") { savePassword() }
                    .disabled(password.isEmpty || password != passwordRepeat)
            } header: {
                Text("1. Password")
            } footer: {
                Text(hasPassword
                     ? "Saved on this iPhone. Keep it somewhere safe: the backup cannot be opened without it."
                     : "Every backup is encrypted (AES-256) with this password. It is kept on this iPhone only; keep it somewhere safe, as the backup cannot be opened without it.")
            }
            Section {
                Button(folderName.map { "Folder: \($0)" } ?? "Choose Folder…") { chooseFolder() }
            } header: {
                Text("2. Folder")
            } footer: {
                Text("For example iCloud Drive › Keibord. The backup is always called \(AutoBackup.fileName) and replaces the last one.")
            }
            Section {
                Button("Back Up Now") { backUpNow() }
                    .disabled(busy || !hasPassword || folderName == nil)
                if let date = lastDate {
                    LabeledContent("Last Backup", value: date.formatted(date: .abbreviated, time: .shortened))
                    if let summary = lastSummary { LabeledContent("Contents", value: summary) }
                }
                if let error = lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("3. Test")
            }
            Section {
                Button("Open Shortcuts") { openShortcuts() }
                Label("Tap Automation, then +", systemImage: "1.circle")
                Label("Time of Day: e.g. 03:00, Daily, Run Immediately; tap Next", systemImage: "2.circle")
                Label("Search “Keibord”, choose Back Up Keibord, tap Done", systemImage: "3.circle")
            } header: {
                Text("4. Every Day by Itself")
            } footer: {
                Text("iOS does not let apps create automations themselves, so this step is done in Shortcuts. The action needs nothing else: the password and the folder come from here. Restore a backup under Data › Import.")
            }
        }
        .navigationTitle("Automatic Backup")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if busy { ProgressView() }
            }
        }
        .alert("Keibord", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func savePassword() {
        do {
            try AutoBackup.shared.setPassword(password)
            hasPassword = true
            password = ""
            passwordRepeat = ""
            message = "Password saved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func chooseFolder() {
        DocumentPicker.shared.pickFolder { url in
            guard let url = url else { return }
            do {
                try AutoBackup.shared.setFolder(url)
                folderName = AutoBackup.shared.folderName
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func backUpNow() {
        model.saveNow() // the settings just changed in the app are in the backup too
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AutoBackup.shared.run() }
            DispatchQueue.main.async {
                busy = false
                refreshStatus()
                switch result {
                case .success(let summary): message = "Backed up (\(summary))."
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
    }

    private func refreshStatus() {
        lastDate = AutoBackup.shared.lastDate
        lastSummary = AutoBackup.shared.lastSummary
        lastError = AutoBackup.shared.lastError
    }

    private func openShortcuts() {
        guard let url = URL(string: "shortcuts://") else { return }
        UIApplication.shared.open(url)
    }
}
