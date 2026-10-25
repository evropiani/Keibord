Keibord 1.0.20: the suggestions sit in the same place every time.

- iOS draws a thin glass strip (17 pt) above third-party keyboards, and the suggestion bar was laid out for it (the words sit a little above the bar's middle, so they look centred between that strip and the keys). Now and then the strip was missing, and the words then sat right against the top edge.
- It went missing when the keyboard asked for its height again while already on screen: iOS then laid it out anew, sometimes without the strip. Keibord did that on every opening (a leftover from the height fixes), when a field wanted a number pad, and for the emoji search (52 pt taller).
- Now the keyboard sets its height once while it loads and never changes it on screen. Number pads use the same height (with taller keys), and the emoji search takes the room for its search bar from the keys instead of making the keyboard taller.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
