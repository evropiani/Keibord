Keibord 1.0.4: fewer missed taps.

- iOS watches the screen edges for system gestures and delayed or cancelled touches on the keys there (q, a, y, p, ü, ä, shift, backspace), so fast taps were sometimes lost. Keibord now switches those delays off on every view around the keyboard (newer iOS versions moved them off the keyboard's window), and a short tap that iOS cancels anyway still types its key. A swipe or a held finger that iOS cancels still types nothing.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), or use TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
