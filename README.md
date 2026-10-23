# Keibord

A private, fully on-device iOS keyboard that looks and feels like the iOS keyboard, with customization on top.
No network code anywhere: dictionaries, autocorrect and learning all run on your iPhone.

## Features

- **Languages:** German (Austria), English (UK & US), Albanian (Albania & Kosovo), Italian. QWERTZ or QWERTY per language (German: ü/ö/ä keys, Albanian: ç/ë keys).
- **Multilingual typing:** suggestions and autocorrect across all enabled languages at once. The language key switches the layout (hold it for a list).
- **Autocorrect & predictions:** spelling and typo correction, accent restoration (`eshte` → `është`, `perche` → `perché`), German noun capitalization (`haus` → `Haus`), next-word predictions, undo a correction with backspace.
- **Learning:** learns your words and word pairs, plus where you tap each key (adaptive touch model). Incognito mode, dictionary editor and blocked words.
- **Move devices without losing data:** export your typing data (learned words, word pairs, touch model, emoji history), all settings and your details – any combination, e.g. settings only – as a JSON file, optionally password-encrypted (AES-256). An import only changes what the file contains; typing data can be merged or replaced.
- **Look & feel:** iOS-style keys, key previews, long-press accents, space-bar cursor control, caps lock and held shift, smart quotes per language („…“, “…”), double-space period, number row, light/dark/custom colours, key size, corner radius.
- **Tinted keys:** pick one or many keys that always stay in a colour of your choice.
- **Emoji:** full Emoji 17.0 set with skin tones (both people's tones for 🤝 💏 👫 …, the last chosen tone is remembered), recents and search in German, English, Italian and Albanian.
- **Local AutoFill:** your own email/phone/address/name values are suggested in matching fields. Saved bank cards: number and expiry are stored encrypted, the CVV is never stored, and with “Require CVV” a card only unlocks when you type its CVV.
- **Text replacements:** Keibord shortcuts, plus your iOS text replacements.

### What iOS does not allow third‑party keyboards to do
- Password fields always switch to Apple's keyboard (so password AutoFill keeps working there).
- AutoFill of passwords, one-time codes from Messages/Mail, and Wallet cards is only available in Apple's keyboard. In code fields Keibord shows a one-tap switch to the iOS keyboard. You can also long-press any text field → **AutoFill**.
- No dictation (keyboards can't use the microphone). Some apps (often banking apps) block custom keyboards.

## Install (no Mac needed)

> **No computer, no weekly refresh:** with a paid Apple Developer account (€99/year), Keibord installs and auto-updates through TestFlight. See **[docs/INSTALL-NO-PC.md](docs/INSTALL-NO-PC.md)**. The steps below are for a free Apple ID.

1. Download `Keibord.ipa` from the latest [GitHub release](../../releases).
2. Install **Sideloadly** (Windows or macOS) and connect your iPhone by cable. Sign in with your free Apple ID and sideload the IPA.
3. On the iPhone, trust the developer profile under **Settings → General → VPN & Device Management**. Then enable **Settings → Privacy & Security → Developer Mode** and restart.
4. Go to **Settings → General → Keyboard → Keyboards → Add New Keyboard… → Keibord**. Tap **Keibord → Allow Full Access**. Full Access is needed for learning, syncing with the app, cards and haptics. Keibord contains no networking code.
5. Open the Keibord app to choose languages, layouts, colours and tinted keys.

**Free Apple ID notes:** apps must be re-signed every 7 days. Sideloadly can auto-refresh over Wi-Fi, or use AltStore/SideStore for on-device refresh. Your data survives re-installing with the same Apple ID. The app plus its keyboard use 2 of your App IDs. If you use AltStore, it counts as one of the 3 active apps.

**Troubleshooting:** the app's **Data → Diagnostics** section shows whether the shared app group works. If “Shared storage” is “No”, the keyboard still types, but settings and learned data aren't shared with the app. Re-sideloading with AltStore/SideStore usually fixes this.

## Building

Every push to `main` runs CI (`.github/workflows/build.yml`):
- Core tests run on Linux.
- The iOS project is generated with XcodeGen (`project.yml`) and built unsigned on macOS. The app and keyboard are then ad-hoc signed with their entitlements and packaged as `Keibord.ipa` (a workflow artifact).
- Tags `v*`, or a manual run of the Build workflow with `release_tag` set, publish a GitHub release with the IPA (notes: `docs/RELEASE_NOTES.md`).

Run core tests locally with `swift test --package-path Core`. Dictionaries are rebuilt with `tools/build_dictionaries.py`, emoji data with `tools/build_emoji.py`, the icon with `tools/make_icon.py`. The design is described in `docs/ARCHITECTURE.md`.

Data sources: OpenSubtitles word frequencies (FrequencyWords, CC-BY-SA 4.0), LibreOffice Hunspell dictionaries, Google Books Ngram (CC BY 3.0), Unicode emoji & CLDR annotations. Personal use.
