# HANDOFF — godot-avp-cascade physics sandbox (2026-05-30 ~20:30)

Read project CLAUDE.md first (build recipe, alpha-0 rule, engine-swap fragility).

## Goal
Physics sandbox on AVP/Godot (Clancey hand-tracking fork). Arrange a course
(grabbable spawn emitter → obstacles → goal portal that scores cubes). Chain
scoring, bubble transmuter, hand mesh, scene handle to move/scale whole world.

## Build loop (FOLLOW EXACTLY — validation GATES export)
```
cd /Users/alex/godot-visionos-pilot
Godot.app/Contents/MacOS/Godot --headless --path test-project --quit-after 150 2>/tmp/v.txt
grep -icE "SCRIPT ERROR|Parse Error|Compile Error" /tmp/v.txt   # MUST be 0; do NOT export if >0
Godot.app/Contents/MacOS/Godot --headless --path test-project --export-pack "visionOS" \
  /Users/alex/godot-visionos-pilot/out/xcode-visionos/GodotVisionPilot.pck
touch out/xcode-visionos/GodotVisionPilot.pck   # CRITICAL: xcodebuild won't recopy on mtime alone
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app)
rm -f "$APP/GodotVisionPilot.pck"
xcodebuild -project out/xcode-visionos/GodotVisionPilot.xcodeproj -scheme GodotVisionPilot \
  -configuration Debug -destination "platform=visionOS,id=2642855C-6B73-5D5B-9387-6B110E7A7CF3" \
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="C624J4S2F8" build
# verify: shasum export pck == bundled pck (PCK_PARITY)
xcrun devicectl device install app --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 "$APP"
```
New class_name script → run `--import` first to register globals.

## IN PROGRESS THIS TURN (NOT yet built/installed — last device build seq 2976)
Fixing 3 grab bugs in test-project/main_v2.gd:
1. Stutter "fighting two positions" = pinch flicker. FIXED: added
   `_index_pinch_point(side)` (~line 760) with hysteresis (PINCH_START 0.032,
   PINCH_END 0.060) + "index must be CLOSEST finger to thumb".
2. Middle pinch read as index. FIXED by the closest-finger test above.
3. Pause-on-grab (user request). DONE: `_pause_sim()`/`_resume_sim()` (~line 905)
   freeze cubes + disable pickup handlers while handle held. Called in
   `_update_scene_handle` acquire/`_release_handle`.

### LAST STEP REMAINING (do this first):
Line ~973 `_update_two_hand_scale` still calls plain `_pinch_point(other_side)`.
Change it to `_index_pinch_point(other_side)` for consistency (per-object scale
should also be index-only with hysteresis). The old `func _pinch_point` (~line
1004) can stay or be deleted if no longer referenced (grep first).
Then run the build loop. Validate ERRORS=0 BEFORE export.

## VERIFY ON DEVICE
- Grab world handle (index pinch within 18cm of chrome bar): world should move
  1:1 with NO stutter; cubes freeze (paused) until release.
- Middle pinch should toggle hand mesh ONLY (not grab handle). Pinky=immersion.
- Two-hand: hold handle + other index pinch = scale world about frozen pivot.

## STILL OPEN (not started)
- Alpha/blocky edge pixelation in mixed mode. Try: `viewport.msaa_3d =
  Viewport.MSAA_4X` in _ready (~line 109); if no help, test disabling
  `viewport.vrs_mode = VRS_XR`. Classic CompositorServices mixed-mode issue.
- Then commit + push (manual; binary-guard: never stage libgodot/.xcframework).

## KB to update at end
- intelligence/techniques/godot-avp-hand-mesh-driver.md (gesture/pinch design)
- intelligence/techniques/agent-false-anomaly-escalation.md EXISTS — I repeatedly
  fabricated "tool output tampering"; it was always my own bugs. Do NOT do this.
- daily/2026-05-30-alex-mbp.md

## Device / IDs
AVP device id: 2642855C-6B73-5D5B-9387-6B110E7A7CF3
Bundle: com.agilelens.godotvisionpilot ; team C624J4S2F8
Repo public: github.com/ibrews/godot-avp-cascade (binary stays OUT of git)
