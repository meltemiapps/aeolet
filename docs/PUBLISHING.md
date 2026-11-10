# Publishing under Meltemi Apps

## Before submitting

| Item | Status or action |
| --- | --- |
| Name | "Aeolet" passed a knockout screen only. Commission a clearance search, then file in Nice classes 9, 38 and 42. |
| Seller name | Set "Meltemi Apps" as the Apple Developer account name. An individual account shows your legal name; a company account with a D-U-N-S number shows the company. |
| Publisher links | Set `PUBLISHER_URL` and `SOURCE_CODE_URL` in `Config.xcconfig`. They appear under Settings > About. |
| Bundle ID | `com.meltemiapps.aeolet`. Register it in App Store Connect and keep it permanently. |
| Google verification | Required for a public release. See below. |
| Encryption export | PGP is non-exempt encryption. Complete App Store Connect's export compliance questions; France needs separate handling. |
| Privacy policy | Required. State that no data reaches Meltemi Apps and link Google's Limited Use compliance. |

## The Google gate

A public App Store release shares one OAuth client among all users, so the 100-user cap for unverified apps applies. Passing it means Google OAuth verification, because `gmail.modify` is a restricted scope, followed by annual re-verification.

Google's Gmail documentation ties the security assessment to storing or transmitting restricted data on servers, and Aeolet has none. Its general help page says restricted-scope apps are assessed annually. Get Google's position in writing during verification before budgeting either way.

Open-source users building their own copy with their own client ID are unaffected.

## Google Play

Aeolet is iOS only. A Play listing needs a separate Android app.

## Name screening record, 9 November 2026

Sources: WIPO Global Brand Database (EUIPO, Madrid, UK, GR, DE, FR, IT, ES, US, CA, MX, BR, AR, CL, CO), USPTO, App Store (US, UK, DE, BR), Google Play (US), open web.

| Candidate | Result |
| --- | --- |
| Aeolet | Selected. No identical mark in WIPO or USPTO, no same-named app found. An Indian application for AEOLET appears on a commercial lookup site and is outside the target markets. |
| Epistolos | Rejected. EPISTOLA, EU word mark 019395658, classes 9/35/41/42, registered 29 October 2026; E-PISTOLAS, Chile, class 38. |
| Etesian | Rejected. US filing 99464511, Etesian Wind app on both stores. |
| Anemogram | Rejected. Live App Store app in Germany. |
| Meltemail | Set aside. Too close to live MELTEMI marks in class 9 (UK00002379304; Italy, including classes 38 and 42). |

Those MELTEMI marks also matter for the publisher brand "Meltemi Apps". Include it in the clearance search.
