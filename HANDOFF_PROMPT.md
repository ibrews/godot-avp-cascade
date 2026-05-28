# HANDOFF — Next session pickup brief

**Current state as of 2026-05-27 (end of evening session):** v5 committed and pushed. Build succeeded. **NOT yet installed on device** — AVP was asleep at wrap time. Install is the first thing to do next session.

**Read this whole file before doing anything.** Self-contained pickup — no prior transcript needed.

## First thing next session

```bash
# 1. Install v5 (put headset on first — AVP sleeps when not worn)
xcrun devicectl device install app \
  --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  $(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app)

# 2. Verify 90 FPS still holds with v5 (per-cube materials + 12 particles × 25 cubes = 300 total)
xcrun devicectl device copy from \
  --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  --source "Documents/xr_diag.txt" \
  --destination /tmp/xr_diag.txt \
  --domain-type appDataContainer \
  --domain-identifier com.agilelens.godotvisionpilot
cat /tmp/xr_diag.txt
# Per-5s delta must be 450. If it drops: reduce particles.amount from 12→8.
```

## What's working right now

- **Mixed immersion** confirmed — cubes composite into real room, no artifacts
- **Spatial audio** confirmed — chimes attenuate with distance, stereo panning works
- **PR comment live** on godotengine/godot#109975 — positive reply from @stuartcarnie
- Info.plist tracked at `out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist` (`UIImmersionStyleMixed`)

## What changed in this session (v5, built not installed)

1. **8-colour palette** — orange, amber, yellow, deep-red, white-hot, electric violet, ice blue, hot pink
2. **Per-cube random size** — 6–12 cm; mass scales with volume (small cubes bounce faster)
3. **Per-cube emission energy** — 1.2–3.5× for visual variety
4. **Per-cube colour-matched particle trails** — 12 quads per cube (up from 8), tinted to match cube colour
5. **Collision flash light** — `OmniLight3D` repositioned to impact point, energy 3.5 → 0 in ~160ms; illuminates plates/wall (PER_PIXEL shaded), not cubes (UNSHADED)
6. **Dual collision sounds** — cube-on-plate: resonant chime 260–700 Hz with octave harmonic; cube-on-cube: bright tink 700–1500 Hz, 36ms

## Tomorrow's agenda (tabled from this session)

### 1. Hand tracking — coordinate with Marshall first

**Marshall (Nocxr) has hand tracking working.** Talk to him before writing any hand-tracking code. Find out:
- Which branch is his working build on? (Clancey's `visionos_interactions_master_rebase`, or did he get it on rsanchezsaez's branch?)
- Does he have individual joint data, or just grip/pinch actions?
- Is hand-as-collision-mesh already solved, or just pinch gesture?

Plan once we know his state:
- **If he's on the same rsanchezsaez branch**: add hand collision mesh directly (5 `AnimatableBody3D` capsules at fingertips, updated from `XRHandTracker` each frame). Grab/throw: detect pinch distance < 25mm → parent cube to pinch point; on release → apply velocity from last 3-frame delta.
- **If he's on Clancey's fork**: decision point — port Cascade to his branch, or wait for upstream.

### 2. Progressive immersion + skybox (quick wins, ~15 min)

- Change Info.plist `UIImmersionStyleMixed` → `UIImmersionStyleProgressive`
- Digital Crown lets user blend 0% (mixed) → 100% (full) at will
- Add `WorldEnvironment` with `ProceduralSkyMaterial` (or shader starfield) — visible at full Crown rotation
- Background alpha stays 0 in mixed range; sky only shows at or near full immersion

### 3. README GIF — now is the right time

v5 has the full visual: mixed mode, 8 colours, sized cubes, coloured particles, flash light. Capture when confirmed on device. AirPlay → QuickTime → 7–10s clip → ffmpeg two-pass palettegen, 720×405, 15fps → replace `captures/cascade.gif`.

## Longer-term (not this sprint)

- **Room surface detection** (physics cubes bounce off real furniture) — requires ARKit `ARMeshAnchor` + Swift GDExtension bridge. Real sprint.
- **Image detection for world centering** — same layer, `ARImageTrackingConfiguration`. Same cost.
- **Programmatic immersion toggle** (button/gesture in-app) — needs Swift `updateImmersionStyle()` shim. One sprint.

## Dev Strap install gotcha

`xcrun devicectl device install` fails if AVP is asleep. Put headset on first, retry 2–3×.

## Read these FIRST

1. [`CLAUDE.md`](CLAUDE.md) — build loop, critical constraints, do-nots
2. KB: [`intelligence/techniques/godot-visionos-xr.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-visionos-xr.md)
3. KB: [`intelligence/techniques/godot-avp-falling-cascade.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-avp-falling-cascade.md)

## Critical contacts

- **Marshall Nowak** (Nocxr) — Agile Lens. Slack `U04MR6H85K6`. Arizona (no DST). **Has hand tracking working — talk to him before writing hand-tracking code.**
- **Alex Coulombe** — pilot owner. One round-trip ≈ 3–4 min.

## Don't break what works

- `main.tscn` is the fallback minimal scene. Keep it.
- `XROrigin3D.current = true` in main_v2.tscn — silent killer if removed.
- Connect `body_entered` AFTER `add_child()` on RigidBody3D.
- `out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist` is tracked — don't overwrite with a full `--export` without re-applying `UIImmersionStyleMixed`.

## State of the working tree

```
Pilot repo: /Users/alex/godot-visionos-pilot/ (git, branch main, public on GitHub)
KB: ~/knowledge/ (separate repo)

Critical files:
  test-project/main_v2.gd                                      # Cascade script (v5)
  test-project/main_v2.tscn                                    # scene (ExtResource → main_v2.gd)
  test-project/main.tscn                                       # fallback minimal scene
  test-project/project.godot                                   # XR project settings
  test-project/export_presets.cfg                              # visionOS export config
  out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist  # immersion=Mixed (TRACKED)
  Godot.app/                                                   # custom binary (gitignored)
  rsanchezsaez-godot/                                          # engine source (gitignored)
  captures/                                                    # cascade.gif = pre-v5, update when ready
```
