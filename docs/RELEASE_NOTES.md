Keibord 1.0.3: settings that reach the keyboard, and the same keyboard height everywhere.

Settings
- iOS only lets a keyboard read what its app saved when Full Access is on and the app and keyboard share an app group. When that link is missing, the keyboard now says so in every empty text field ("Allow Full Access to use your settings", or "No link to the Keibord app"); tap the hint for the steps. Before, the hint was hidden behind the first-word suggestions.
- The app's status explains what is missing instead of showing a green "Shared storage" that only the app itself could see.

Keyboard height
- The keyboard asks for its height the way content-sized keyboards do and asks again whenever iOS lays it out at another height, so it should have the same height in every app. Where iOS still refuses, the rows shrink to fit instead of being cut off.

Install `Keibord.ipa` with your signer, or use TestFlight (docs/INSTALL-NO-PC.md). Your signer must keep the app group for both the app and the keyboard, otherwise settings cannot reach the keyboard. Installing over an earlier version keeps your data.
