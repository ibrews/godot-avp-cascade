# Physics Sandbox — Progress

Turning the falling-cascade demo into a proper physics-sandbox sample project for AVP/Godot.

## ✅ STATE (2026-06-03) — sample-project polish pass (code/doc cleanup, NO behavior change)

Cleaned the GDScript + README so the repo reads as a clear Godot-on-AVP **sample project**. No
behavior change — headless-validated ("Sandbox built", 0 script errors), and the engine
`.a`/`.xcframework`/PCK/xcodeproj were NOT touched, so grab/hand-tracking are byte-for-byte the
same as shipped build 7.

- **main_v2.gd** (2877 → 2847 lines): removed the dead grab telemetry (`_gdiag` / `GRAB_DIAG` /
  `grab_diag.txt`, the SCALE_ENGAGE/END calls, the `_ready` header init, `_hand_holds`) — it was
  gated `false` and the KB already said to strip it at ship. Removed dead state (`_sim_paused`,
  `_scaling_body`, `_scale_start_*`, `_world_scale_*`) and dead funcs (`_wrist_world`, `_pinch_point`).
  Added 16 `# ===` section banners; fixed stale comments (header gesture map now lists all four
  pinches incl. pinky→sky; moved the `_which_finger_pinch` doc off `_hand_confident`). **KEPT** the
  `xr_diag.txt` FPS diagnostic (`_grab_diag`/`_write_log`/`_append_log`, now clearly labelled) and
  every teaching gotcha (XROrigin3D.current, alpha-0 bg, FREEZE_MODE_STATIC-while-held, VALID-vs-TRACKED…).
- **pickup_handler.gd**: fixed 3 comments that still named the removed ORIGINAL/WRIST/THUMB A/B grab
  modes (collapsed to THUMB-only on 2026-06-02).
- **hand_visualizer.gd**: it's an unwired orphan (`HandVisualizer3D` is never instantiated) — documented
  it as an OPTIONAL debug tool instead of deleting. **REVIEW_NEEDED:** delete it if you don't want it kept.
- **README**: fixed the stale grab description ("snap to pinch midpoint" → grab-by-point / thumb anchor)
  and "Yellow outline" (→ cyan/green/blue states); Status bumped to build 7 / `v0.9.34`; added the
  two-hand-scale, control-panel and wrist-menu-hidden features.
- **chore**: gitignored `.claude/` (local agent memory/worktrees — was untracked in a public repo).

---

## ✅ STATE (2026-06-02, session 7k) — v0.9.34-nowrist SHIPPED to TestFlight (build 7) — READ FIRST

