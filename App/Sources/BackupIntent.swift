import AppIntents
import UniformTypeIdentifiers

/// The Shortcuts action for automatic backups (`AutoBackup`). It needs no input: the password is set up
/// in the app, so a daily automation is just this one action. It also outputs the backup file, so a
/// "Save File" after it can keep a copy elsewhere (iCloud Drive).
struct BackUpKeibordIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up Keibord"
    static var description = IntentDescription("Saves an encrypted backup of your typing data, settings and details as Keibord-Backup.json in Files › On My iPhone › Keibord, replacing the last one, and outputs the file.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let backup = try AutoBackup.shared.run()
        let file = IntentFile(data: backup.data, filename: AutoBackup.fileName, type: .json)
        return .result(value: file, dialog: "Keibord backed up (\(backup.summary)).")
    }
}

/// Makes the action available in Shortcuts and Spotlight without adding anything.
struct KeibordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BackUpKeibordIntent(), phrases: ["Back up \(.applicationName)"],
                    shortTitle: "Back Up Keibord", systemImageName: "externaldrive.badge.checkmark")
    }
}
