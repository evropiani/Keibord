import SwiftUI
import UIKit
import KeibordCore

/// Sets up automatic backups (`AutoBackup`): the password, where the backup file is saved, a test backup
/// and the daily automation in Shortcuts (apps cannot create automations, so the steps are shown).
struct AutoBackupView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var passwordRepeat = ""
    @State private var hasPassword = AutoBackup.shared.hasPassword
    @State private var location = AutoBackup.shared.location
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
                Button(location == nil ? "Choose Where to Save…" : "Save Somewhere Else…") { chooseLocation() }
                    .disabled(busy || !hasPassword)
                if let location = location { LabeledContent("Saved in", value: location) }
            } header: {
                Text("2. Where to Save")
            } footer: {
                Text("Makes the first backup and opens the Save dialog: pick a folder such as iCloud Drive › Keibord and tap Move. The file is called \(AutoBackup.fileName); every later backup replaces it.")
            }
            Section {
                Button("Back Up Now") { backUpNow() }
                    .disabled(busy || !hasPassword || location == nil)
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
                Text("iOS does not let apps create automations themselves, so this step is done in Shortcuts. The action needs nothing else: the password and the file come from here. Restore a backup under Data › Import.")
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

    private func chooseLocation() {
        model.saveNow()
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AutoBackup.shared.makeFirstFile() }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .failure(let error):
                    message = error.localizedDescription
                case .success(let file):
                    DocumentPicker.shared.export(file) { saved in
                        guard let saved = saved else { return }
                        do {
                            try AutoBackup.shared.setFile(saved)
                            location = AutoBackup.shared.location
                            refreshStatus()
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
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
