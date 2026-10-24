Keibord 1.0.15: fixes 1.0.14, which did not open at all.

- 1.0.14 read the text field's identifier while the keyboard was loading, before iOS had connected the field. iOS has none to give then, and the keyboard crashed every time it opened. The keyboard now reads nothing from the text field until iOS connects it; the keys and the height are still set while it loads.
- Everything else from 1.0.14 stays: one height request set while loading, keys drawn even if iOS does not announce the keyboard, the number row making way where a host keeps keyboards low (Spotlight).

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
