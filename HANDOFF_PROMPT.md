# HANDOFF — Next session pickup brief

**Current state as of 2026-05-29:** Hand tracking is **WORKING on device** — pinch-grab + throw, 90 FPS, mixed immersion, compositing into the real room. Catch plates and the deflector wall are grabbable too. All committed and pushed.

**Read this whole file before doing anything.** Self-contained — no prior transcript needed.

## ⚠️ The single most important thing to know

**The working engine is a borrowed binary that is NOT in git.** Hand tracking only works because we swapped Marshall Nowak's Clancey-fork `libgodot.a` into our xcframework. The whole `GodotVisionPilot.xcframework/` is untracked (this repo is PUBLIC, the lib is borrowed + 181MB, so it must stay out of git). **A fresh clone, or any `--export` that regenerates the xcframework, reverts to the rsanchezsaez render-only engine and silently loses hand tracking** (cubes render, nothing grabbable, no permission prompt).

**FIX after a fresh clone or a full export: run `scripts/restore-engine-lib.sh`.** It copies the canonical lib from the local archive into the device slice and verifies the sha256. One command, then rebuild.

- Working/canonical lib sha256: `179446a8434682f197aab1c709e832d1c6ba3b5c7374b36353861613052901fc` (verified on device 2026-05-30 — drives the white skinned hand mesh + grab/throw). This is NEWER than the `85f0afd`/`f86892fe` build the MANIFEST originally described.
- Working lib lives at: `out/xcode-visionos/GodotVisionPilot.xcframework/xros-arm64/libgodot.a` (Clancey `visionos_master_pr`, `4.6.2.rc.custom_build`)
- Rollback copy: `out/xcode-visionos/GodotVisionPilot.xcframework/xros-arm64/libgodot.a.rsanchezsaez.bak`
- Durable archive: `~/godot-engine-bin-archive/clancey-handtracking-4.6.2/` — now holds the canonical working lib as `libgodot.a.xros-arm64.WORKING-179446a8` (what the restore script reads) alongside the older `f86892fe` build. **Still needs offsite/NAS backup — it's the only copy outside this Mac's working tree.**
- Full recipe: KB [`godot-avp-hand-tracking-engine-swap.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-avp-hand-tracking-engine-swap.md)

## What's working (verified on device 2026-05-28/29)

- **Cube cascade** — 8-colour palette, randomised sizes, collision flash light, dual collision audio (plate chime vs cube tink), 90 FPS locked
- **Mixed immersion** — composites into the real room, no halo artifacts
- **Hand tracking** — pinch near any cube (0.3 m grab radius) → highlights yellow, snaps to pinch, throws with hand velocity on release
- **Grabbable plates + wall** — pinch and reposition; they stay put on release (frozen kinematic, `freeze_on_release`)

## How hand tracking actually works here (the three layers)

1. **Engine** (Clancey `visionos_master_pr`) — the ONLY layer that bridges ARKit hand tracking into Godot's `XRHandTracker`. rsanchezsaez has none. This is why the swap was necessary.
2. **Permissions** — `NSHandsTrackingUsageDescription` + `NSWorldSensingUsageDescription` in the tracked Info.plist (`out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist`). `--export-pack` does NOT regenerate this file — edit it directly. Empty `.entitlements` is fine.
3. **Project** — `openxr/extensions/hand_interaction_profile=true` in project.godot; `PickupHandler3D`/`PickupAbleBody3D` (Marshall's, derived from godot-xr-tools Function_Pickup); two `XRController3D` (left_hand/right_hand) built procedurally in `_setup_hands()`.

## Critical build gotchas (learned the hard way this session)

- **Version gap:** our editor (`Godot.app`) is 4.6.3.stable; the runtime lib is Clancey 4.6.2.rc. `script_export_mode=0` (Text) in `export_presets.cfg` is REQUIRED so the 4.6.2 runtime compiles scripts from source — binary tokens (mode 2) silently fail to load → passthrough-only. Don't revert this until editor and lib are version-matched.
- **Headless-verify before every device round-trip:** `Godot.app/Contents/MacOS/Godot --headless --path test-project --quit-after 120` and grep for `SCRIPT ERROR`/`Parse Error`/`Compile Error`. `--export-pack` swallows compile errors and ships broken bytecode → passthrough. See KB [`godot-headless-verify-before-device.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-headless-verify-before-device.md).
- **PCK export output path MUST be absolute** — relative paths resolve from the project dir, not cwd.
- **No `var x := min(...)` / Dictionary-access inference** — `min()`/`max()` and `dict[key]` return Variant; `:=` then warns→errors on load. Type explicitly (`var x: int = min(...)`).

## Build + deploy loop (current, working)

