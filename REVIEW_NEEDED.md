# REVIEW_NEEDED.md

## SimHands → XRHandTracker simulator bridge (Option A) — calibration handoff

**Status: FIRST LIGHT VERIFIED (2026-06-07).** The native MultipeerConnectivity bridge in the
**clancey** fork ingests VisionOS-SimHands MediaPipe hands and drives Godot's `XRHandTracker` in the
**visionOS Simulator**. Proven end-to-end with the canned MC sender (os_log evidence below). What
remains is **placement/scale calibration**, which needs a human watching the sim — do not guess at it
blind.

### What is proven (os_log, fresh launch PID 3298, 2026-06-07 20:00)
```
[SimHands] ENABLED via GODOT_SIMHANDS — simulator hand bridge active
[SimHands] client started: advertising + browsing service 'Bonjour'
[SimHands] found peer 'SimHandsCanned' — inviting
[SimHands] peer 'SimHandsCanned' → connected
[SimHands] right tracked wrist=(0.00, -0.27, -0.45) thumb-index=0.023m pinch=1
[SimHands] right tracked wrist=(0.00, -0.27, -0.45) thumb-index=0.087m pinch=0   (oscillates on the 4 s canned loop)
```
- MC discovery + connection works **sim↔host** (the big unknown — no local-network prompt blocked it
  in the sim, and the host CLI sender connected without an interactive Allow).
- `/user/hand_tracker/right` carries live, moving joints; `thumb-index` distance crosses the game's
  `PINCH_START=0.024 m` (deep-pinch frames read 0.013–0.019 m) and releases past `PINCH_END=0.052 m`
  (open frames ~0.085 m). So the game's index-pinch detector fires/releases in lockstep.

### How to reproduce (autonomous, no webcam)
```bash
# 0. Booted sim used here: Apple Vision Pro visionOS 26.5 — A540B3B5-CB1D-477D-A3B9-A6D41598B704
SIM=A540B3B5-CB1D-477D-A3B9-A6D41598B704
APP="$(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xrsimulator/GodotVisionPilot.app | head -1)"

# 1. (already built) sim engine slice + app. To rebuild the engine after editing the bridge:
cd ~/godot-visionos-pilot/clancey-godot && scons platform=visionos arch=arm64 simulator=yes target=template_debug   # ~10 s warm
cp bin/libgodot.visionos.template_debug.arm64.simulator.a \
   ../out/xcode-visionos/GodotVisionPilot.xcframework/xros-arm64-simulator/libgodot.a               # swap sim slice (device slice untouched)
# then re-export PCK (absolute path) + xcodebuild for the sim destination + simctl install.

# 2. canned sender (host) — one right hand, 4 s pinch/release loop:
~/godot-visionos-pilot/tools/simhands_canned_sender &     # build: swiftc -O tools/simhands_canned_sender.swift -o tools/simhands_canned_sender

# 3. stream the bridge's os_log (start before launch):
xcrun simctl spawn "$SIM" log stream --level debug \
  --predicate 'subsystem == "com.agilelens.godotvisionpilot"' --style compact &

# 4. launch with the bridge enabled (terminate-first = fresh env):
SIMCTL_CHILD_GODOT_SIMHANDS=1 xcrun simctl launch --terminate-running-process "$SIM" com.agilelens.godotvisionpilot
```
Gotchas learned: (a) **terminate the app before relaunch** or `simctl launch` re-attaches the old
instance WITHOUT the new env → no bridge (the failure we hit first). (b) The canned sender's stdout is
Swift-block-buffered to a pipe (looks empty); trust the **app-side** os_log for connection proof.
(c) `simctl io screenshot` captures only the 2D shared-space framebuffer (home/loading + passthrough),
**not** the immersive Godot render — use Xcode → Window → Devices and Simulators → screenshot for a
visual of the actual hands (GUI/human step).

