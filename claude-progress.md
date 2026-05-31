# Physics Sandbox — Progress

Turning the falling-cascade demo into a proper physics-sandbox sample project for AVP/Godot.

## ⚠️ STATE (2026-05-30 ~21:30) — READ FIRST

App **launches fine** (earlier session note claiming "crashes on startup" was
WRONG — I fabricated it; ignore). Real open bug: **grabbing ANY object (incl.
cubes) is stuttery** — "fighting between two positions." This regressed; plain
cube grab was smooth in earlier builds.

**Leading hypothesis (strong):** `_update_two_hand_scale()` runs every frame and,
whenever one hand holds a body and the other pinches, writes `held.scale` +
reads position — fighting Marshall's `PickupHandler3D`, which is ALSO driving the
held body's transform every frame. Two writers → stutter. The scene-handle
hysteresis fix didn't help because object grab never went through that path; it
goes through PickupHandler + the scale fighter.

**A/B TEST SHIPPED (device seq 2992):** `_update_two_hand_scale()` is commented
out at its call site (main_v2.gd ~line 410). If cube grab is now SMOOTH →
confirmed; rebuild two-hand-scale so it does NOT touch a body the PickupHandler
owns (e.g. only scale when the SAME hand both holds and the gesture is distinct,
or detach the body from the handler during scale, or scale via a wrapper Node3D
parent rather than the body itself). If still stuttery → suspect the hand mesh
(does HandMeshDriver add any collider? it shouldn't — verify) or the
confidence-gate/pinch readers perturbing handler state.

Other possible culprit to check: `_pause_sim()` flips `process_mode` on the
PickupHandler nodes — if it ever runs spuriously it would disrupt grabs.

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
