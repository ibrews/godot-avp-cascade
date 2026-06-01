# Physics Sandbox — Progress

Turning the falling-cascade demo into a proper physics-sandbox sample project for AVP/Godot.

## ⚠️ STATE (2026-05-31, session 6) — v0.8.0-controls: 4 ITEMS SHIPPED — READ FIRST

Device app **v0.8.0-controls** built (validate gate clean: 0 errors / 1 "Sandbox built";
PCK parity OK; BUILD SUCCEEDED) + **installed to AVP** (devicectl, attempt 1).
**Awaiting Alex's on-headset verify** (quit + relaunch on the headset to load the reinstall).
Ran in an **isolated worktree** (`agent-a716da0d49930d981`) — the right pattern; commits on a
worktree branch on top of `e291a91`, pushed to origin/main at session end. Pure GDScript;
borrowed `libgodot.a` (`f968292d`) untouched, NO engine recompile.

**The 4 items (all device-installed, awaiting verify):**
1. **Grab-pivot fix** (`pickup/pickup_able_body.gd`). One-handed grabs were forcing the body
   CENTRE to the hand (grab a panel by its edge → centre snapped to finger → you'd poke a
   button). Now captures `_grab_pos_offset` = body-centre in holder-local frame at grab and
   replays it each frame (`target_pos = holder.origin + holder.basis.orthonormalized() *
   _grab_pos_offset`) → the GRABBED POINT stays under the finger and the object orbits that
   point. Holder basis orthonormalized on replay so holder scale isn't double-applied;
   `_grab_scale` still composes; one-euro spike-rejection/clamp unaffected. KB:
   `godot-avp-grab-smoothing.md`.
2. **New-high-score fireworks + cheer** (`main_v2.gd`). On round end: beat PERSONAL best →
   scene-spanning fireworks cascade (multiple staggered bursts scattered around the player,
   warm/gold) + procedural crowd cheer (`_push_cheer`: filtered-noise roar swell + bright
   in-key C-minor-pentatonic chord). Beat ONLINE leaderboard TOP (`_lb_top_score`, captured in
   `_on_lb_completed`) → bigger/distinct (more bursts, wider spread, electric cyan/magenta, a
   longer cheer + sparkle tail). `_celebrate_high_score(tier)`. Shared-audio buffer 0.6→1.0s so
   the cheer isn't clipped. Respects `_muted`.
3. **ONE control panel** (`_build_control_panel`, replaces `_build_gesture_panel` + the standalone
   START/ARMS/MUTE nodes). Grabbable PickupAbleBody3D, 2-col×3-row grid of **6** poke buttons:
   HANDS (mesh↔real cycle, ONE button) / START / MUTE / GESTURES / SKY / RESET + a big BEST
   readout. All six use the shared `_poke_buttons` registry (`_update_poke_buttons`, world-pos
   poke → follows the panel when grabbed). Removed `_build_start_button`/`_build_arms_button`/
   `_build_mute_button` + pollers `_update_arms_button`/`_update_mute_button` + `_press_button`/
   `_press_arms_button`; stripped the poke-loop from `_update_timer` (countdown/pulse stays).
   START callback = `_gp_start` (start/cancel, gated by `_start_cooldown`). Cleaned orphaned vars.
   NO destruct button on this panel (per request).
4. **Dissolve-sound polish** (`_push_dissolve_texture`/`_push_tick`). Duration now from the new
   `SKY_DISSOLVE_SEC` (0.8s) constant — SAME value drives the shader `dissolve` tween, so sound
   and visual can never drift. Fewer ticks (~13 vs 30), ease-in-out swell schedule (sparse ends,
   bunched middle), per-tick varied timbre (pure drop / bell / detuned-woody) + decay + amplitude
   = textured shimmer, not a glitchy uniform burst. Still in-key (snapped); rises on materialize,
   falls on dissolve.

