# Physics Sandbox — Progress

Turning the falling-cascade demo into a proper physics-sandbox sample project for AVP/Godot.

## ⚠️ STATE (2026-05-31, session 3) — ENGINE RECOMPILE DONE; ITEM 2 SHIPPED, ITEM 1 DEFERRED

Rebuilt the Clancey fork (`clancey-godot`, branch `visionos_master_pr`). App **v0.5.0-engine**,
device-verified on AVP. **OUTCOME:**
- **ITEM 2 (real-arm runtime toggle): ✅ DONE + device-verified + committed.** (fork local commit
  0954ef5; cascade pushed 9cd50c8.) Hand tracking preserved (grab/throw confirmed).
- **ITEM 1A (foveation off): ❌ DISPROVEN on device** (full-rate held 90 FPS, halos unchanged).
  Reverted to stock. KB `godot-avp-alpha-edge-aa.md` corrected (old foveation verdict was wrong).
- **ITEM 1B: DEFERRED** (Alex's call). Hypothesis weakened; needs a FRESH Dev Strap screenshot to
  re-characterize the halo before any Metal-renderer change. Do NOT dive in blind.
- Installed lib `f968292d` = ITEM 2 minus foveation experiment (both halves verified separately;
  combined build not re-glanced — only diff is makeConfiguration reverted to stock).
- Backups: working lib `179446a8` in durable archive + `/tmp/avp_session_backup_dir.txt`.
- KB + daily + timing all pushed. Public cascade pushed. Fork commit is LOCAL ONLY (not pushed to
  Marshall's origin — borrowed fork).

(historical detail below)

**What changed (all in `platform/visionos/app_visionos.swift`, one fork rebuild):**
- **ITEM 1A — foveation OFF.** `makeConfiguration()` now forces `isFoveationEnabled=false`
  + non-foveated layout (behind `let godotEnableFoveation=false`, flip to revert).
  Hypothesis: foveation rasterization-rate map is what coarsens the mixed-mode alpha
  halos. MUST verify on device: (a) halos gone, (b) FPS still 90 (xr_diag delta ~450).
- **ITEM 2 — real-arm runtime toggle.** New `UpperLimbVisibilityModel: ObservableObject`
  (@MainActor, @Published) polls `Documents/upper_limb.txt` every 0.5s on the main actor;
  Scene reads `limbModel.visibility` via `@StateObject` so `.upperLimbVisibility` re-applies
  LIVE (no relaunch). File-first → Info.plist key → controller → .automatic. Used
  ObservableObject NOT @Observable (the hand-rolled `swift-frontend -c` build has no macro
  plugin paths; @Observable won't expand). CompositorContent has no `.task`, hence the model.
- **GDScript (`main_v2.gd`):** new pokable **ARMS** button (left, mirror of START) writes
  `user://upper_limb.txt`; `_load_arms_pref` syncs label at launch; instructions panel updated;
  middle-pinch relabeled "hand mesh" to keep virtual-mesh vs real-arms distinct. APP_VERSION
  bumped v0.4.0-scale → v0.5.0-engine.

**SAFETY / borrowed-binary status:**
- WORKING lib sha `179446a8` backed up (durable archive + session backup dir in
  `/tmp/avp_session_backup_dir.txt`). New lib sha `362c28d2`, swapped into xcframework
  device slice ONLY (sim slice untouched). Restore via `scripts/restore-engine-lib.sh`
  if hand tracking breaks.
- `bin/libgodot.visionos.template_debug.arm64.a` was byte-identical to the WORKING lib
  before this build; `obj/` is a complete prior build (7483 .o) so this was an INCREMENTAL
  relink — only `app_visionos.swift` recompiled, all C++ hand-tracking objects reused →
  hand tracking SHOULD be preserved. **Verify on device.**

**DEVICE VERIFY CHECKLIST (Alex, headset on):**
1. Hand tracking + grab/throw still work (white GLTF hands track, cubes grabbable). If
   NOT → `bash scripts/restore-engine-lib.sh` + rebuild, engine rebuild reverted.
2. Mixed-mode alpha halos GONE around cubes/hands/panels (ITEM 1A win).
3. xr_diag frame delta ~450/5s = 90 FPS held (foveation-off didn't tank GPU). If <450 →
   ITEM 1A too costly, flip `godotEnableFoveation=true`, fall back to ITEM 1B.
4. Poke ARMS button → real Persona arms fade ON; poke again → OFF (live, no relaunch).

NOTHING committed yet — gated on device verify. KB writes + commits + timing log pending.

## ⚠️ STATE (2026-05-31, session 2) — READ FIRST

Device app **v0.1.8-smooth** (seq 3140). AWAITING headset feel-test.
- **v0.1.7 grab-orientation fix CONFIRMED** (rotation jump gone). grab_snap.txt=148.6° =
  the reorientation the old IDENTITY snap applied; now preserved.
- **BUT held follow felt "electric" (raw jitter, pos+rot).** v0.1.7 trace: ±1–3mm & ±2°
  per frame with sign flips every frame = raw XRHandTracker noise passed 1:1.
- **KEY LESSON: I was wrong to revert the v0.1.5 one-euro filter.** Its still-hold trace
  was smooth (sub-mm glide) — I mislabeled that smoothness as "lag" and reverted. User
  explicitly WANTS the dampened/interpolated feel. (Also: v0.1.5 beta=0.06 was far too
  low → genuinely laggy on fast moves; standard one-euro beta ~0.5–1.0.)
- **v0.1.8 = one-euro on BOTH pos + rot, KEPT.** Persistent WORLD-space filtered
  transform in pickup_able_body._process (render rate), eased toward holder's raw pose.
  Tunables: FOLLOW_POS_MIN_CUTOFF=2.0/BETA=0.7, FOLLOW_ROT_MIN_CUTOFF=3.0/BETA=0.35.
  Replaced the reparent 1:1 ride AND the snap tween (filter eases the grab in).
  If still jittery → lower MIN_CUTOFFs. If laggy on fast moves → raise BETAs.
- Last main commit 75d7804 (v0.1.4). v0.1.5(reverted)/6/7/8 uncommitted — commit v0.1.7
  grab-orient + v0.1.8 smoothing together once feel is confirmed, then KB write, then Task 2.

### (prior) v0.1.7-graborient
- **v0.1.5 one-euro filter REVERTED** (not committed). Still-hold grab_trace.txt proved the
  held position is already clean after Fix A (<0.3mm/frame, no jitter/beat with hand
  confirmed still) — the filter only added rubber-band lag vs natural hand sway.
- **Release snap diagnosed (v0.1.6 release probe): NOT a release bug.** release_trace.txt
  showed orientation 0.000 across all 12 post-release frames (bit-identical, no
  discontinuity, no settling). The reorientation the user feels "on release" is actually
  the GRAB-time snap: pickup tweened local transform to Transform3D.IDENTITY, forcing the
  cube's orientation to align to the hand axis.
- **v0.1.7 fix:** pickup now tweens to Transform3D(grab_local.basis, Vector3.ZERO) —
  position still snaps to fingertips, but orientation is PRESERVED ("grab it as-is").
  Added grab_snap.txt probe = resting→hand angle (the now-avoided snap magnitude).
- **If confirmed:** commit Fix A is already in (acb5aa8); commit v0.1.7 grab-orient; then
  Task 2 (two-hand scale). Last commit on main = 75d7804 (v0.1.4). v0.1.5/6/7 uncommitted.

### (prior) Device app v0.1.3-fixA / v0.1.5-oneeuro
- **Fix A (v0.1.3, committed acb5aa8) WORKED** for the 60 Hz beat: steady-hold floor
  7.2mm→1.1mm, saw-tooth gone. **HELD_ROT_DAMP removed (v0.1.4, committed 75d7804).**
- **BUT user reports residual stutter persists.** Root cause refined: after Fix A the
  held body inherits the handler anchor 1:1 every render frame, and the anchor =
  RAW XRHandTracker fingertip midpoint with nothing smoothing it → sensor jitter
  lands straight on the cube. (v0.1.4 trace mean=3.96 but contaminated by real motion.)
- **Fix C = ONE-EURO FILTER on the anchor (v0.1.5, NOT yet committed — awaiting verify).**
  Added `_filter_anchor()` + `_oe_alpha()` to pickup_handler.gd; runs in `_process`
  (render rate = KB-safe domain). Adaptive low-pass: smooths jitter at rest, raises
  cutoff with hand speed so fast moves get ~no lag. Tunables: ANCHOR_MIN_CUTOFF=1.6,
  ANCHOR_BETA=0.06, ANCHOR_DCUTOFF=1.0. If still jittery at rest → lower MIN_CUTOFF.
  If laggy on fast moves → raise BETA. NEVER move this to _physics_process (60 Hz).
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
