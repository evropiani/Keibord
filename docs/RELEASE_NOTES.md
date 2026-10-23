Keibord 1.0.5: taps between keys and around suggestions count.

- iOS gives a keyboard no touches where it draws nothing, and Keibord's background was fully transparent. Taps in the gaps between keys and on the edge of a key did nothing (thin keys like i, j, y were hard to hit), and a suggestion only reacted on the word itself. Every part of the keyboard now has an invisible but touchable background, so a tap between keys goes to the nearest key.
- Each suggestion is tappable across its whole third of the bar (a single hint across the whole bar).

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), or use TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
