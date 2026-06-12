# Privacy Policy — Cascade Countdown

**Last updated: 2026-06-12**

Cascade Countdown ("the App") is an independent Apple Vision Pro game developed by Alex Coulombe. This policy describes what data the App handles and what it does not.

## Short version

- The App **collects no personal information**.
- The App **does not track you**, does not use advertising identifiers, and contains no third-party analytics, advertising, or tracking SDKs.
- Hand tracking and all gameplay run **entirely on-device**. Camera data never leaves your headset.
- The only data the App transmits is a **three-letter player tag** (which you choose, defaulting to "AAA") and your **round score**, sent to a global leaderboard so other players can see top scores.

## What the App does NOT collect

- Your name, email address, phone number, or any account information
- Your Apple ID, Game Center identifier, or any device identifier
- Your location (GPS, IP-derived, or otherwise)
- Camera images, hand images, room scans, or any spatial-mapping data — these are processed by visionOS on-device for hand tracking and passthrough rendering, and the App never receives raw image or scan data
- Microphone audio
- Contacts, calendar, photos, or any other personal data on your device
- Crash reports beyond what Apple collects through standard system reporting (which you control in Settings → Privacy & Security → Analytics & Improvements)
- Any advertising or marketing identifier (the App has no advertising)

## The one thing the App does transmit

When you complete a 30-second round, the App sends two pieces of information to a leaderboard server so that scores can be ranked globally:

1. **Your three-letter player tag** — a string of exactly three characters (A–Z), which you set yourself in the in-world YOUR TAG panel. Defaults to "AAA" if you don't set one. This is not linked to your Apple ID, your device, or any account.
2. **Your round score** — a non-negative integer.

These two values are sent over HTTPS to a Google Apps Script endpoint at `script.google.com`, which writes them to a Google Sheet and returns the current top-20 list. No other information is included in the request (no IP-based geolocation by the App, no device identifier, no timestamp beyond what HTTPS requests inherently include).

If you do not want any data transmitted, you can:
- Not press START (the leaderboard submit only fires at the end of a timed round), or
- Use the App offline / in airplane mode (the App will continue working; only the leaderboard panel will be empty).

## What the leaderboard server stores

The Google Apps Script backend stores the three-letter tag and score in a Google Sheet owned by the developer. No IP addresses, user agents, or other request metadata are retained by the App's code. Google's own infrastructure may log standard HTTPS request metadata under its own privacy terms — see Google's privacy policy for details.

There is no mechanism for individual deletion of an entry because there is no identifier linking an entry to you. If you would like the entire leaderboard reset, contact the developer (below).

## Children's privacy

The App is rated 4+ and is suitable for all ages. The App does not knowingly collect personal information from anyone, including children under 13. The only data collected is the three-letter tag and score described above, which contains no personal information by design.

## Permissions the App requests

- **Hand tracking** (via Apple's `NSHandsTrackingUsageDescription`) — required for the pinch-to-grab gameplay. Hand-pose data is processed by visionOS on-device and exposed to the App only as anonymous joint poses; no image data is received.

The App does not request access to: camera, microphone, photos, location, contacts, calendar, motion sensors beyond head-pose (which is system-provided), or any other privacy-protected resource.

## Data security

The leaderboard request is sent over HTTPS (TLS). No data is stored on disk by the App other than your local high-score record and your chosen three-letter tag, which are saved in the App's sandboxed `UserDefaults` and are removed when you delete the App.

## Third-party services

The App uses one third-party service:

- **Google Apps Script / Google Sheets** — receives the leaderboard submission described above. See [Google Privacy Policy](https://policies.google.com/privacy).

The App contains no other third-party SDKs, analytics, advertising networks, attribution services, or social-login providers.

## International users

The leaderboard server is hosted by Google and may be located outside your country. By using the leaderboard feature you consent to the transfer of the tag and score values to Google's servers for the purpose described above.

## Changes to this policy

If this policy changes, the updated version will be committed to the App's public source repository at https://github.com/ibrews/godot-avp-cascade and the "Last updated" date at the top will be revised.

## Contact

Questions, concerns, or leaderboard-reset requests:

**Alex Coulombe**
info@agilelens.com

Source repository: https://github.com/ibrews/godot-avp-cascade