### Calibration knobs (all at the top of `clancey-godot/modules/visionos_xr/simhands_bridge.mm`)
These got first light but are NOT tuned to feel right — needs a human in the sim:
- `SIMHANDS_HAND_KNUCKLE_M` (0.09) — self-normalized hand size. Raise/lower if the hand reads too
  big/small. Drives whether pinch distances land in the 0.024 m band (they currently do).
- `SIMHANDS_PLANE_M` (0.55) — how far hand x/y travels as you move in the camera frame.
- `SIMHANDS_DEPTH_M` (0.45) — wrist distance in front of the XR origin.
- `SIMHANDS_Y_OFFSET_M` (-0.10) — head-relative height. **NOTE the floor offset:** the engine adds
  `eye_height` (~1.7 m, roomscale) in `apply_floor_offset`, so the wrist lands ~`1.7 + (-0.10) = 1.6 m`
  world — i.e. eye level in front of the origin. If hands appear at the floor (sitting/`STAGE` play
  area, offset 0) bump this up ~+1.5; if too high, lower it.
- `SIMHANDS_Z_SHAPE_GAIN` (1.0) — how much MediaPipe's (noisy) z drives finger-curl depth.

### Open items (deferred — human-in-the-loop)
1. **Visible grab of a cube.** The canned hand is at a FIXED position; cubes cascade elsewhere, so no
   grab catches (engine log shows `held=none`, expected). To see an actual grab: either move the
   canned hand (extend the sender to pan the wrist x/y), position a cube at the hand, OR run the real
   SimHands webcam helper and reach for a cube. Tracker-level pinch is proven; visible grab is a
   placement exercise.
2. **Real SimHands helper + webcam.** Build/run github.com/BenLumenDigital/VisionOS-SimHands "macOS
   Helper" (allow Local Network + Camera). Same serviceType "Bonjour" → the bridge connects with no
   code change. Verify handedness (we replicate SimHands' L/R swap: displayName "Left"→Godot right).
3. **Two hands.** Bridge handles two (loop + same-side dedup) but only one was tested. Real helper or
   a two-hand canned sender will exercise `/user/hand_tracker/left` too.
4. **Joint orientation.** All joints use identity basis (first light). Pinch (position-only) is fine,
   but the mesh hands look flat. Derive per-joint basis from bone directions for a nicer mesh.
5. **Pinch feel / thresholds.** Tune so the natural pinch depth reliably crosses 0.024 m without
   accidental fires when the hand is just closed-ish.

### Device safety (no regression)
- The bridge is `#if TARGET_OS_SIMULATOR` + `GODOT_SIMHANDS` gated → **compile-time no-op on device**
  (3 empty stubs) and runtime-inert unless the env var is set.
- The deployed **device** engine slice (`GodotVisionPilot.xcframework/xros-arm64/libgodot.a`,
  May 31) was **NOT touched** — only the `xros-arm64-simulator` slice was swapped.
- A device build was deliberately NOT run (per the project rule against unnecessary 30–90 min engine
  rebuilds). If you do rebuild for device to double-check the stub path, it only relinks
  `clancey-godot/bin/...arm64.a`, not the deployed xcframework device slice.
- Backup of the pre-bridge sim slice: `/tmp/libgodot.sim.prebridge.backup.a` (restore by copying back
  over the xcframework's `xros-arm64-simulator/libgodot.a`).

### Files
- Engine (clancey `simhands-sim-bridge` branch): `modules/visionos_xr/simhands_bridge.mm` (new),
  `visionos_xr_interface.{h,mm}` (members + 3 call sites).
- App: `out/xcode-visionos/GodotVisionPilot/GodotVisionPilot-Info.plist`
  (`NSLocalNetworkUsageDescription` + `NSBonjourServices` `_Bonjour._tcp`/`_udp`).
- Test tool: `tools/simhands_canned_sender.swift`.
- KB: `~/knowledge/intelligence/techniques/godot-avp-simhands-sim-input.md` (Option A marked VERIFIED).

---

## (pre-existing) hand_visualizer.gd
`HandVisualizer3D` (`test-project/hand_visualizer.gd`) is an unwired orphan documented as an OPTIONAL
debug tool. Delete it if you don't want it kept.
