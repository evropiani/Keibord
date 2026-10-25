Keibord 1.0.18: back to the height setup that got the full height. Restart your iPhone after installing.

- Your recordings showed iOS giving Keibord its full height (314 pt) in the App Library until the iPhone restarted, and that height came from versions 1.0.3–1.0.13. Only those versions told iOS that the keyboard sizes itself (allowsSelfSizing). 1.0.14–1.0.17 left that out and got 241 or 224 pt everywhere, whatever else they tried.
- 1.0.18 asks for its height exactly like 1.0.3–1.0.13 again, and keeps everything else that was fixed since (number row, bigger keys when room is short, no crash on opening, Keyboard Log).
- iOS remembers the height it gave a keyboard until the iPhone restarts. So: install 1.0.18, restart the iPhone, then open the keyboard.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