**Worktree build note (cost time — log to KB):** the spawned worktree did NOT contain the
gitignored/untracked heavy build artifacts (Godot.app, the xcframeworks, the .xcodeproj, the
app build-support files, `.godot/` import cache). Fixed by **symlinking** them from the main
checkout into the worktree (Godot.app + the `out/xcode-visionos/*.xcframework`/PrivacyInfo +
the `GodotVisionPilot/` support files), **copying** the small `.xcodeproj` as a REAL dir (so its
`<group>`-relative pck/xcframework refs resolve to the WORKTREE, not main — a symlinked xcodeproj
would have built main's pck), and running `Godot --import` once to rebuild the global `class_name`
registry (else every `PickupAbleBody3D`/`SpawnEmitter3D`/etc. = "type not in scope" at validate).
None of those symlinks/copies are committed (binary-guard clean on all commits).

**HEADSET VERIFY CHECKLIST — see the session report / README Things to Try.**

---


## ⚠️ STATE (2026-05-31, session 5) — 4 NEW FEATURES SHIPPED (v0.7.0-music) — READ FIRST

Device app **v0.7.0-music** built (PCK parity OK) + installed to AVP; **awaiting Alex's
on-headset verify** (must quit+relaunch on headset to load the reinstall). All 4 are pure
GDScript in `test-project/main_v2.gd` — NO engine recompile, borrowed `libgodot.a` untouched.
Commits `1028d34`, `152cb69`, `a220f7a` on top of `ef9cc8b`.

**⚠️ CONCURRENCY NOTE:** a *separate* live Claude session committed **`ef9cc8b` v0.6.3-scalefix**
(object two-hand-scale spike rejection) into main DURING this session — my Read saw v0.6.2,
the file changed to v0.6.3 mid-session (mtime + a fresh commit confirmed it). I built my 4
features ON TOP of ef9cc8b (their work is good + untouched — it's in `_update_two_hand_scale`,
which none of my features touch). Lesson reinforced (already in the notes): **spawned chips on
this repo must use their own worktree** — two agents editing main_v2.gd in-place is a live hazard.

**The 4 features (all device-installed, awaiting verify):**
1. **Textured dissolve/materialize sound** — `_push_dissolve_texture()` schedules ~30 short
   scale-snapped ticks (jittered) across the full 0.8s sky dissolve = rain/typing, not one tone.
   Pitch rises on materialize / falls on dissolve. Mute checked at fire time.
2. **Gesture button panel** (`_build_gesture_panel`, grabbable, NO destruct button, left of
   ARMS/MUTE at `(-0.66,1.16,-0.45)`): poke buttons HANDS / RESET / SKY + a **GESTURES** master
   toggle (`_gestures_enabled`, gates the middle/ring/pinky dispatch ~line 729; index grab never
   gated) + a big ★BEST★ readout. New generic `_poke_buttons` registry + `_update_poke_buttons`.
   The **ARMS button is now a HANDS-MODE cycle** (`_cycle_hands_mode`): MESH hands ↔ REAL Persona
   arms, mutually exclusive (synced at launch in `_load_arms_pref`).
3. **Best score polish** — START label `best %d`→`Best: %d`; Best also on the gesture panel
   (bigger). Persistence unchanged (`user://best.txt`, survives relaunch — confirmed correct).
4. **30s music bed** — DEDICATED `_bed_audio` (non-positional AudioStreamPlayer + own generator;
   NOT the shared 0.6s 3D buffer, which would starve the chimes). 1 beat/s bass+kick+hat loop,
   final-6s urgency ramp (louder/faster/octave-up). ONE key = **C minor pentatonic**: bass riff,
   urgency tones, AND all cube-collision chimes snap to it (`_snap_to_scale`) so impacts
   harmonise. Bed fed only while `_timer_active`; resets `_bed_time=0` on round start; muted with
   the rest. Gotcha hit: untyped array elements → `Cannot infer type of "midi"`; typed the
   pentatonic `pcs` arrays `Array[int]`.

---


## ⚠️ STATE (2026-05-31, session 4) — MIXED-IMMERSION ALPHA HALO FIXED (v0.6.0-depthfix) — READ FIRST

Device app **v0.6.0-depthfix** (repo `ae78f72`). The long-PARKED mixed-immersion blocky
alpha halo is **fixed** — pure GDScript/shader, NO engine recompile, hand-tracking lib
`f968292d` untouched (grab/throw intact). Installed on AVP; **awaiting Alex's on-headset
visual confirmation.**

- **Root cause CONFIRMED (not theory):** CompositorServices requires alpha==0 wherever
  depth==0. Godot mobile XR uses reverse-Z (depth 0 = nothing drawn); transparent /
  additive / no-depth-write geometry left nonzero alpha at depth 0 → blocky halo. NOT
  alpha AA, NOT foveation, NOT MSAA (explains why every AA/MSAA/foveation dead-end failed).
- **Source:** huisedenanhai, godotengine/godot PR #109975 comment 3418064636 (custom-Metal-
  AR-renderer contributor, before/after screenshots); fix comment 3446873204, confirmed
  "worked great" by Godot XR maintainer dsnopek 2026-05-30. Converges with UE commit
  `7282ab2faf4e` (clears depth swapchain to MIN_flt).
