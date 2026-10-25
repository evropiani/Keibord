Keibord 1.0.21: the suggestions no longer sit against the top edge in apps.

- iOS draws a thin glass strip (17 pt) above third-party keyboards, but not everywhere: it is always there in Spotlight and the App Library, while apps start without it and only get it after switching apps (or after Apple's own keyboard, for example in a password field). Other keyboard developers have reported the same to Apple. A keyboard cannot tell whether the strip is there.
- Since 1.0.8 the suggestions were placed for the strip, so in apps without it they sat right against the top edge. They now sit 6 pt lower, between the two cases: a little high without the strip, a little low with it, and never against the edge.
- 1.0.20 blamed height changes for the missing strip; that was wrong (the strip comes and goes by itself). Its changes stay: the keyboard keeps one height on every page.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
