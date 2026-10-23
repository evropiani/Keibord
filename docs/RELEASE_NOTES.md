Keibord 1.0.10: importing a backup works again.

- Data → Import: tapping an exported file in the file picker now opens it. Before, on some iPhones the picker stayed open and nothing happened (an iOS bug in the picker SwiftUI provides; Keibord now uses the UIKit picker).
- Any file can be chosen, even one that lost its ".json" ending when it was sent or saved; Keibord checks the content and tells you if it is not a Keibord backup.

Install `Keibord.ipa` with your signer (keep app groups for the app and the keyboard), SideStore with the Keibord source, or TestFlight (docs/INSTALL-NO-PC.md). Installing over an earlier version keeps your data.
