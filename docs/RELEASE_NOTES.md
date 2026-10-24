Keibord 1.0.13: normal-sized keys in Spotlight, fewer collapsed or empty keyboards.

- Spotlight (and any app that keeps keyboards lower than they ask for) squeezed all rows together, so the keys were tiny. When there is not enough room, the number row now makes way and the other keys keep (nearly) their normal size. It comes back as soon as there is room.
- iOS sizes a keyboard in several steps when it opens (no height, full screen, then the requested height). Keibord asked for its height again in between, which could leave it collapsed (only 🌐 and the microphone) or empty. It now asks only once iOS is done: 0.5 s and 1.5 s after opening, and only if the height is still wrong.
- If the keyboard still opens collapsed or empty: open Keibord right away → Data → Keyboard Log → Copy, and send it. It shows what iOS did (never what you type).

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