```bash
# 1. (after any .gd / project.godot edit) headless verify
~/godot-visionos-pilot/Godot.app/Contents/MacOS/Godot --headless --path /Users/alex/godot-visionos-pilot/test-project --quit-after 120 2>&1 | grep -iE "error|parse|compile" | grep -v "XR=FAILED"

# 2. export PCK (ABSOLUTE output path)
~/godot-visionos-pilot/Godot.app/Contents/MacOS/Godot --headless \
  --path /Users/alex/godot-visionos-pilot/test-project --export-pack "visionOS" \
  /Users/alex/godot-visionos-pilot/out/xcode-visionos/GodotVisionPilot.pck

# 3. build (generic destination avoids "device unavailable" when AVP asleep)
xcodebuild -project out/xcode-visionos/GodotVisionPilot.xcodeproj \
  -scheme GodotVisionPilot -configuration Debug \
  -destination "generic/platform=visionOS" \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="C624J4S2F8" build

# 4. install (put headset ON first — AVP sleeps when not worn; retry 2-3x)
xcrun devicectl device install app --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  "$(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app)"

# 5. verify FPS (boot line must read "...hand tracking active"; per-5s delta 450 = 90 FPS)
xcrun devicectl device copy from --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  --source "Documents/xr_diag.txt" --destination /tmp/xr_diag.txt \
  --domain-type appDataContainer --domain-identifier com.agilelens.godotvisionpilot
head -6 /tmp/xr_diag.txt
```

## Remaining agenda (priority order)

1. **Make hand tracking durable (the big one).** Build Clancey `visionos_master_pr` ourselves (HEAD `2b2f749`, 2026-03-03 — full hand tracking) as our canonical `Godot.app` + `libgodot.a`, version-matched so we can drop the text-mode workaround. ~30–90 min on M1 Max. Coordinate with Marshall first (Slack `U04MR6H85K6`) — he built it; get his build gotchas + whether he has a shareable fork. **Also: push the archived lib to offsite/NAS backup now** (it's the only copy off Marshall's Desktop).
2. **README GIF** — full visual is ready (cubes, light, mixed mode, hand grab/throw). AirPlay → QuickTime, or Xcode → Devices → Record Screen → ffmpeg two-pass palettegen 720×405 15fps → replace `captures/cascade.gif`.
3. **Progressive immersion + skybox** (~15 min) — Info.plist `UIImmersionStyleMixed` → `UIImmersionStyleProgressive`; add `ProceduralSkyMaterial` to WorldEnvironment.
4. **Hand-as-collision-mesh** (next sprint) — 5 `AnimatableBody3D` capsules per hand at finger joints from `XRHandTracker`, so hands deflect cubes without pinching.
5. **Watch upstream** — Apple's hand tracking is "ready but unsubmitted." When it lands in rsanchezsaez/upstream, migrate off Clancey's fork to the official path.

## Engine landscape (so you don't re-research)

| Engine | Hand tracking | Notes |
|--------|:---:|-------|
| rsanchezsaez/godot `apple/visionos-xr` | ❌ render-only | Apple's official PR branch (#109975). No hand input compiled in. |
| **Clancey/godot `visionos_master_pr`** | ✅ | HEAD `2b2f749`. Our running lib is pre-rebase `85f0afd` (diverged, also works). **This is what we use.** |

## Don't break what works

- **Don't run a full `--export`** (vs `--export-pack`) without re-applying the Clancey lib swap AND the tracked Info.plist (`UIImmersionStyleMixed` + the two hand/world usage keys). A full export regenerates the xcframework → reverts to rsanchezsaez.
- **Don't revert `script_export_mode=0`** until editor and lib are the same Godot version.
- `XROrigin3D.current = true` in main_v2.tscn — silent killer if removed.
- `main.tscn` is the fallback minimal scene. Keep it.
- `PickupHandler3D` uses `$CollisionShape3D` in `_ready()` — the CollisionShape3D child must be named `"CollisionShape3D"` and added before the handler enters the tree (done in `_setup_hands()`).
- Plates/wall are `PickupAbleBody3D` in group `"surface"`; cubes in group `"cube"`. Audio + kill-plane classify by group — keep the groups if you touch spawn code.

## Critical contacts

- **Marshall Nowak** (Nocxr) — Agile Lens. Slack `U04MR6H85K6`. Arizona (no DST). Built the Clancey `visionos_master_pr` engine; provided the `libgodot.a` + `visionosxr_hand_tracking` reference project. Coordinate before rebuilding the engine.
- **Alex Coulombe** — pilot owner. One round-trip ≈ 3–4 min.

## Key files

```
test-project/main_v2.gd               # cascade + _setup_hands() + grabbable plates/wall
test-project/main_v2.tscn             # scene (XROrigin3D.current=true)
test-project/main.tscn                # fallback minimal scene
test-project/project.godot            # hand_interaction_profile=true, mobile renderer
test-project/export_presets.cfg       # script_export_mode=0 (Text), hand/world privacy strings
test-project/pickup/pickup_handler.gd    # Marshall's PickupHandler3D
test-project/pickup/pickup_able_body.gd  # + throw velocity + freeze_on_release
test-project/shaders/highlight_{shader,material}.tres
out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist  # TRACKED: Mixed + hand/world keys
out/xcode-visionos/GodotVisionPilot.xcframework/xros-arm64/libgodot.a  # Clancey lib (gitignored!) + .rsanchezsaez.bak
Godot.app/                            # 4.6.3 editor (gitignored)
~/godot-engine-bin-archive/clancey-handtracking-4.6.2/  # durable lib copy + MANIFEST
```
