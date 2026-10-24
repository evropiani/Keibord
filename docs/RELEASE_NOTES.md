Keibord 1.0.11: the keyboard no longer opens blank.

- Sometimes the keyboard opened empty (only 🌐 and the microphone below it) until it was closed or switched. While opening and closing, the keyboard waited for its files; when iOS had paused the Keibord app (or another copy of the keyboard) in the middle of saving, that wait never ended and no keys were drawn. Opening and closing no longer wait for any file: settings are read directly, and what the keyboard learned is saved in the background.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
