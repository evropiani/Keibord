import AppIntents

/// The Shortcuts action for automatic backups (`AutoBackup`). It needs no input: the password and the
/// backup file are set up in the app, so a daily automation is just this one action.
struct BackUpKeibordIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up Keibord"
    static var description = IntentDescription("Saves an encrypted backup of your typing data, settings and details into the Keibord-Backup.json file saved from Keibord (Data › Automatic Backup), replacing the last one.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = try AutoBackup.shared.run()
        return .result(dialog: "Keibord backed up (\(summary)).")
    }
}

/// Makes the action available in Shortcuts and Spotlight without adding anything.
struct KeibordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BackUpKeibordIntent(), phrases: ["Back up \(.applicationName)"],
                    shortTitle: "Back Up Keibord", systemImageName: "externaldrive.badge.checkmark")
    }
}