**Wrist/Home menu hidden — and it did NOT need an engine rebuild.** The build-6 "OPEN follow-up"
below assumed `.persistentSystemOverlays(.hidden)` required a 30-90 min engine rebuild. **WRONG.**
The Clancey engine lib ALREADY has `.persistentSystemOverlays(Self.preferredPersistentSystemOverlays)`
on the CompositorLayer content, reading the Info.plist key `GodotPersistentSystemOverlays` (default
`.automatic`) — an exact sibling of the proven `GodotUpperLimbVisibility` key. Confirmed the reader
is compiled into the SHIPPING `libgodot.a` via `strings`. So the fix = ONE Info.plist key, NO rebuild,
`libgodot.a` byte-for-byte unchanged → **zero hand-tracking risk**. (Even a rebuild would've been ~12s
incremental, not 30-90 min — the `bin/obj/` cache is intact — but it wasn't needed at all.)

**Shipped build 7** (v1.0, panel `v0.9.34-nowrist`): `GodotPersistentSystemOverlays=hidden` in
GodotVisionPilot-Info.plist, CURRENT_PROJECT_VERSION 6→7, re-exported PCK (`a2f9b51e`, parity-verified
inside the archived `.app`), ARCHIVE SUCCEEDED → Upload succeeded → EXPORT SUCCEEDED (ASC key
79HM47GZ7C). Committed `fe121bb` (NOT pushed — manual push per project convention).

**PENDING device verify (Alex):** install build 7 from TestFlight → confirm (a) hand tracking/grab
still work AND (b) the wrist/Home menu is gone. If grab regressed, it is NOT this change (lib untouched);
nothing to restore. If `.persistentSystemOverlays(.hidden)` doesn't hide the specific menu Alex means,
that's an Apple-API scope question, not a build problem.

---

## ✅ STATE (2026-06-02, session 7j) — v0.9.33-thumbgrab SHIPPED to TestFlight (build 6) — READ FIRST

**Grab + scale interaction set DONE and shipped.** TestFlight **build 6** (v1.0, in-world panel
`v0.9.33-thumbgrab`) uploaded successfully (ARCHIVE SUCCEEDED → Upload succeeded → EXPORT SUCCEEDED;
ASC key 79HM47GZ7C). Processing on Apple's end (~5-15 min to appear). This carries the whole pending
v0.9.x local batch + the entire grab/scale fix saga.

**Final grab design = THUMB-only** (collapsed from the 3-mode A/B cycle): the handler exposes a
de-spiked thumb-tip world transform; the body uses it as the single grab source (pivot = thumb
origin, rotation = thumb basis), grab-by-point + one-euro + clean-release-on-open. Sticky-release
(timer accrues only while well-observed + open) prevents false drops. Stripped: the WRIST/ORIGINAL
modes, the in-world DEBUG button, and all grab telemetry (GRAB_DIAG=false; grab_diag.txt/_gdiag).
Kept the xr_diag.txt FPS diagnostic. Code: ~1394 lines (peak) → ~580 across the two pickup files.

**Full root-cause cascade + the VALID-vs-TRACKED lesson** is written up in KB
`intelligence/techniques/godot-avp-grab-by-point.md` (Root-cause cascade + resolution section). The
one-line takeaway: on this hand path, gate interactions on `POSITION_VALID`, reserve `POSITION_TRACKED`
for confidence checks — the grabbing/pinching hand's own fingers go not-TRACKED under self-occlusion,
which was behind the false-release, the grab-point slide, and the scale flicker.

**OPEN follow-up (spun off as a chip):** disable the AVP "wrist menu" via
`.persistentSystemOverlays(.hidden)` — it's in `clancey-godot/platform/visionos/app_visionos.swift`
(the ENGINE), so it needs a 30-90 min engine rebuild + re-ship. Deliberately NOT in build 6.

**Commit:** the whole batch was committed + pushed to origin/main after the ship (was uncommitted
since e7b66c2 / the v0.9.27 restore point).

---

## ⚠️ STATE (2026-06-02, session 7i) — v0.9.32-scalevalid: two-hand scale occlusion fix — READ FIRST

Device app **v0.9.32-scalevalid** built + installed (validate clean; PCK `9541fd91` parity-matched
`gidtuid…`; install try 1). **Grab CONFIRMED good by Alex** ("grab feels better now" on v0.9.31
anchorfresh). Now fixing two-hand SCALE ("kind of broken, hard to activate"). Restore point on
origin/main still `e7b66c2`; all consolidation+fixes uncommitted (gated on verify).

**Scale diagnosis (from grab_diag SCALE lines):** rapid SCALE_ENGAGE→SCALE_END pairs (0.2-1.2s) —
the gesture engaged then tore down every few frames. Root cause (same VALID-vs-TRACKED trap, but in
main_v2's pinch detector, NOT my rewritten files — pre-existing): `_index_pinch_point` → `_hand_confident`
required ALL FIVE fingertips + wrist `POSITION_TRACKED`. Two hands pinching close to scale occlude each
other's fingers → a tip drops to estimated-not-TRACKED → `_index_pinch_point` returns null → scale ends
(after SCALE_END_GRACE). Engage logic itself is fine (one hand holds via handler.picked_up_body + the
other pinch within `_obj_reach`).

**Fix:** `_index_pinch_point` now gates on only **thumb(5)+index(10) POSITION_VALID** (estimate ok,
holds through occlusion) instead of `_hand_confident` (all-5-TRACKED). `_hand_confident` is untouched
(still used elsewhere). + bumped `SCALE_END_GRACE` 4→8 frames for extra debounce.

**HEADSET VERIFY (Alex — `v0.9.32-scalevalid`):** grab an object with one hand, pinch it with the
other → two-hand scale should ENGAGE and HOLD steadily (no flicker), scale/rotate smoothly, and the
world-handle two-hand scale too. Grab itself unchanged (still solid).

**THEN — FINAL COLLAPSE + SHIP** (once scale confirmed): collapse to THUMB-only (drop WRIST/ORIGINAL
modes + DEBUG button + the GRAB log + grab_diag), update KB `godot-avp-grab-by-point.md` with the full
resolution, commit the whole batch, TestFlight per `~/knowledge/projects/godot-avp-cascade.md`.

---

## ⚠️ STATE (2026-06-02, session 7h) — v0.9.31-anchorfresh: REMOVED the grab-point restore — READ FIRST

Device app **v0.9.31-anchorfresh** built + installed (validate clean; PCK `871fb626` parity-matched
`gidtuid…`; install try 1). Default THUMB. **Awaiting Alex's verify.** Restore point on origin/main
still `e7b66c2` (v0.9.27); consolidation+fixes since are uncommitted (gated on verify).

**v0.9.30 STILL slid to old grab points** (fingers in view). Couldn't pull logs — the device tunnel
was timing out for `copy` (failed ~7×; install still worked). Diagnosed from code instead, narrowed
to ONE cause: the only path that keeps an OLD `_grab_point_local` is the restore (`restore=true`); and
a grab can only fire when both tips are TRACKED (`_get_pickup_value` returns 0 otherwise) so the thumb
anchor is always fresh AT the grab (never stale). ∴ the snap IS the restore firing. For it to fire,
`_pinch_view_lost()` had to trip within 600 ms before the release — and the **fast open/release
gesture flickers the VALID flag** even with the hand in view, so it false-fired on deliberate
re-grabs. Two flag-based criteria (not-TRACKED v0.9.29, VALID v0.9.30) both mis-fired.

**Fix: REMOVED the grab-point restore entirely.** Every grab recomputes `_grab_point_local` at the
current thumb — anchors right where you grab, always. Deleted: `wants_grab_point_restore`,
`_pinch_view_lost`, `_last_pinch_lost_ms/_last_release_uncertain/_last_release_ms/_last_released_body`,
`POST_DROPOUT_RESTORE_MS`, `REGRAB_RESTORE_MS`, the pinch-lost tracking + release-flag writes, the
body's restore branch. **The lost-view need is already covered by sticky-release** (it HOLDS the
object through a dropout — never drops it — so there's nothing to "restore"). Kept a minimal `GRAB
obj=… thumb_valid=… thumb_tracked=…` log (confirms grabs require TRACKED ⇒ anchor fresh); strip at collapse.

**KEY LESSON (→ KB):** the hand-tracking VALID/TRACKED flags are too noisy to reliably detect a
"genuine lost view" vs a normal fast open gesture — don't build behavior on a "was tracking lost"
heuristic. Rely on sticky-release (hold-through-dropout) instead.

**HEADSET VERIFY (Alex — `v0.9.31-anchorfresh`, default THUMB):** grab corner → release (hand in
view) → grab center → must anchor at CENTER, no slide, every time. If clean → collapse to THUMB-only,
strip the GRAB log + cycle + DEBUG button, commit, TestFlight.

**Device note:** the AVP tunnel was very flaky this session (copy timeouts; needed a headset restart
to clear a wedged compositor where no immersive app would present). Keep the headset on-head for log pulls.

---

## ⚠️ STATE (2026-06-02, session 7g) — v0.9.30-grabvalid: lost-view detection = VALID not TRACKED — READ FIRST

Device app **v0.9.30-grabvalid** built + installed (validate clean; PCK `ba6cf8b8` parity-matched
`gidtuid…`; installed try 1). **Awaiting Alex's verify.** Not committed (restore point `e7b66c2`).

**v0.9.29 STILL slid to old grab points** even with the scoped restore — Alex correctly noted his
pinch joints weren't dropping out. ROOT CAUSE: the v0.9.29 lost-view detector used
`_joint_has_tracked_position` (POSITION_VALID **and** POSITION_TRACKED). A HELD OBJECT occludes the
pinching fingers, so the joints routinely read **VALID-but-not-TRACKED** (estimated) — the handler's
own earlier notes already documented "tips read 'V-' under occlusion." So `_last_pinch_lost_ms` was
updated on basically every held frame → EVERY release flagged `_last_release_uncertain` → the restore
fired on every re-grab → the slide persisted. (Also: I'd stripped the per-grab telemetry in the
consolidation, so "check my logs" found only the header + SCALE lines — nothing to diagnose from.)

**Fix:** new `_pinch_view_lost()` keys on **POSITION_VALID** only — a genuine lost view = NEITHER tip
has even an estimated position (hand left the cameras). Normal occluded holding stays "observed", so
deliberate re-grabs anchor fresh; only a true out-of-view arms the restore. Re-added a MINIMAL one-
line-per-grab log (`GRAB obj=… restore=… uncertain=… since_release_ms=… same=…`) to verify on device;
strip at the final collapse.

**General lesson (for the KB):** on this hand path, distinguish VALID (has an estimate) from TRACKED
(high-confidence). A held object makes the grabbing hand's own pinch joints not-TRACKED as a matter
of course — so any "is the hand observed" gate that needs TRACKED will false-trigger during every
normal hold. Use VALID for "do we have a usable position", reserve TRACKED for confidence only.

**HEADSET VERIFY (Alex — `v0.9.30-grabvalid`, default THUMB):** grab a corner, release (hand in
view), re-grab the center → must anchor at CENTER (no slide). Then I'll pull the GRAB log (expect
`restore=0` on those deliberate re-grabs). If clean → collapse to THUMB-only + strip the log + TestFlight.

---

## ⚠️ STATE (2026-06-02, session 7f) — v0.9.29-freshgrab: default THUMB + scoped grab-point restore — READ FIRST

Device app **v0.9.29-freshgrab** built + installed (validate clean; PCK `be9dc562` parity-matched
`gidtuid…`; install needed 1 retry — AVP off-head). **Awaiting Alex's verify.** Consolidation NOT
committed yet (the v0.9.27 checkpoint `e7b66c2` on origin/main is the restore point).

**Alex's verdict: THUMB feels best.** Default is now THUMB (grab_mode=1; DEBUG still cycles
WRIST/THUMB/ORIGINAL). Remaining issue he flagged: the grab had "too long a memory" — re-grabbing a
DIFFERENT spot on the same object slid it to the OLD grab point. Cause: the quick-regrab restore
(was 1.5s, unconditional) kept the original grab point on ANY re-grab.

**Fix (scoped grab-point restore):** every grab now anchors fresh right where you grab — EXCEPT a
genuine lost-view recovery. The handler tracks `_last_pinch_lost_ms` (pinch joints untracked while
held); on release it flags `_last_release_uncertain = (release within POST_DROPOUT_RESTORE_MS=600ms
of a lost-view)`. The body's pick_up calls `handler.wants_grab_point_restore(self)` → restores the
original `_grab_point_local` ONLY if that flag is set AND it's the same body within
REGRAB_RESTORE_MS=1000ms. A clean deliberate release (no recent dropout) → fresh anchor. (Per Alex's
steer: keep the restore but scope it to lost-view, ~1s window.)

**OPEN — AVP "wrist menu":** Alex asked to disable the AVP wrist menu ("simple one-line setting?").
Checked `GodotVisionPilot-Info.plist` — no obvious key (it's a CPSceneSessionRoleImmersiveSpace app;
keys are standard: immersion style, GodotUpperLimbVisibility, hand/world-sensing usage). Not certain
what the "wrist menu" is in visionOS terms — asked Alex to describe/screenshot before changing
anything (avoid a hallucinated plist key). Many AVP system affordances (Control Center, Home) aren't
app-disablable; if it's something else, find the setting.

**HEADSET VERIFY (Alex — `v0.9.29-freshgrab`, default THUMB):**
1. Grab corner, release, re-grab center → should anchor at CENTER now (no slide to the old corner).
2. Confirm the clean-release (no spin) + de-spike (no jump) still hold.
3. Clarify the wrist menu.
Then: collapse to THUMB-only (drop the cycle + DEBUG button), commit, TestFlight.

---

## ⚠️ STATE (2026-06-02, session 7e) — v0.9.28-finalists: CONSOLIDATED grab + 3-way cycle — READ FIRST

Device app **v0.9.28-finalists** built + installed (validate clean; PCK `89440bab` parity-matched
`gidtuid…`). **Awaiting Alex's A/B + sign-off.** The v0.9.27 checkpoint is pushed to origin/main
(`e7b66c2`) as a restore point; THIS consolidation is NOT committed yet (gated on device verify).

**Why:** Alex asked to compare against the original Nowak grab and check if we'd overcomplicated.
Archaeology (git): original `f7ac2d6` = 401 lines (reparent-ride + IDENTITY centre-snap); the
good grab-by-point core landed at `35da93b` = 753 lines; we'd drifted to **1394 lines**, ~half of
it telemetry + the 4-mode A/B multiplexer + dead helpers. Verdict: core not broken, just buried;
the crazy-rotation-on-release is OUR orientation-following addition (the original didn't follow a
joint, so it couldn't spin on release).

**v0.9.28 = consolidation (714 lines: body 340 + handler 374).** STRIPPED: GRAB_DIAG/_gdiag, ORICMP,
PINCH_DIAG, the trace/release/grab-snap probes, glitch-gate, wrist-rigid anchor, palm/locked modes,
`_has_confident_hand_release_signal`, `_is_controller_profile_input`. KEPT (load-bearing): firm-pinch
detection, de-spiked midpoint anchor + thumb-tip de-spiked anchor, sticky-release (false-release
fix), one-euro follow, grab-by-point, two-hand scale integration, throw, highlights, all @exports.

**DEBUG button now cycles 3 FINALISTS** (`grab_mode`, default 0 = WRIST), all on the de-spiked
**thumb-tip anchor**:
- **0 WRIST** — thumb-tip pivot + rotation from the WRIST joint (calmest; stable as you open → no spin)
- **1 THUMB** — thumb-tip pivot + rotation from the THUMB-TIP joint (rotates with the thumb)
- **2 ORIGINAL** — Nowak reparent-ride (centre-snap, controller pose, no filter) — the baseline

**CLEAN-RELEASE built in (the crazy-rotation-on-release fix):** the handler sets
`body.follow_suspended=true` the instant the pinch opens; the body then HOLDS its rotation (so the
opening hand can't spin it) — and a freeze_on_release body also holds position (no thumb-drag), while
throwable cubes keep following position for throw velocity. (ORIGINAL mode is faithful = no
clean-release, so it'll still show the baseline release behavior.)

**HEADSET A/B (Alex — `v0.9.28-finalists` on the panel; default WRIST):**
1. Confirm NO crazy rotation on release in WRIST and THUMB (ORIGINAL will still spin — that's the
   baseline). 2. Confirm no grab jump (de-spike). 3. Cycle WRIST↔THUMB↔ORIGINAL, pick the winner.
Then I collapse to the chosen mode (drop the cycle + DEBUG button), commit, and TestFlight.

---

## ⚠️ STATE (2026-06-02, session 7d) — v0.9.27-thumbfix: THUMB anchor de-spike + freeze-on-open — READ FIRST

Device app **v0.9.27-thumbfix** built + installed (validate clean; PCK `301d6dbd` parity-matched
`gidtuid…`). **Awaiting Alex's re-test.** Still cycles THUMB/WRIST/PALM/LOCKED (THUMB default).

**Alex's v0.9.26 feedback:** THUMB wins for anchor + rotation ("locks into a spot on the plate";
WRIST's grab point visibly DARTS on the plate as you rotate = wrist-orientation noise amplified
through the long wrist→pinch offset into position wander). THUMB's two defects: (1) sticky release
("stays resting on my thumb" — the opening hand drags the thumb-anchored object out); (2) the plate
sometimes JUMPS to a new spot on press/release. Logs confirmed (2): the raw thumb-tip POSITION
glitches at the grab instant — 3/21 THUMB grabs spiked |body−anchor| to 0.35–0.40 m (normal 0.19 m)
→ a wrong grab point baked in → ~15–20 cm jump.

**v0.9.27 fixes (THUMB anchor kept — it's the winner):**
- **De-spike the thumb-tip anchor**: median-of-3 on the thumb-tip POSITION (same trick as the
  fingertip anchor), sampled every render frame in the handler (`_sample_thumb_anchor` /
  `thumb_anchor_xf`), exposed via `thumb_anchor_xform()`; holds last-good through a dropout. Kills
  the grab jump. Orientation passes through (body slerp+clamp smooth it).
- **Freeze-on-open** (general, gated to `freeze_on_release` bodies = plates/wall): the handler sets
  `picked_up_body.follow_suspended = true` the instant the pinch opens; the body holds its pose
  while suspended (early-return in `_process`) instead of following the opening hand → clean release,
  no thumb-drag, and a re-pinch resumes from the held pose (no jump). Throwable cubes don't set
  `freeze_on_release` so they keep following (throw velocity preserved). Handler sets it false while
  pinched; `pick_up` resets it false.

**HEADSET RE-TEST (Alex — `v0.9.27-thumbfix` on the panel; default THUMB):**
1. Repeatedly press/release a plate on the same spot — should NOT jump to a new location anymore.
2. Grab a plate, position it, open to release — it should stay where you opened (no "resting on the
   thumb" drag-out).
3. Rotate one-handed — grab point should stay locked on the plate (as before).
4. Cubes should still THROW (freeze-on-open doesn't apply to them).
If THUMB now feels right → declare it the winner; I collapse to it, strip all modes + scaffolding,
TestFlight.

---

## ⚠️ STATE (2026-06-02, session 7c) — v0.9.26-thumbpin: ONE-HANDED GRAB A/B (4 MODES) — READ FIRST

Device app **v0.9.26-thumbpin** built + installed (validate clean; PCK `b4b21a19` parity-matched
`gidtuid…`; clean install). **Awaiting Alex's A/B feel-test via the in-world DEBUG button.**

**Why this build:** v0.9.24-palmrot's palm-rotation fixed the stationary "walks on every pinch"
problem, but Alex reported (a) one-handed ROTATION still felt "ridiculous" and (b) pulling the
INDEX away from the thumb (pre-release) moved/rotated the object. ORICMP telemetry from v0.9.24
explains (a): the **PALM orientation SPIKES ~190 rad/s under motion** (p90 187, max 199) while the
**WRIST stays ~10x calmer** (p90 16, max 64); aim was median 13.7. So palm was a poor rotation
source under motion. For (b), Alex's fix: anchor to the **THUMB TIP** (the stable side) so index
movement is irrelevant.

**The DEBUG button now cycles 4 one-handed grab modes** (`PickupAbleBody3D.grab_mode`,
GRAB_MODE_NAMES, label on the DEBUG panel). Default = mode 0 THUMB:
- **0 THUMB** (default): object RIGID to the `HAND_JOINT_THUMB_TIP` transform for BOTH the
  position pivot AND rotation. Moving the index (pinch/pull, pre-release) does nothing — only the
  thumb carries/rotates it. Capture of `_grab_rot_offset` + `_grab_point_local` and the _process
  pivot/basis all come from the thumb-tip transform. Handler exposes `joint_world_transform(joint)`
  (last-good hold per joint). This directly answers Alex's index-independence requirement.
- **1 WRIST**: rotation from the WRIST joint basis; position = existing de-spiked wrist-rigid
  anchor. (Also index-independent; the data-calmest rotation source.)
- **2 PALM**: rotation from PALM joint (the v0.9.24 baseline — spikes under motion; reference).
- **3 LOCKED**: no one-handed rotation; holds grab orientation (`_locked_basis`); rotate w/ 2 hands.

Implementation: handler `joint_orientation_basis(joint)` + `joint_world_transform(joint)` (per-joint
last-good dict cache, rendered through XROrigin). Body `_orient_basis(holder)` picks wrist/palm by
mode; `_thumb_xform(holder)` returns the thumb-tip transform in THUMB mode (else null → other
modes). ORICMP telemetry (palm/wrist/aim angular speed) still logging. `_locked_basis` seeded at
the follow seed.

**HEADSET A/B (Alex — `v0.9.26-thumbpin` on the info panel):**
1. THUMB (default): grab a plate; pull your index away from the thumb WITHOUT releasing → it must
   NOT move or rotate. Rotate your whole hand → the object should rotate with your thumb.
2. Poke the DEBUG · GRAB MODE button to cycle THUMB → WRIST → PALM → LOCKED; compare the feel of
   one-handed rotation in each. (Readout shows the active mode.)
3. Tell me which feels best → I lock it in as the single behavior and strip the other modes + all
   debug scaffolding, then TestFlight.

After Alex picks: collapse to the chosen mode, strip GRAB_DIAG/ORICMP/DEBUG button/dead probes,
update KB `godot-avp-grab-by-point.md`, ship.

---

## ⚠️ STATE (2026-06-02, session 7b) — v0.9.24-palmrot: ROTATION SOURCE = PALM JOINT — READ FIRST

Device app **v0.9.24-palmrot** built + installed to AVP (validate clean; PCK sha `d23a8562`
parity-matched `gidtuid…`; install clean, no retry). **Awaiting Alex's headset feel-test.**

**What v0.9.23 telemetry (grab_diag.txt) proved on device:**
- **Issue 1 (false release): FIXED.** 55 `STICKYHOLD obs=0` lines = held *through* dropouts; the
  52 `(grace)` releases now only fire when `obs=1` (well-observed). The timer-reset fix works.
- **Issue 2 (rotation): my v0.9.23 no-snap fix was INSUFFICIENT.** Alex re-pinched the SAME spot
  repeatedly and the object kept ROTATING. Root cause (confirmed by telemetry, exactly Alex's
  hypothesis): the held body's rotation followed the **controller "aim" basis** (`holder.basis`,
  inherited from the XRController3D pose), which is derived from the pinch geometry and is
  violently noisy — HOLD `ang_spd` **median 20.1 rad/s (~1150°/s), p90 93, max 261** while
  "holding still"; the angular spike-clamp `clampA` fired on **608/1108 = 55%** of held frames.
  Each pinch/open swung the aim basis → the object's orientation walked every grab/release.

**The v0.9.24 fix (Alex's call: use a stable bone, not the fingers/wrist — the PALM):**
- `pickup_handler.gd`: new `grab_orientation_basis()` returns the **`HAND_JOINT_PALM`** world
  basis (rendered through the XROrigin like the position anchor), holding the last good palm
  through a 1-frame flicker so the source never switches palm↔aim mid-hold. `_joint_world_basis`
  helper (ORIENTATION_VALID gate).
- `pickup_able_body.gd`: new `_orient_basis(holder)` reads that palm basis (fallback = aim basis
  only if palm never available). Used BOTH where `_grab_rot_offset` is captured (pick_up, normal
  + quick_regrab) AND where `target_basis` is applied (_process) — so capture/apply use the SAME
  source (no snap). Position pivot still = the de-spiked WRIST anchor (`holder_xform.origin`).
- **Telemetry added (`ORICMP`)**: per-frame angular speed of palm vs wrist vs aim while holding,
  max-per-window @ ~5 Hz. Confirms whether the palm is actually the calmest source (and gives
  wrist as a backup if palm isn't perfect).

**HEADSET VERIFY (Alex, look for `v0.9.24-palmrot` on the info panel):**
1. Re-pinch a STATIONARY plate repeatedly on the same spot — the object must NOT rotate on grab
   OR release. It should hold its orientation.
2. Rotate your whole hand while holding — the object SHOULD rotate with your palm (that's wanted).
3. (Issue 1 regression check) hold through finger-occlusion dropouts — must not let go.

After verify, pull `grab_diag.txt` and read the `ORICMP` lines: expect `palm_max` ≪ `aim_max`
(palm calm, aim noisy). If palm is also noisy, the data tells us to try wrist or smooth the palm.

---

## ⚠️ STATE (2026-06-02, session 7) — v0.9.23-grabfix: TWO GRAB BUGS FIXED — READ FIRST

Device app **v0.9.23-grabfix** built + installed to AVP (validate clean: "Sandbox built", 0
script errors; PCK sha `b4ffa14a` parity-matched the installed bundle `gidtuid…`; install
needed 1 retry — AVP was asleep). **Awaiting Alex's on-headset feel-test of the two fixes.**
Builds on the uncommitted v0.9.22-responsive WIP. Nothing committed yet — gated on verify.

**The two fixes (both precisely diagnosed from `grab_diag.txt` before this session):**
1. **False "(grace)" release on a tracking dropout** — `pickup/pickup_handler.gd`
   `_physics_process`. The release timer (`release_started_msec`) used to accrue while we held
   through `not _hand_well_observed()` (index+thumb tips untracked). When tracking returned —
   often with the estimate still splayed (`val≈0`) — the grace window (180 ms) had ALREADY
   elapsed during the blackout → an instant release fired even though the user kept pinching
   (telemetry: 36/39 releases were "(grace)"). **Fix:** when `not well_observed`, reset
   `release_started_msec = 0`; the timer now only accrues while WELL-OBSERVED and open, so a
   disappearance→return can't carry an elapsed timer. `held_open_ms` guarded to 0 when the
   timer isn't started (so `fallback` can't false-fire off `now-0`). The wrist anchor carries
   the object through the dropout; a real release needs a fresh sustained open in clear view.
2. **~157° rotation snap on quick re-grab** — `pickup/pickup_able_body.gd` `pick_up()`. The
   quick-regrab restore (same body re-grabbed within `REGRAB_RESTORE_MS=1500`) KEPT the stale
   `_grab_rot_offset` captured against the holder basis at the ORIGINAL grab; on re-grab the
   holder basis differs (orientation noise + elapsed time), so the follow target
   `holder.basis * stale_offset` ≠ current orientation → snap up to ~157° (grab_snap.txt). The
   "snap on release" report was really the snap at the immediately-following re-grab
   (release_trace showed ZERO post-release drift; 35/39 grabs were regrab=1). **Fix:** on
   quick_regrab, RECAPTURE `_grab_rot_offset` fresh vs the CURRENT holder+body basis (frame-0
   target == current basis → no snap), while still preserving `_grab_point_local` (position
   anchor) and letting the follow reseed adopt current scale. Quick-regrab now preserves
   position only, not rotation.

**HEADSET VERIFY (Alex, headset on, look for `v0.9.23-grabfix` on the info panel):**
1. Grab a plate and hold through repeated index+thumb dropouts (wave the other hand / a plate
   across the holding hand to occlude the pinch) — it must NOT let go. Deliberate release
   (sustained open hand in clear view) must still work.
2. Grab/release a STATIONARY plate repeatedly — NO rotation snap on grab OR on re-grab.

**THEN (gated on Alex's "feels solid"):** FULL POLISH CLEANUP (strip all debug scaffolding —
grab_diag/GRAB_DIAG, the DEBUG grab-mode button + modes, the trace/release/grab-snap probes,
dead `_glitch_gate`/`_has_confident_hand_release_signal`/`_is_controller_profile_input`/
`_wrist_world`, private-KB-link + version/session comments; keep the educational gotcha
comments) → ship to TestFlight with the pending batch per `~/knowledge/projects/godot-avp-cascade.md`.
Then update KB `intelligence/techniques/godot-avp-grab-by-point.md` + commit/push KB.

**DEEPER root cause (optional, after the two fixes):** Godot's raw hand-ORIENTATION stream is
very noisy on this engine path (~54 rad/s while held steady; `clampA` fired ~90% of held
frames) while Apple's Persona tracking is smooth → it's the Godot/OpenXR hand-data path. The
RESPONSIVE vs DAMPED modes feel identical because discrete snaps + orientation noise dominate.
Candidate: drive grab ROTATION from the WRIST JOINT (like the position anchor) instead of the
controller "aim" basis — but FIRST add telemetry comparing wrist-joint vs controller-basis
per-frame angular speed, then decide.

---

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
