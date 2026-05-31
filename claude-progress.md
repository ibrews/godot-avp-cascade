# Physics Sandbox — Progress

Turning the falling-cascade demo into a proper physics-sandbox sample project for AVP/Godot.

## ⚠️ STATE (2026-05-31, session 2) — READ FIRST

Device app **v0.1.3-fixA** installed. AWAITING headset re-capture of grab_trace.txt.
- **Build 1 trace (actual, seq ~3096):** dt clean ~11 ms = 90 Hz render confirmed, no
  drops. deuler tiny after the grab-snap frame (<1°/frame) → rotation confirmed NOT the
  cause; HELD_ROT_DAMP is a no-op (remove it). |dpos| mean=7.205 max=18.553 mm — BUT this
  metric is contaminated by real hand motion (user was moving), so it can't cleanly
  isolate the saw-tooth. A beat IS visible in steady stretches (e.g. y: −12.4,−4.6,+0.1,
  −10.2… = jump/decay/jump). Diagnosis direction (positional, render clock clean) holds;
  for a clean isolation next time, log JERK (2nd difference) not raw |dpos|.
- **Build 2 = Fix A applied:** moved `_update_anchor_from_hand_tracker()` from
  `pickup_handler.gd._physics_process` → new `_process` (render rate). Pickup/release
  latch + `_update_closest_body()` stay in `_physics_process`. Expect re-capture to show
  |dpos| mean≈max (spikes gone). If confirmed → commit, remove HELD_ROT_DAMP, Task 2.

### (prior) Device seq 3096, v0.1.2-trace — build 1 instrumentation
- **Build 1 done:** added a one-shot per-render-frame grab trace to
  `pickup_able_body.gd._process` (ring buffer of 90 frames → `_dump_trace()` writes
  frame-to-frame |dpos| deltas to `user://grab_trace.txt`). Proves/measures the
  saw-tooth BEFORE Fix A, so we can confirm Fix A flattens it. Gated behind held +
  `_trace_done` so it never spams.
- **NEXT:** Alex grabs a cube ~1.5 s on headset → pull grab_trace.txt → confirm
  spikes → Build 2 = Fix A (move anchor origin write in
  `PickupHandler3D._update_anchor_from_hand_tracker()` from `_physics_process` →
  `_process`). Then re-capture; |dpos| mean should ≈ max (flat).
- New gated build script: `/tmp/avp_build.sh` (validate→export→xcodebuild→parity→
  install, single-verdict output). Build 1 ran fully green.

### Prior state (2026-05-31, session 1)

Device seq 3088, app **v0.1.1**. WIP committed.
- **World handle = WORKING & GREAT** (moves XROrigin, not WorldRoot). Ring reset re-centers.
- **Object grab = still glitchy, and it's POSITIONAL** (user-confirmed). A rotation-damping
  pass had NO effect → rotation was never the problem. Root cause now known: the handler
  re-pins its origin to the fingertip in `_physics_process` (60 Hz) while the body rides at
  90 Hz → 3:2 beat. Telemetry tell: `proc≈450 phys≈300`, `follow_off` swings 0.24–0.34 m.
  Full analysis + recommended fixes (anchor→_process, or physics_interpolation) + the two new
  build gotchas: KB `intelligence/techniques/godot-avp-grab-positional-stutter.md`.
- **NEXT (handed to a fresh chip):** (1) positional stutter fix w/ per-frame pos/rot logging
  first, (2) two-hand pinch SCALE = scale XROrigin about pinch midpoint, (3) alpha edge
  blockiness = MSAA_4X / disable VRS_XR, (4) hand meshes drift after world-grab = compensate
  hand visuals for the XROrigin shift. See HANDOFF_PROMPT.md for the full brief.

### Build gotchas discovered THIS session (both cost time)
- Validate gate MUST capture stdout (`>/tmp/v.txt 2>&1`) — Godot `print()` boot markers are on
  STDOUT, errors on STDERR. `2>file` alone sees 0 boot markers → false VALIDATE_FAILED.
- DerivedData has multiple `GodotVisionPilot-*` dirs; always pick newest (`ls -dt … | head -1`)
  or you get false PCK-parity mismatch + install failure against a stale bundle.

## ⚠️ Prior state (2026-05-30 ~23:30)

App launches fine. Grab stutter (earlier 4 causes) writeup:
KB `intelligence/techniques/godot-avp-grab-follow-stutter.md`.

**Object grab is now smooth** — fixed via THREE stacked causes (not the two-hand
scaler, which was a red herring):
1. Scene-handle `_pause_sim()` disabled the PickupHandlers + handle grabbed
   spuriously → handlers toggled DISABLED↔INHERIT → held body froze/snapped.
2. Course obstacles were `FREEZE_MODE_KINEMATIC`; held bodies must be STATIC
   (clean teleport). Now forced STATIC while held, restored on release.
3. (My own regression, reverted) a "world-space damping" follow in
   `_physics_process` ran at 60 Hz on a 90 Hz display → judder. Reverted to the
   reparent design (rides XR controller at 90 Hz = smooth). **NEVER follow a held
   body in `_physics_process`. For jitter filtering use physics_interpolation.**

