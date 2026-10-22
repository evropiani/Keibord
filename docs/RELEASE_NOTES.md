Keibord 1.0.1: a full test and bug-fix round over the whole keyboard and app.

Typing
- Better autocorrect in all five languages: German noun twins ("die zeit" → "Zeit"), accents restored across languages ("perche" → "perché", "eshte" → "është"), sentence context picks the language, English names capitalised ("john" → "John")
- Cleaner dictionaries: everyday and Austrian words checked ("Jänner", "Paradeiser", "Sackerl", "leiwand"), fewer subtitle artefacts and false names, common word pairs for predictions
- Smart quotes, double-space period, abbreviations ("z.B.", "Dr.") and spacing after suggestions fixed in many edge cases
- No autocorrect inside URLs, e-mail addresses and shortcut phrases; no word suggestions with the cursor inside a word

Keyboard
- Hold shift to type several capitals; in landscape the keys stay clear of the rounded corners and the notch
- Fixed multi-key rollover, two-thumb capitals, preview balloons and long-press menus at the screen edges
- Space-bar cursor no longer drifts; globe key and edge keys behave like the system keyboard
- Learning is kept when a save fails and is loaded in the background; less work per keystroke
- Emoji search finds inflected words; skin tones for more emoji

App and data
- Export never leaves out learned data; import asks again for a wrong or empty password and explains damaged files
- Card vault and device secret can no longer be overwritten by stale copies
- Damaged settings or learning files are repaired entry by entry instead of being reset

Install `Keibord.ipa` with Sideloadly/AltStore/SideStore, or use TestFlight (docs/INSTALL-NO-PC.md). Installing over 1.0.0 keeps your data; for a fresh install use Export/Import in the app.
