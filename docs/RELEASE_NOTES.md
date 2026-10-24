Keibord 1.0.12: the keyboard repairs itself when it opens blank or collapsed.

- Shortly after opening, the keyboard checks that its keys are drawn and that iOS gave it its height. If the keys are missing, it draws them again; if iOS left it collapsed (only 🌐 and the microphone) or at another height, it asks again, several times.
- Keys are also drawn when iOS shows the keyboard without announcing it first (that left it blank).
- New: Data → Keyboard Log. The keyboard notes when it opens and closes, its size, its memory use and whether it stopped responding (never what you type). If the keyboard still opens blank, open the log right after, tap Copy and send it.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
