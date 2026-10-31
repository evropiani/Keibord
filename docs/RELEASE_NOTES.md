Keibord 1.0.29: automatic backups that work.

- Automatic backup: 1.0.28 said "The backup file was moved or deleted" on every backup: Keibord could not write to a place chosen outside the app. Backups now go into Keibord's own folder, Files › On My iPhone › Keibord, always as Keibord-Backup.json and replacing the last one. Nothing to choose anymore: set the password, tap Back Up Now, and "Show in Files" opens the folder.
- The Shortcuts action "Back Up Keibord" also outputs the file. For a copy in iCloud Drive, add "Save File" after it in your automation (Ask Where to Save off, your folder, Overwrite If File Exists on). Deleting the Keibord app deletes its own folder, so that copy is worth having.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboards), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