- **Fix:** `test-project/passthrough_depth_fix.gdshader` — full-screen quad, child of
  `XRCamera3D`, writes clip-space depth `1e-8` + alpha 0 everywhere via `depth_draw_always`
  → depth is never exactly 0. `extra_cull_margin=16384` so the camera-child quad isn't
  frustum-culled (gotcha: a shader that writes clip-space POSITION still gets culled by AABB).
- Build green: validate 0 err → export → BUILD SUCCEEDED → PCK parity OK → installed.
- Full writeup + ranked alternatives: KB `intelligence/techniques/godot-avp-alpha-edge-aa.md`.
- **OPEN:** if a specific object still halos after this, it forces transparency another way →
  fix #2 (force that object opaque / make it write depth). Fresh Dev Strap screenshot now a
  confirmation, not a diagnosis.

---

## ⚠️ STATE (2026-05-31, session 3 FULL) — ROADMAP LANDED through v0.5.2-polish — READ FIRST

Device app **v0.5.2-polish**, committed `21c39b6`. This consolidates the engine chip's work
(next section) PLUS the interactive GDScript work. All device-verified along the way.

**Shipped:** 3D volumetric score text + multi-layer fireworks + boom fanfare; smaller plates;
grabbable + self-destructing panels (info / leaderboard / instructions — red poke-ball explodes
each, ring-reset restores); **30s time-attack** (pokable START, click+depress, mid-round press
cancels-to-neutral → 2nd press restarts) + **global leaderboard** (Google Apps Script GET-submit,
`tools/leaderboard/`, live `/exec` URL wired into app + index.html); **two-anchor two-hand
scale+rotate** (glued pinches; both hands pinch object OR world handle; blue outline/handle;
confirmed great); hand-drift-after-world-drag fix; min grab collider (≥0.10m); cube bloom halos +
interior lights; **immersive default** + gradual sky dissolve; **real upper-limb toggle** (REAL ARMS
button + experimental poke-wrist → `user://upper_limb.txt` polled by recompiled engine).

**Alpha blockiness PARKED** (foveation disproven; immersive default = workaround; Epic chat TBD).

**NEXT:** (1) 3-letter high-score entry — AVP keyboard NOT available in immersive CompositorServices;
build an in-world A–Z poke/dial picker (scores use `PLAYER_INITIALS` const for now). (2) fresh Dev
Strap screenshot to re-characterise the alpha halo before any engine attempt. (3) future spawned
chips must run in their OWN worktree — the engine chip ran in-place here and co-edited main_v2.gd
(merged cleanly by luck). (4) AWAITING Alex's final headset test of v0.5.2 (items 1-6 of the last batch).

---

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
- KB + daily + timing all pushed. Public cascade pushed. Fork source is **James Clancey's**
  `Clancey/godot:visionos_master_pr` (Marshall supplied the *binary*, but the branch is Clancey's).
  Our Swift change offered as a POC PR via `ibrews/godot` → `Clancey/godot`.

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
