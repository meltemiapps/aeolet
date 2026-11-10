# Aeolet

An open-source, native Gmail client for iPhone and iPad, in the spirit of K-9 Mail. Free, no ads, no tracking and no server: the app talks directly to Google.

## What it does

- Native SwiftUI client on the Gmail REST API: threads, labels, search, read and unread, star, archive, bin, spam, attachments, reply, reply all, forward, drafts.
- Several Gmail accounts.
- Sign-in with OAuth 2.0 and PKCE in Apple's system sign-in sheet. Your password goes to Google only.
- Refresh tokens in the iOS Keychain, this device only, never iCloud. Access tokens stay in memory.
- HTML mail in a sandbox: no scripts, remote images blocked until you ask, links confirmed before opening.
- Optional Face ID or passcode lock.
- Optional PGP (below).

Requested Google permission: `gmail.modify`. It cannot permanently delete mail.

## Setup

You need a Mac with Xcode (free, Mac App Store), a Google account, and an iPhone.

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
- There is no key recovery. Keep your own backup.

The cryptography is [OpenPGP.js](https://github.com/openpgpjs/openpgpjs), run in a hidden web view whose content policy blocks all network access. Rebuild and test it from `PGP/js` with `npm ci && npm test`.

## Tests

- `AeoletTests`: OAuth PKCE vectors, MIME building and parsing, header-injection protection.
- `PGP/js/test`: 24 checks in a real browser engine under the production content policy, including interoperability with GnuPG in both directions.

## Licence

Apache-2.0. OpenPGP.js is LGPL-3.0-or-later; see `NOTICE`.
