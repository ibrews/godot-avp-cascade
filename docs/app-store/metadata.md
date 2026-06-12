# App Store Listing — Cascade Countdown

Paste-ready copy for App Store Connect. Character counts noted where Apple enforces a limit.

---

## App Name (≤30 chars)

```
Cascade Countdown
```
*17 chars*

## Subtitle (≤30 chars)

Pick one:

1. `Pinch-to-grab AVP arcade` — *24 chars*
2. `Hand-tracked physics arcade` — *27 chars*
3. `Reach in. Grab. Score.` — *22 chars*

Recommended: **#2** (most descriptive for search; "hand-tracked" and "physics" are both searched terms on visionOS).

## Promotional Text (≤170 chars, editable without re-review)

```
30 seconds. 8-colour plasma cubes cascading through your room. Pinch any one mid-air and throw it through the goal ring. Procedural soundtrack rises with the chaos.
```
*168 chars*

## Description (≤4000 chars)

```
Cascade Countdown is a hand-tracked physics arcade game built for Apple Vision Pro.

Glowing 8-colour plasma cubes — randomised sizes, real physics — cascade down through spinning bumpers and a prism splitter onto tilted catch plates in your room. Reach into the cascade, pinch any cube mid-flight, and throw it into the floating goal ring. Every collision synthesises a chime pitch-snapped to the key, so the chaos harmonises into a tune that rises with the action.

Poke START and you've got 30 seconds. Keep cubes alive. Score every goal. Post your three letters to the global top-20 leaderboard.

—— GAMEPLAY ——

• Pinch-to-grab and throw any cube with either hand — anchored to your thumb tip, follows your throw velocity
• Two-hand pinch to scale and rotate the whole world via the floating chrome handle
• 30-second time-attack mode with a global top-20 leaderboard
• Set your own three-letter player tag on the in-world YOUR TAG panel — your scores post under your name
• Grabbable HANDS / START / MUTE / GESTURES / SKY / RESET control panel — move it anywhere in your space
• Real-time procedural soundtrack — every cube collision is a synthesised chime, pitch-snapped so the music never breaks

—— TECHNICAL ——

• 90 FPS locked — zero variance across a 95-second sample
• Mixed-immersion passthrough — cubes composite into your real room, not a virtual one
• ~475 physics collisions per round, simulated on-device
• System wrist menu suppressed during play for uninterrupted immersion
• No ads, no tracking, no account required

—— BUILT WITH ——

Cascade Countdown is built on the open-source Godot game engine using Apple's official visionOS contribution (Godot PR #109975, Ricardo Sanchez-Saez / Apple visionOS team) — the first publicly-documented Godot RigidBody3D physics scene rendering in immersive mode on real AVP at locked 90 FPS with working hand-tracking pickup.

Hand tracking runs entirely on-device through Apple's hand-tracking system. No camera data ever leaves your headset.

—— PRIVACY ——

Cascade Countdown collects no personal information. The leaderboard transmits only your chosen three-letter tag and your round score. There are no ads, no analytics, no tracking, no third-party SDKs.

Made independently by Alex Coulombe. Not affiliated with, endorsed by, or sponsored by the Godot Foundation. "Godot" is a trademark of the Godot Foundation.
```
*~2,400 chars — comfortable headroom*

## Keywords (≤100 chars, comma-separated, no spaces after commas)

```
hand tracking,physics,arcade,immersive,vision pro,pinch,grab,cascade,leaderboard,godot,passthrough
```
*107 chars — TRIM ONE before pasting*

Trimmed (98 chars):
```
hand tracking,physics,arcade,immersive,vision pro,pinch,grab,cascade,leaderboard,passthrough
```

Notes on keyword strategy:
- Don't repeat words already in the app name/subtitle — Apple indexes those separately.
- "vision pro" works as two words; Apple tokenises commas.
- "godot" is searchable but optional — drop if you need room for other terms.

## What's New in This Version (≤4000 chars)

For build 8:

```
Set your own three-letter player tag on the new YOUR TAG panel — your scores now post to the global leaderboard under your initials instead of a shared default.

The leaderboard panel now shows the top 20 players (was top 10).

Shockwave VFX timing polish on the goal ring.
```

## Support URL (required)

