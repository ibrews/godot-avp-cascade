# HANDOFF — godot-avp-cascade physics sandbox (2026-05-30 ~23:30)

Read project CLAUDE.md first (build recipe, alpha-0 rule, mobile renderer, engine-swap
fragility — working libgodot.a is gitignored; if a fresh clone reverts hand tracking run
`scripts/restore-engine-lib.sh`). Then KB
`intelligence/techniques/godot-avp-grab-follow-stutter.md` (this session's full root-cause
writeup) and `godot-avp-sandbox-verify-each-change.md`.

## State: grab stutter FIXED (device seq 3048). One feature broken on purpose-ish.
Object grab (cubes + static obstacles) is smooth. Pinch is firm (~1 cm thumb–index tip).
Title/version panel added. See claude-progress.md ⚠️ STATE for the 3 stacked causes.

## ⏭️ DO THIS FIRST — world handle: move the XROrigin, not the world
The chrome handle is re-enabled but FREAKS EVERYTHING OUT: `_update_scene_handle()`
(test-project/main_v2.gd) does `_world_root.global_position += delta`, dragging all physics
bodies through the solver. **Alex's directive (correct, standard VR world-grab pattern):
move `XROrigin3D` the OPPOSITE direction instead of moving WorldRoot. Visually identical,
but zero physics objects move → no jitter. Scaling (when re-added) = scale the XROrigin /
world scale, not the assets.**
- Rewrite `_update_scene_handle()` translate path to move `$XROrigin3D` by `-delta` (and
  the handle bar itself stays put in world space, or moves with the origin — decide so the
  bar stays grabbable). Drop the `WorldRoot` translate and the `_pause_sim()` freeze
  entirely (no need to freeze physics if nothing in the world moves).
- Keep the firm-pinch + on-bar acquisition guards already in place (closest_body guard,
  HANDLE_GRAB_DIST 0.09, PINCH_START 0.024).
- Then two-hand scale: scale the XROrigin about the pinch midpoint, not the bodies.

## Build loop (FOLLOW EXACTLY — validation GATES export; use ABSOLUTE paths, cwd persists)
```
cd /Users/alex/godot-visionos-pilot
Godot.app/Contents/MacOS/Godot --headless --path test-project --quit-after 120 2>/tmp/v.txt
grep -icE "SCRIPT ERROR|Parse Error|Compile Error" /tmp/v.txt   # MUST be 0 before export
Godot.app/Contents/MacOS/Godot --headless --path test-project --export-pack "visionOS" \
  /Users/alex/godot-visionos-pilot/out/xcode-visionos/GodotVisionPilot.pck
touch out/xcode-visionos/GodotVisionPilot.pck
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app)
rm -f "$APP/GodotVisionPilot.pck"
xcodebuild -project out/xcode-visionos/GodotVisionPilot.xcodeproj -scheme GodotVisionPilot \
  -configuration Debug -destination "platform=visionOS,id=2642855C-6B73-5D5B-9387-6B110E7A7CF3" \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="C624J4S2F8" build
# verify exported-pck SHA == bundled-pck SHA (PCK_PARITY)
xcrun devicectl device install app --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 "$APP"
```
New `class_name` script → run `--import` first. Binary guard: never `git add`
libgodot/.xcframework/.a/.pck. **visionOS needs a full quit+relaunch to pick up a reinstall**
— the title panel is a handy build-freshness canary.

## On-device telemetry (USE IT before theorizing)
`xr_diag.txt` logs every 5 s: `proc≈450 phys≈300` (90 Hz render / 60 Hz physics),
`held=L/R`, `paused`, `both_same`, `follow_off`. Pull:
```
xcrun devicectl device copy from --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  --source "Documents/xr_diag.txt" --destination /tmp/xr_diag.txt \
  --domain-type appDataContainer --domain-identifier com.agilelens.godotvisionpilot
```

## Also open (not started)
- Residual hand-tracking shimmy on held objects → try `physics/common/physics_interpolation
  =true` in project.godot (renders 60 Hz physics smoothly at 90 Hz; add
  `reset_physics_interpolation()` on pickup/spawn to avoid smears). Do NOT add a
  `_physics_process` follow lerp — that's what caused this session's judder regression.
- Alpha/blocky edge pixelation in mixed mode → `viewport.msaa_3d = Viewport.MSAA_4X` in
  `_ready` (~line 130); if no help test disabling `viewport.vrs_mode = VRS_XR`.

## Device / IDs
AVP id 2642855C-6B73-5D5B-9387-6B110E7A7CF3 ; bundle com.agilelens.godotvisionpilot ;
team C624J4S2F8 ; repo PUBLIC github.com/ibrews/godot-avp-cascade (binary stays OUT of git).
