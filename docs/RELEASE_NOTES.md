Keibord 1.0.14: full height and keys from the first moment.

- Your logs showed that iOS always gave Keibord 241 pt, whatever it asked for afterwards, and that iOS sometimes loaded the keyboard without ever announcing it, so no keys were drawn (blank or collapsed until reopened).
- Keibord now draws its keys and sets its full height while it loads, before iOS decides how tall the keyboard is, and keeps that one height request instead of asking again and again (which never helped and could confuse iOS).
- If iOS loads the keyboard and does not announce it within a second, it now prepares itself anyway and notes it in the Keyboard Log.
- Where a host keeps keyboards low (Spotlight: 241 pt), the number row still makes way so the keys keep their size.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
