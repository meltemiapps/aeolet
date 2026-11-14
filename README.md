# Aeolet

An open-source, native Gmail client for iPhone, iPad and Mac, in the spirit of K-9 Mail. Free, no ads, no tracking and no server: the app talks directly to Google.

## What it does

- Native SwiftUI client on the Gmail REST API: threads, labels, search, read and unread, star, archive, bin, spam, attachments, reply, reply all, forward, drafts.
- Attach photos from the Photo Library (Apple's picker, so no access to your library is requested) and files from the Files picker, which includes iCloud Drive, Google Drive and any other installed provider. Photos go out as JPEG with their location removed unless you turn on Settings > Keep photo originals. Compose shows each attachment's size and keeps the total within Gmail's 25 MB limit.
- Preview received attachments with Quick Look, save them to Files or pass them on with the share sheet.
- Several Gmail accounts.
- Sign-in with OAuth 2.0 and PKCE in Apple's system sign-in sheet. Your password goes to Google only.
- Refresh tokens in the iOS Keychain, this device only, never iCloud. Access tokens stay in memory.
- HTML mail in a sandbox: no scripts, remote images blocked until you ask, links confirmed before opening.
- Optional Face ID or passcode lock.
- Optional PGP (below).

Requested Google permission: `gmail.modify`. It cannot permanently delete mail.

## On the Mac

A native SwiftUI Mac app (macOS 14 or later), not an iPad port. It shares all non-UI code with iOS (`Shared/`): the Gmail client, sign-in, Keychain, MIME, PGP and the mail cache. One App Store purchase covers iPhone, iPad and Mac.

- Three columns: accounts and labels, conversations, the conversation.
- Menus and shortcuts: ⌘N new message, ⌘R reply, ⇧⌘R reply all, ⇧⌘F forward, E archive, ⌘⌫ Bin, ⇧⌘U read or unread, ⇧⌘L star, ⌘O open in a new window, ⌘F search, ⇧⌘N get new mail, ⇧⌘D send, ⌘, Settings.
- Compose in its own window, several at once. Drag files in to attach them; drag attachments out to Finder or into a message; Save Attachment puts a file in any folder you choose, including Google Drive for desktop if it is installed.
- Checks for new mail on a timer while it is open (every 5 minutes by default), with notifications and the unread count on the Dock icon. Optional Open at Login. No server and no push, so nothing arrives while Aeolet is closed.
- Same security as iOS: sign-in in Apple's system sheet with PKCE, refresh tokens in the data protection keychain (this Mac only, never iCloud), App Sandbox limited to outgoing network, files you choose and Downloads, Hardened Runtime, and an optional Touch ID or password lock that engages when Aeolet is hidden, the Mac sleeps or the screen locks.

## Setup

You need a Mac with Xcode (free, Mac App Store), a Google account, and an iPhone or just the Mac.

### 1. Create your Google OAuth client (free)

1. In [Google Cloud Console](https://console.cloud.google.com), create a project and enable the **Gmail API**.
2. Under **Google Auth Platform**, set Audience to **External**, and add the scope `https://www.googleapis.com/auth/gmail.modify` under **Data Access**.
3. Under **Clients**, create an **iOS** client with bundle ID `com.meltemiapps.aeolet`.
4. Under **Audience**, choose **Publish app**. Leaving it in Testing makes Google expire your sign-in every 7 days. No verification is needed for your own use, up to 100 users; you will click through an "unverified app" warning at sign-in.

### 2. Build

1. Open `Config.xcconfig`. Set `GOOGLE_CLIENT_PREFIX` to the part of the client ID before `.apps.googleusercontent.com`.
2. Open `Aeolet.xcodeproj`.
3. Select the Aeolet target, then **Signing & Capabilities**, and choose your team. If the bundle ID is taken for your team, change it in `Config.xcconfig` and in the Google client.
4. Plug in your iPhone and press Run. Enable Developer Mode on the phone when iOS asks.
5. For the Mac, choose the **AeoletMac** scheme and **My Mac**, then Run. The Mac app uses the same iOS client ID. Xcode registers your Mac with your team the first time, because the data protection keychain needs a provisioning profile.

With a free Apple account the app stops opening after 7 days until you run it from Xcode again. The paid Apple Developer Program removes that limit and adds TestFlight.

## New-mail behaviour

Instant Gmail push needs a server, and this project deliberately has none. New-mail alerts use iOS background refresh, so timing is up to iOS and can be delayed by minutes or hours. Mail is always current when you open the app.

## PGP

Off by default; enable under Settings. Standard OpenPGP and PGP/MIME (RFC 3156), compatible with GnuPG, Thunderbird and Proton Mail.

- Generate a key or import your own. Private keys live in the Keychain, device-only, and must have a passphrase.
- Passphrases are held in memory and forgotten when the app leaves the foreground.
- Encrypted content is decrypted on demand, kept in memory and never written to the cache. Remote content is always off for encrypted mail.
- Encrypted mail never falls back to plaintext. A recipient without a key blocks sending.
- Subject lines, senders and recipients are not encrypted. That is how OpenPGP email works.
- Bcc and draft saving are refused while encrypting, because each would leak information.
- Contact keys are not trusted until you confirm the fingerprint.
- There is no key recovery. Keep your own backup: Settings > Keys > Export private key saves the key, still locked with its passphrase, through the share sheet.
- The inbox shows "Encrypted message" or "Signed message" instead of raw PGP armour.

The cryptography is [OpenPGP.js](https://github.com/openpgpjs/openpgpjs), run in a hidden web view whose content policy blocks all network access. Rebuild and test it from `PGP/js` with `npm ci && npm test`.

## Tests

- `AeoletTests`: OAuth PKCE vectors, MIME building and parsing, header-injection protection, error wording, the remote-content policy, and an OpenPGP round trip through the app's own engine.
- `AeoletMacUITests`: the Mac app end to end against the same mock: three-column browsing, search, keyboard shortcuts (E, ⌘⌫, ⇧⌘L, ⇧⌘U, ⌘O), compose windows with send, reply, reply all, forward and the save-draft prompt, saving attachments and dragging them into a message, two accounts and signing out, Google's errors and offline. `AeoletTests` also runs on macOS.
- `AeoletUITests`: the whole app driven end to end in the Simulator: sign-in, inbox, search, labels, compose with attachments (photos converted and stripped of location, any file type, the 25 MB limit, the real system pickers), previewing, saving and sharing received attachments, reply, reply all, forward, archive, star, read and unread, Bin, two accounts and signing out, remote images, Face ID lock, PGP between two accounts, Google's error responses and offline. They never touch a real Gmail account.
- `PGP/js/test`: 24 checks in a real browser engine under the production content policy, including interoperability with GnuPG in both directions.
- `Scripts/check-release-excludes-mock.sh [ios|mac]`: builds Release and fails if any trace of the mock below is in it.

```sh
xcodebuild test -project Aeolet.xcodeproj -scheme Aeolet -destination "platform=iOS Simulator,name=iPhone 17"
xcodebuild test -project Aeolet.xcodeproj -scheme AeoletMac -destination "platform=macOS"
```

Mac UI tests need UI automation, which macOS turns on after asking for your password the first time, and they take over the mouse while they run. Mock runs on a Mac keep their own Keychain items, files and preferences, so they never touch your real sign-in.

### Mock Gmail

Debug builds launched with `-AeoletMockGmail` answer every Google request from an in-memory Gmail with two fictional accounts and about 30 threads (`Aeolet/Debug`). Sign-in skips Google's page but still goes through the token exchange. `-AeoletResetState` starts from a clean install (of the mock's own data, on a Mac), and `AEOLET_MOCK_FAULT` (`401`, `403`, `429`, `500`, `missingField`, `offline`) simulates failures. Compose's Photo Library and Files pick fixtures, chosen with `AEOLET_MOCK_PHOTOS` and `AEOLET_MOCK_FILES`, unless `-AeoletRealPickers` opens Apple's pickers. None of it is compiled into Release builds.

## Security

Please report security problems privately to developer@meltemiapps.co.uk. See [SECURITY.md](SECURITY.md).

## Licence

Apache-2.0. OpenPGP.js is LGPL-3.0-or-later; see `NOTICE`.
