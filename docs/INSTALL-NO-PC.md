# Installing Keibord without a computer (and without weekly refreshes)

With a free Apple ID, every sideloaded app expires after **7 days**, and refreshing it needs a computer or AltStore/SideStore.
The only reliable way around that is a **paid Apple Developer Program membership (€99 / year)**. With it, Keibord can be
installed through Apple's own **TestFlight** app, straight on the iPhone. GitHub builds and uploads it for you.

| | Free Apple ID + Sideloadly | **Paid account + TestFlight (recommended)** | Paid account + Ad Hoc link | Bought "certificate" + Feather |
|---|---|---|---|---|
| Cost | free | €99/year | €99/year | ~€10–25/year |
| Computer needed | every 7 days | **never** (setup works in Safari) | never | never |
| How long it runs | 7 days | 90 days per build, **auto-renewed monthly by GitHub** | 1 year | until Apple revokes the certificate |
| Updates | re-sideload | automatic in TestFlight | tap a link | re-sign in Feather |
| Reliability | ok | **very high (official)** | high | low (revocations are common) |

---

## Recommended: TestFlight, fully automatic

You set this up once (about 30 minutes, all in Safari on the iPhone or in a browser on your Linux laptop). After that:
- you install and update Keibord from the TestFlight app;
- GitHub uploads a fresh build automatically on the 1st of every month, so it never expires (TestFlight builds last 90 days);
- you can trigger a new build any time, e.g. after a change.

### 1. Join the Apple Developer Program (on the iPhone)
1. Install the **Apple Developer** app from the App Store.
2. Open it, go to **Account**, sign in with your Apple ID and tap **Enroll Now**. Enroll as an *Individual* and pay €99.
3. Approval usually takes from a few minutes to 48 hours. You'll get an email.

### 2. Register the identifiers (Safari: developer.apple.com/account)
Tip: in Safari, tap **aA → Request Desktop Website** if a page looks broken.
1. **Certificates, IDs & Profiles → Identifiers → +** → *App Groups* → Description `Keibord`, identifier `group.com.keibord.app` → Register.
2. **Identifiers → +** → *App IDs* → *App* → Description `Keibord`, Bundle ID (explicit) `com.keibord.app`.
   Under Capabilities tick **App Groups** → Continue → Register. Open the new ID again → App Groups → **Configure** → tick `group.com.keibord.app` → Save.
3. Do the same for the keyboard: Description `Keibord Keyboard`, Bundle ID `com.keibord.app.keyboard`, App Groups → same group.
4. Note your **Team ID**: **Membership details** (10 characters, e.g. `A1B2C3D4E5`).

> If Apple says `com.keibord.app` is not available, use your own prefix, for example `at.hamza.keibord`, `at.hamza.keibord.keyboard` and `group.at.hamza.keibord`.
> Then add a repository **variable** `KEIBORD_BUNDLE_ID` = `at.hamza.keibord` in step 5.

### 3. Create the app in App Store Connect (appstoreconnect.apple.com)
1. **Apps → + → New App**. Platform: iOS. Name: `Keibord` (if taken: `Keibord Senad`; this name isn't shown on your home screen).
   Language: German. Bundle ID: `com.keibord.app`. SKU: `keibord`. Access: Full Access → **Create**.
2. You never submit it to the App Store. It only exists for TestFlight.

### 4. Create an API key (lets GitHub sign and upload)
1. App Store Connect → **Users and Access → Integrations → App Store Connect API → Team Keys → +**.
2. Name `GitHub`, Access **Admin** → Generate.
3. Note the **Key ID** and the **Issuer ID** (shown above the list).
4. **Download API Key** (`AuthKey_XXXXXXXXXX.p8`). It can only be downloaded **once**, so keep it safe. Open it in the Files app or a text editor; you need its full text, including the `-----BEGIN PRIVATE KEY-----` lines.

### 5. Add the secrets to GitHub (github.com in Safari)
Repository **evropiani/Keibord → Settings → Secrets and variables → Actions → New repository secret**:

| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | your Team ID |
| `ASC_KEY_ID` | the Key ID |
| `ASC_ISSUER_ID` | the Issuer ID |
| `ASC_KEY_P8` | the whole text of the `.p8` file |

(Only if you changed the bundle ID: tab **Variables → New repository variable** `KEIBORD_BUNDLE_ID`.)

### 6. Build and upload
1. GitHub → **Actions → TestFlight → Run workflow**. It takes about 10 minutes.
2. Apple then processes the build for 5–30 minutes. You'll get an email when it's ready.

### 7. Install on the iPhone
1. App Store Connect → your app → **TestFlight → Internal Testing → +** → create a group (e.g. `Me`) and add yourself as a tester.
2. Install **TestFlight** from the App Store and open the invitation email (or TestFlight shows the app directly). Tap **Install**.
3. In TestFlight, open Keibord and turn on **Automatic Updates**.
4. **Settings → General → Keyboard → Keyboards → Add New Keyboard… → Keibord**, then tap **Keibord → Allow Full Access**.

### Moving your data from the sideloaded version
The TestFlight version is signed by your own team, so it has its own storage.
1. In the **old** Keibord app: **Data → Export Typing Data…**.
2. In the **new** app: **Data → Import Backup… → Replace Everything**.
3. Delete the old sideloaded app afterwards.

### What it costs in GitHub minutes
Each TestFlight run uses about 5 Mac minutes. GitHub bills these ten times over for private repos, so about 50 of the
2,000 free monthly minutes per run. The monthly automatic upload stays far below the free limit.

---

## Alternative: Ad Hoc install link (paid account, no TestFlight)
Apps signed for specific devices ("Ad Hoc") run for **1 year**. You install them by tapping an `itms-services://` link in Safari.
This needs your iPhone's UDID registered in the developer portal. Get it without a computer via a UDID profile site such as
`udid.tech`. It also needs the `.ipa` and a `manifest.plist` hosted on a public HTTPS server, which a private GitHub repo can't provide.
TestFlight is simpler, so this isn't automated here.

## Cheaper, but not recommended: bought certificates + Feather
Resellers sell shared developer certificates for about €10–25/year. You sign the `.ipa` on the phone with an on-device signer such as
**Feather**. Apple regularly revokes such certificates, and your keyboard would then stop working without warning.
For a keyboard you rely on every day (and one with Full Access), the official route is worth the extra money.

## Using the Linux laptop once a year instead
With the paid account you could also sign a 1-year development build and install it over USB from Linux Mint with
`libimobiledevice` (`sudo apt install ideviceinstaller`, then `ideviceinstaller -i Keibord.ipa`). TestFlight avoids even that.
