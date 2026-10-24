Keibord 1.0.16: bigger keys, a number row that stays put, and a second height request.

- The number row now simply follows the setting. 1.0.13 hid it whenever iOS gave the keyboard too little height, so it came and went from app to app.
- When iOS gives less height than Keibord asks for, the gaps between the rows shrink first and the keys keep their full height as long as possible. Before, keys and gaps shrank together, which made the keys tiny. Without the number row, the keys now keep their full height even in iOS's lowest keyboard (241 pt).
- In some apps (for example after switching from the Apple keyboard) iOS keeps its default height. Keibord now changes its height request once more after it appears, which is when Apple's guide says iOS accepts height changes.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
