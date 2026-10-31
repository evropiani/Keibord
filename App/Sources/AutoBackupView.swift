import SwiftUI
import UIKit
import KeibordCore

/// Sets up automatic backups (`AutoBackup`): the password, a first backup (in Files › On My iPhone ›
/// Keibord) and the daily automation in Shortcuts (apps cannot create automations, so the steps are shown).
struct AutoBackupView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var passwordRepeat = ""
    @State private var hasPassword = AutoBackup.shared.hasPassword
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
                Button("Back Up Now") { backUpNow() }
                    .disabled(busy || !hasPassword)
                if let date = lastDate {
                    LabeledContent("Last Backup", value: date.formatted(date: .abbreviated, time: .shortened))
                    if let summary = lastSummary { LabeledContent("Contents", value: summary) }
                    Button("Show in Files") { showInFiles() }
                }
                if let error = lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("2. Back Up")
            } footer: {
                Text("Saved as \(AutoBackup.fileName) in Files › On My iPhone › Keibord; every backup replaces it. Deleting the Keibord app deletes this folder too: for a copy elsewhere, see the last step below.")
            }
            Section {
                Button("Open Shortcuts") { openShortcuts() }
                Label("Tap Automation, then +", systemImage: "1.circle")
                Label("Time of Day: e.g. 03:00, Daily, Run Immediately; tap Next", systemImage: "2.circle")
                Label("Search “Keibord”, choose Back Up Keibord, tap Done", systemImage: "3.circle")
                Label("Optional, a copy in iCloud Drive: add Save File after it, turn off Ask Where to Save, choose the folder and turn on Overwrite If File Exists", systemImage: "4.circle")
            } header: {
                Text("3. Every Day by Itself")
            } footer: {
                Text("iOS does not let apps create automations themselves, so this step is done in Shortcuts. The action needs nothing else: the password comes from here. Restore a backup under Data › Import.")
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

    private func backUpNow() {
        model.saveNow() // the settings just changed in the app are in the backup too
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AutoBackup.shared.run() }
            DispatchQueue.main.async {
                busy = false
                refreshStatus()
                switch result {
                case .success(let backup): message = "Backed up (\(backup.summary))."
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

    /// Opens the Files app at the backup's folder.
    private func showInFiles() {
        let folder = AutoBackup.shared.fileURL.deletingLastPathComponent()
        guard let url = URL(string: "shareddocuments://" + folder.path) else { return }
        UIApplication.shared.open(url)
    }

    private func openShortcuts() {
        guard let url = URL(string: "shortcuts://") else { return }
        UIApplication.shared.open(url)
    }
}
