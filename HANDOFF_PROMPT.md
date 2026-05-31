# HANDOFF — godot-avp-cascade physics sandbox (2026-05-31)

Read project CLAUDE.md first (build recipe, alpha-0 rule, mobile renderer, engine-swap
fragility — working libgodot.a is gitignored; if a fresh clone reverts hand tracking run
`scripts/restore-engine-lib.sh`). Then read these KB files IN ORDER:
1. `intelligence/techniques/godot-avp-grab-positional-stutter.md` ← THIS SESSION; the
   positional-stutter root cause + recommended fixes + the two build-gotchas below.
2. `intelligence/techniques/godot-avp-grab-follow-stutter.md` (the earlier 4 causes + the
   world-handle "move the XROrigin" fix that now works).
3. `intelligence/techniques/godot-avp-sandbox-verify-each-change.md`.

## State (device seq 3088, app v0.1.1, WIP committed)
- **World handle = GREAT.** Grabbing the chrome bar drags the whole world smoothly by moving
  `XROrigin3D` the opposite direction (zero physics bodies move). Ring-pinch reset re-centers
  the origin too. DO NOT go back to translating WorldRoot.
- **Object grab is still POSITIONALLY glitchy.** User confirmed it's position, not rotation.
  A rotation-damping pass (`HELD_ROT_DAMP` in `pickup_able_body.gd`, runs in `_process`) had
  **no visible effect** → rotation was never the problem. That code is committed but SUSPECT:
  consider removing it once the positional fix lands (it adds rotation lag for no benefit).

## ⏭️ DO FIRST — positional grab stutter (root cause is known; see KB #1)
The held body rides the handler at 90 Hz, but the handler RE-PINS its origin to the fingertip
in `_physics_process` (60 Hz) → a 60 Hz position correction shown on a 90 Hz display = 3:2
beat. Telemetry tell: `proc≈450 phys≈300` + `follow_off` swinging 0.24–0.34 m while held.
1. **Add per-frame pos/rot logging first** (user's explicit ask): ring-buffer
   `(t, held_body.global_position, global_basis.get_euler())` for ~60 render frames while held,
   dump deltas — proves the saw-tooth and confirms the fix flattens it.
2. **Fix A (try first):** move the anchor origin write in
   `PickupHandler3D._update_anchor_from_hand_tracker()` from `_physics_process` → `_process`
   (render rate). Keep `_update_closest_body()` + pickup/release latch in `_physics_process`.
3. **Fix B (if A insufficient):** `physics/common/physics_interpolation=true` in project.godot
   + `reset_physics_interpolation()` on pickup/spawn. Test A and B independently.
   NEVER reintroduce a hand-rolled lerp in `_physics_process` (that was a reverted regression).

## Also solve this session (in priority order after the stutter)
1. **Two-hand pinch SCALE.** Scale the XROrigin about the pinch midpoint (NOT the assets, NOT
   WorldRoot — same philosophy as the world-handle translate). `_update_two_hand_scale()` and
   the old `_scale_world_about()` were removed; the scaffolding constants (SCALE_MIN/MAX,
   `_world_scale_*`) and the disabled call site comment are still in main_v2.gd. Implement as:
   while the world handle is held, the OTHER hand's index-pinch distance from the handle drives
   `XROrigin3D.scale` about the pinch midpoint (inverse: shrinking the origin = growing the
   world). Keep it off the physics bodies entirely.
2. **Alpha edge blockiness in mixed mode** (never addressed). In `_ready()` (~main_v2.gd:130)
   add `get_viewport().msaa_3d = Viewport.MSAA_4X`. If no help, test DISABLING
   `viewport.vrs_mode = Viewport.VRS_XR` (currently set at line 130 — VRS may be coarsening
   edge pixels in the alpha/passthrough composite). Classic CompositorServices mixed-mode issue.
3. **Hand meshes drift away from real hands after a world-handle drag.** Expected side effect of
   moving XROrigin: passthrough (real hands) is composited from the PHYSICAL pose, but the
   `HandMeshDriver3D` + pickup anchors read `XRHandTracker.get_hand_joint_transform()` in
   TRACKING space and render through the shifted origin → virtual hands swim away by the drag
   amount. Fix: the hand meshes/anchors should re-pin to the real hands regardless of the origin
   shift. Investigate whether hand-joint transforms are origin-relative (likely) and compensate,
   OR parent the hand visuals so they track the physical hand independent of the world-grab
   offset. Verify the world still appears shifted while hands stay on the real hands.

## Build loop (FOLLOW EXACTLY — two gotchas baked in)
```bash
cd /Users/alex/godot-visionos-pilot
GODOT=/Users/alex/godot-visionos-pilot/Godot.app/Contents/MacOS/Godot
PROJ=/Users/alex/godot-visionos-pilot/test-project
PCK=/Users/alex/godot-visionos-pilot/out/xcode-visionos/GodotVisionPilot.pck
# 1. VALIDATE — capture stdout+stderr (boot markers are on STDOUT!). Gate on BOTH.
"$GODOT" --headless --path "$PROJ" --quit-after 120 >/tmp/v.txt 2>&1
grep -icE 'SCRIPT ERROR|Parse Error|Compile Error|not declared|nonexistent function' /tmp/v.txt  # ==0
grep -cE 'Sandbox built' /tmp/v.txt                                                               # >=1
# 2. EXPORT (absolute paths; cwd persists between bash calls)
"$GODOT" --headless --path "$PROJ" --export-pack "visionOS" "$PCK"
touch "$PCK"
# 3. XCODEBUILD against the NEWEST DerivedData app (multiple dirs exist!)
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app | head -1)
rm -f "$APP/GodotVisionPilot.pck"
xcodebuild -project out/xcode-visionos/GodotVisionPilot.xcodeproj -scheme GodotVisionPilot \
  -configuration Debug -destination "platform=visionOS,id=2642855C-6B73-5D5B-9387-6B110E7A7CF3" \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="C624J4S2F8" build
# 4. PCK PARITY (re-resolve APP to newest) then INSTALL
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app | head -1)
diff <(shasum -a256 "$PCK"|cut -d' ' -f1) <(shasum -a256 "$APP/GodotVisionPilot.pck"|cut -d' ' -f1) && echo PARITY_OK
xcrun devicectl device install app --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 "$APP"
```
Bump APP_VERSION in main_v2.gd on each meaningful build — the info panel is the freshness
canary (visionOS needs a full quit+relaunch to load a reinstall). New `class_name` → `--import`
first. Binary guard: NEVER `git add` libgodot/.xcframework/.a/.pck. ONE change → verify on
headset (Alex opens it) → commit. Pull telemetry BEFORE theorizing:
```bash
xcrun devicectl device copy from --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  --source "Documents/xr_diag.txt" --destination /tmp/xr_diag.txt \
  --domain-type appDataContainer --domain-identifier com.agilelens.godotvisionpilot
```

## Device / IDs
AVP id 2642855C-6B73-5D5B-9387-6B110E7A7CF3 ; bundle com.agilelens.godotvisionpilot ;
team C624J4S2F8 ; repo PUBLIC github.com/ibrews/godot-avp-cascade (binary stays OUT of git).
