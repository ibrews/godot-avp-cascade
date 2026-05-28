# HANDOFF — Next session pickup brief

**Current state as of 2026-05-28 (morning session):** v6 (hand tracking) committed `f7ac2d6` and pushed. Build succeeded. **NOT yet installed on device** — AVP was asleep. Install is the first thing to do next session.

**Read this whole file before doing anything.** Self-contained pickup — no prior transcript needed.

## First thing next session

```bash
# 1. Install v6 (put headset on first — AVP sleeps when not worn)
xcrun devicectl device install app \
  --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  $(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app)

# 2. Verify 90 FPS still holds with v6
xcrun devicectl device copy from \
  --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  --source "Documents/xr_diag.txt" \
  --destination /tmp/xr_diag.txt \
  --domain-type appDataContainer \
  --domain-identifier com.agilelens.godotvisionpilot
cat /tmp/xr_diag.txt
# Per-5s delta must be 450. If it drops: reduce particles.amount from 12→8 in main_v2.gd.

# 3. Test hand tracking
# Try pinching near a cube — should highlight yellow, snap to pinch point.
# Throw: flick wrist, release pinch. Cube should retain throw velocity.
```

## What's working right now

- **Mixed immersion** confirmed — cubes composite into real room, no artifacts
- **Spatial audio** confirmed — chimes attenuate with distance, stereo panning works
- **PR comment live** on godotengine/godot#109975 — positive reply from @stuartcarnie
- Info.plist tracked at `out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist` (`UIImmersionStyleMixed`)

## What changed in v6 (built, not yet installed)

1. **`openxr/extensions/hand_interaction_profile=true`** added to `project.godot` — the missing flag that enables XRHandTracker joint data on AVP
2. **`PickupHandler3D`** — Marshall Nowak's (Nocxr) hand-tracking Area3D, copied verbatim from `visionosxr_hand_tracking` project
   - Pinch detection: joint-distance (0.06 m=0%, 0.025 m=100%), threshold 0.35 to pickup, 0.12 to release, 180 ms grace window
   - Fingertip anchoring: handler moves to index+thumb midpoint each physics frame
   - `hold_while_hand_tracking_uncertain=true` — keeps hold if tracking momentarily drops
3. **`PickupAbleBody3D`** — extends `RigidBody3D`, adds snap-to-pinch + throw velocity
   - Tracks last 6 global positions in `_physics_process()` while held
   - `let_go()` applies `linear_velocity` from position delta → cube inherits hand speed on throw
   - Yellow highlight outline on nearest grabbable cube (grow-normal shader)
4. **Hand setup** in `_ready()` — two `XRController3D` nodes (left_hand, right_hand) with `PickupHandler3D` children added procedurally to `XROrigin3D`
5. **Spawned cubes** are `PickupAbleBody3D` instead of `RigidBody3D` — drop-in since it extends `RigidBody3D`; all physics properties unchanged
6. **README** updated — description, Things to Try (#2 is grab/throw), Marshall's credit in Credits section

## Key files changed

```
test-project/main_v2.gd              # _setup_hands(), PickupAbleBody3D spawn
test-project/project.godot           # openxr flags added
test-project/pickup/pickup_handler.gd       # Marshall's PickupHandler3D (verbatim)
test-project/pickup/pickup_able_body.gd     # + throw velocity
test-project/shaders/highlight_shader.tres  # yellow grow-normal outline
test-project/shaders/highlight_material.tres
README.md
```

## Known risks for v6 test

- **XRHandTracker availability**: Hand tracking requires `openxr/extensions/hand_interaction_profile=true` (now added) AND Clancey's fork. Confirm we're on the right engine branch; if joint data never arrives, `PickupHandler3D._get_pickup_value()` will fall back to controller float inputs (grip, trigger, pinch) which may fire spuriously.
- **detect_range = 0.08 m**: Tight 8 cm sphere. If cubes are hard to grab, increase to 0.12 in `_setup_hands()`. No rebuild needed — just re-export PCK.
- **Reparenting + _active_cubes**: When cube is picked up it reparents to the handler. `_on_kill_entered` checks `if body is RigidBody3D` — `PickupAbleBody3D` passes this check. Should be fine. Watch for cubes stuck in mid-air if the kill plane fires during a pickup.

## Tomorrow's remaining agenda

### 1. Progressive immersion + skybox (~15 min)

- Change Info.plist `UIImmersionStyleMixed` → `UIImmersionStyleProgressive`
- Digital Crown lets user blend 0% (mixed) → 100% (full) at will
- Add `ProceduralSkyMaterial` to WorldEnvironment in `main_v2.tscn` (or procedurally)

### 2. README GIF

v6 has full visual + mixed mode + hand tracking. Capture when confirmed on device.
AirPlay → QuickTime → 7–10s clip → ffmpeg two-pass palettegen, 720×405, 15fps → replace `captures/cascade.gif`.
High-fidelity: Xcode → Window → Devices and Simulators → select AVP → Record Screen.

### 3. Hand-as-collision-mesh (non-trivial, next sprint)

5 `AnimatableBody3D` capsules at fingertips, updated from `XRHandTracker` each frame.
Requires knowing joint positions without pinch gesture.

## Dev Strap install gotcha

`xcrun devicectl device install` fails if AVP is asleep. Put headset on first, retry 2–3×.

## Read these FIRST

1. [`CLAUDE.md`](CLAUDE.md) — build loop, critical constraints, do-nots
2. KB: [`intelligence/techniques/godot-visionos-xr.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-visionos-xr.md)
3. KB: [`intelligence/techniques/godot-avp-falling-cascade.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-avp-falling-cascade.md)

## Critical contacts

- **Marshall Nowak** (Nocxr) — Agile Lens. Slack `U04MR6H85K6`. Arizona (no DST). Provided the hand tracking reference project (`visionosxr_hand_tracking`) from Clancey's fork.
- **Alex Coulombe** — pilot owner. One round-trip ≈ 3–4 min.

## Don't break what works

- `main.tscn` is the fallback minimal scene. Keep it.
- `XROrigin3D.current = true` in main_v2.tscn — silent killer if removed.
- Connect `body_entered` AFTER `add_child()` on RigidBody3D.
- `out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist` is tracked — don't overwrite with a full `--export` without re-applying `UIImmersionStyleMixed`.
- `PickupHandler3D` uses `$CollisionShape3D` in `_ready()` — CollisionShape3D child MUST be added to handler before handler enters the tree. Already done in `_setup_hands()`.

## State of the working tree

```
Pilot repo: /Users/alex/godot-visionos-pilot/ (git, branch main, public on GitHub)
KB: ~/knowledge/ (separate repo)

Critical files:
  test-project/main_v2.gd                                      # Cascade script (v6 — hand tracking)
  test-project/main_v2.tscn                                    # scene (ExtResource → main_v2.gd)
  test-project/main.tscn                                       # fallback minimal scene
  test-project/project.godot                                   # XR project settings (OpenXR flags added)
  test-project/export_presets.cfg                              # visionOS export config
  test-project/pickup/pickup_handler.gd                       # Marshall's PickupHandler3D
  test-project/pickup/pickup_able_body.gd                     # + throw velocity
  test-project/shaders/highlight_{shader,material}.tres       # yellow outline on nearest cube
  out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist  # immersion=Mixed (TRACKED)
  Godot.app/                                                   # custom binary (gitignored)
  rsanchezsaez-godot/                                          # engine source (gitignored)
  captures/                                                    # cascade.gif = pre-v5, update when ready
```