```
https://github.com/ibrews/godot-avp-cascade
```

(Or set up a simple support page — but the GitHub README + Issues tab is acceptable for a free indie app and Apple accepts it.)

## Marketing URL (optional)

```
https://github.com/ibrews/godot-avp-cascade
```

Same as support, or point at the README's TestFlight section. If you create a one-pager landing page later, swap it in.

## Privacy Policy URL (required)

```
https://github.com/ibrews/godot-avp-cascade/blob/main/docs/privacy-policy.md
```

(See [`privacy-policy.md`](../privacy-policy.md) in this repo — committed alongside this file.)

## Category

- **Primary:** Games → Arcade
- **Secondary:** Games → Action

(Apple lets you pick one game subcategory + one general category, or two game subcategories.)

## Age Rating

Answer **NO** to every question in the age rating questionnaire. No violence, no realistic violence, no sexual content, no profanity, no horror themes, no gambling, no medical info, no unrestricted web access. Result: **4+**.

## Content Rights

- "Does your app contain, display, or access third-party content?" → **No** (the game is fully procedural; no third-party content is bundled or fetched).

## Export Compliance

- "Does your app use encryption?" → **No** — Cascade Countdown does not implement, use, or access any cryptographic algorithms beyond what's exempt under U.S. Export Administration Regulations §740.17(b) (i.e. the HTTPS used by `HTTPRequest` is exempt as Apple's standard system HTTPS for app updates / data submission).
- The exempt-only status means you can answer **"Yes"** to "Does your app use encryption?" and then **"Yes"** to "Does it qualify for the exemption?" — this is the simpler path and avoids any future ITSAppUsesNonExemptEncryption flag in Info.plist.

Recommended answer: **Yes → Exempt** (cleanest, future-proof).

## Pricing & Availability

- **Price:** Free
- **Availability:** All territories (or pick a subset if there's a reason to gate)
- **Pre-order:** Not applicable (already shipping via TestFlight)

## Build Selection

Pick build **8** (or whichever is latest at submission time) from the TestFlight builds list. It's already uploaded and processed.

## App Privacy ("Nutrition Label")

This is filled in via App Store Connect's questionnaire (NOT via the API in practice). Answer:

- **Data Used to Track You:** None
- **Data Linked to You:** None
- **Data Not Linked to You:**
  - **Gameplay Content** (the 3-letter tag + score sent to the leaderboard)
    - Used for: **App Functionality**
    - Linked to user: **No**
    - Used for tracking: **No**

That's it. One disclosed data type, the most minimal possible.

---

## Screenshots — REQUIREMENTS

**visionOS App Store requires 3840 × 2160 PNG or JPG screenshots.** Minimum 1, maximum 10. Recommended: 4–6.

Existing captures in `captures/` are 1280×720 or 1920×1080 — **none meet spec**. You'll need to recapture via:

1. Put on the AVP (with Dev Strap attached)
2. Xcode → Window → **Devices and Simulators**
3. Select Apple Vision Pro in the left pane
4. Click **Take Screenshot**
5. Repeat for each shot you want

**Suggested 6-shot sequence (in display order):**

| # | Shot | Why |
|---|---|---|
| 1 | Cascade in full flow with hand mid-grab, goal ring visible | Hero shot — sells the whole game in one image |
| 2 | Two-hand world-scaling via chrome handle, room visible | Shows the "passthrough into your room" hook |
| 3 | START countdown active, score visible, multiple cubes airborne | Time-attack mode legibility |
| 4 | Leaderboard panel grabbed close to viewer, top scores visible | Social/competitive hook |
| 5 | YOUR TAG panel mid-interaction (poke ▲/▼ on a letter) | Shows depth of interaction |
| 6 | Celebration moment — fanfare after beating personal best | Emotional payoff |

## App Preview Video

`captures/CascadeCountdown_trailer.mp4` — 1920×1080, 30s, with audio. ✅ Within spec.

Apple Vision Pro App Preview spec: max 30s, 30 fps, .mov or .mp4, H.264 or HEVC. The existing trailer fits. Upload as-is.

**One thing to check before upload:** App Preview videos cannot show:
- The Apple Vision Pro hardware
- The home view / system UI
- Hand drift outside your app's space

Scan the trailer for any of those and trim/swap frames if present.
