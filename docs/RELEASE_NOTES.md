Keibord 1.0.19: light and dark mode stay put.

- The app: coming back to Keibord, iOS sometimes left it light while the iPhone was in dark mode, or showed a mix of both (iOS draws apps in both styles for the app switcher when they go to the background and did not always switch back). The app now follows the iPhone's light/dark setting directly, also when it changes while the app is open.
- The keyboard: since 1.0.14 it prepares its keys while it is still loading, before iOS tells it whether the app wants a light or dark keyboard, and that guess could flash the wrong colours for a moment. The keys are still prepared early (for the full height) but stay invisible until the appearance is known.
- The keyboard previews in Theme & Keys and Tinted Keys now start in the iPhone's current style instead of always light.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