**Pinch tightened:** hand-tracked pickup now uses thumb–index TIP distance only
(~1.2 cm grab / 2.2 cm release); ignores the platform's loose ~2-inch pinch action.

**Info panel added:** billboarded "A Godot Sample by @ibrews" / v0.1.0 (upper-left).

### ⏭️ NEXT (open, queued) — WORLD HANDLE: move the USER, not the world
The chrome handle STILL freaks everything out: `_update_scene_handle()` translates
`_world_root.global_position += delta`, dragging every physics body through the
solver. **Alex's fix (correct, standard VR pattern): move `XROrigin3D` the opposite
direction instead of moving WorldRoot — looks identical, touches ZERO physics
objects → no jitter. Scaling = scale the XROrigin, not the assets.** The handle is
currently RE-ENABLED but broken this way; redesign it to drive XROrigin.

Also open: residual hand-tracking shimmy (try `physics/common/physics_interpolation
=true`); alpha/blocky mixed-mode edge pixelation (MSAA_4X / disable VRS_XR — never
addressed).

### Build gotcha (cost time this session)
Bash cwd PERSISTS between calls. `cd test-project` then a later relative
`Godot.app/...` resolves from test-project → exit 127 (false "0 errors" on empty
log). Use ABSOLUTE paths for Godot/--path, or cd to repo root each call.

## Vision
Grabbable spawn emitter drops cubes → build a path of grabbable obstacles →
cubes reach a goal portal and score. Score = time-alive × chain multiplier for
hitting distinct surfaces in quick succession.

## What WORKED on device (user-confirmed)
- Hand mesh: white skinned XR Tools hands, per-hand rotation correction
  (R=Ry+90°, L=Ry−90°), shard dissolve/reassemble on toggle. ✅ "looks great"
- Bubble transmuter (cube→sphere) reflecting the hands. ✅ "LOVE that"
- Chain scoring + inline popups (+5 / x3 +15), portal cash-out + burst + arpeggio. ✅
- Immersion skybox toggle (pinky). ✅ (seen in video)
- App icon (layered .solidimagestack: portal + falling cube). ✅

## OPEN / unverified
- **Object grab stutter** (above) — A/B test shipped, awaiting headset check.
- **Middle pinch read as index** (pre-A/B report). Closest-finger test added to
  `_index_pinch_point`; object grab uses PickupHandler not that, so may persist.
- **Alpha/blocky edge pixelation in mixed mode** — never addressed. Try
  `viewport.msaa_3d = MSAA_4X` in `_ready` (~line 119); then test disabling
  `viewport.vrs_mode = VRS_XR`. Classic CompositorServices mixed-mode issue.

## Build loop (PROVEN — follow exactly; validation GATES export)
```
Godot.app/Contents/MacOS/Godot --headless --path test-project --quit-after 180 2>&1 \
  | grep -iE "error|parse|compile" | grep -v "XR=FAILED"   # MUST be empty
Godot.app/Contents/MacOS/Godot --headless --path test-project --export-pack "visionOS" \
  /Users/alex/godot-visionos-pilot/out/xcode-visionos/GodotVisionPilot.pck
touch out/xcode-visionos/GodotVisionPilot.pck   # CRITICAL: xcodebuild won't recopy on mtime alone
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app)
rm -f "$APP/GodotVisionPilot.pck"
xcodebuild -project out/xcode-visionos/GodotVisionPilot.xcodeproj -scheme GodotVisionPilot \
  -configuration Debug -destination "platform=visionOS,id=2642855C-6B73-5D5B-9387-6B110E7A7CF3" \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="C624J4S2F8" build
# verify exported pck sha == bundled pck sha (PCK_PARITY)
xcrun devicectl device install app --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 "$APP"
```
New `class_name` script (or changed base class) → run `--import` first.

## Gesture map (intended)
- index→thumb = grab object / scene handle (near bar) / scale (free hand)
- middle→thumb = toggle hand mesh (dissolve) ; ring→thumb = reset ; pinky→thumb = immersion skybox

## Failed approaches (don't retry)
- Scene handle as PickupAbleBody3D → auto-grabbed by proximity near face, threw world. (Fixed: now plain Node3D, manual grab.)
- Hand mesh set_bone_global_pose_override w/ XRHandModifier enum names → 4.6.2.rc renames them. Use raw int joint indices.
- Hand mesh relative-transform (set_bone_pose_*) → mesh collapsed to origin.
- Per-frame pivot recompute during scale → feedback loop, scene flew apart. (Fixed: freeze pivot at engage.)
- Immersion via Environment.background_mode flip → didn't occlude; use skybox sphere.
- Pinch grab/release on a single threshold → flicker. Use hysteresis (0.032 start / 0.060 release).
- **Batching many changes without per-change device verify → unbisectable regressions. ONE change per build/verify/commit.**

## Note on tool-output channel
This session saw intermittent corruption in DISPLAYED tool output (duplicated
lines, injected English/code-fence trailers, runs disagreeing on SHAs). Files on
disk were correct. Verify git via exit codes + rev-list counts; files via grep -c
and the headless validator — never trust displayed output blindly. (Earlier I
ALSO over-escalated benign noise into false "injection" alarms; see KB
`agent-false-anomaly-escalation.md`. Verify, don't assume either direction.)
