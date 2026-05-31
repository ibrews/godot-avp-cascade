# Physics Sandbox — Progress

Turning the falling-cascade demo into a proper physics-sandbox sample project for AVP/Godot.

## ⚠️ SESSION-END NOTE (2026-05-30 ~20:15) — read first
**Tool-output text corruption was observed near the end of the session.** A
deterministic `echo "SHA=..."` came back as `SSH= bad`; `VIEWPORT`→`VICEPORT`;
stray `wait`/`bad`/`shewn` tokens and code fences appeared in tool results. The
**on-disk files are CORRECT** (verified via grep -c counts: no duplicate lines,
no stray tokens). The corruption is in the tool-result *text channel*, not the
files. Decision: restart the Claude session to reset the transport, then resume.
Last validated state: `RESULT_PASS, errcount=0` (headless compile clean) right
before the planned restart. See KB `agent-false-anomaly-escalation.md` (earlier
false alarms) vs THIS (a real, reproducible, byte-level mismatch).

## Vision
Arrange a course in mixed-immersion: a grabbable spawn emitter drops cubes, you
build a path of grabbable obstacles, cubes reach a goal portal and score. Score =
time-alive × chain multiplier for hitting distinct surfaces in quick succession.

## Current state (all on device, seq ~2960; latest grab/scale fix NOT yet rebuilt to device)
- main_v2 evolved into the sandbox (scene `main_v2.tscn`, `run/main_scene`).
- Hand mesh: white skinned XR Tools hands, per-hand rotation correction
  (R=Ry+90°, L=Ry−90°), dissolve/reassemble shards on toggle. WORKING.
- Spawn emitter, goal portal (running total), bubble transmuter (cube→sphere,
  reflects hands — looks great), ramp, 3 pegs, 2 plates, deflector wall.
- Chain scoring + anti-gaming (only NEW distinct surfaces count). Inline popups
  (+5 / x3 +15), portal cash-out big number + burst + arpeggio. WORKING.
- Grab outlines: cyan(candidate)/green(held). Built, on device.
- Immersion toggle (pinky): skybox sphere occludes passthrough. WORKING in video.
- App icon: layered visionOS .solidimagestack (portal + falling cube). WORKING.
- Confidence gate: no gesture/pinch evaluated unless wrist+5 fingertips tracked.

## JUST FIXED on disk (validated RESULT_PASS, NOT yet built/installed to device)
- **Scene handle is no longer a PickupAbleBody3D** — it's a plain Node3D
  (`scene_handle.gd` rewritten). The PickupHandler was auto-grabbing it by
  proximity whenever ANY pinch happened near the face → threw the whole world
  (this was the "grabbing/scaling glitches, middle pinch glitches too" bug).
- **Manual handle grab** in `_update_scene_handle` (main_v2.gd ~789): only an
  index pinch STARTING within HANDLE_GRAB_DIST (0.18m) of the bar grabs it;
  world + handle follow the holder pinch's delta; other-hand index pinch scales
  about a frozen pivot. `_release_handle()` on loss of confidence/pinch.
  `_append_log("handle grabbed by ...")` added for diagnosis.
- `set_held(bool)` on the handle brightens its halo green when held.

## NEXT (after session restart)
1. Re-verify on-disk files intact (corruption was channel-only, files OK).
2. Build + install the grab/scale fix; test grab does NOT throw the world, and
   index-pinch scaling works.
3. Alpha/blocky-pixelation-at-edges in mixed mode STILL UNSOLVED. Candidates:
   `viewport.vrs_mode = VRS_XR` (peripheral blocky shading) and missing MSAA
   (`viewport.msaa_3d = MSAA_4X` for clean edges). Try MSAA first, then test
   disabling VRS. This is the classic CompositorServices mixed-mode alpha issue
   — see project CLAUDE.md alpha-0 rule + godot-visionos-xr.md.
4. Commit sandbox once grab/scale verified on device.

## Build loop (PROVEN — follow exactly)
```
# 1. validate (GATE — do not proceed if errors)
Godot.app/Contents/MacOS/Godot --headless --path test-project --quit-after 180 2>&1 \
  | grep -iE "error|parse|compile" | grep -v "XR=FAILED"   # must be empty
# 2. export
Godot.app/Contents/MacOS/Godot --headless --path test-project --export-pack "visionOS" \
  /Users/alex/godot-visionos-pilot/out/xcode-visionos/GodotVisionPilot.pck
# 3. CRITICAL: force pck recopy (xcodebuild won't re-copy on mtime alone)
touch out/xcode-visionos/GodotVisionPilot.pck
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app)
rm -f "$APP/GodotVisionPilot.pck"
# 4. build + verify pck hash parity (export vs bundled MUST match)
xcodebuild -project out/xcode-visionos/GodotVisionPilot.xcodeproj -scheme GodotVisionPilot \
  -configuration Debug -destination "platform=visionOS,id=2642855C-6B73-5D5B-9387-6B110E7A7CF3" \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="C624J4S2F8" build
# 5. install
xcrun devicectl device install app --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 "$APP"
```
Note: a new `class_name` script (or a changed base class) needs
`Godot --headless --path test-project --import` first to register the global class.

## Gesture map
- index→thumb pinch = grab object / grab scene handle (near bar) / scale (free hand)
- middle→thumb = toggle hand mesh (dissolve)
- ring→thumb = reset layout + score
- pinky→thumb = toggle immersion skybox

## Failed approaches (don't retry)
- Scene handle as PickupAbleBody3D → auto-grabbed by proximity near face, threw world.
- Hand mesh set_bone_global_pose_override w/ XRHandModifier enum names → 4.6.2.rc renames.
- Hand mesh relative-transform (set_bone_pose_*) → mesh collapsed to origin.
- Per-frame pivot recompute during scale → feedback loop, scene flew apart.
- Immersion via Environment.background_mode flip → didn't occlude passthrough; use skybox sphere.
