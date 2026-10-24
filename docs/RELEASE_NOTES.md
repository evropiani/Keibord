Keibord 1.0.17: Keibord now asks for its height the way that works on iOS 26 and 27.

- Every version so far asked for its height with a request that gives way as soon as iOS disagrees (priority 999), so iOS's own 241 pt always won. Keibord now uses a required height request, the way Apple's guide shows and the way azooKey (an open-source keyboard whose users can make it taller on iOS 26) does it.
- The request is made once the keyboard is on screen, and iOS's container around the keyboard is laid out right away so it takes the new height. If iOS shrinks the keyboard again afterwards, Keibord asks again (a few times per opening).
- Number row, bigger keys when room is short, and the Keyboard Log stay as in 1.0.16.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
