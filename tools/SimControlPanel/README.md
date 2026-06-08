# SimControlPanel

A small **macOS SwiftUI** control-panel app — a regular on-screen window with clickable
buttons, toggles, and sliders — that drives **simulator-only** dev settings of the Godot
"Cascade Countdown" visionOS app (`com.agilelens.godotvisionpilot`) while it runs in the
**visionOS Simulator**. It is pure dev tooling: every channel it speaks is sim-only by
construction, so it has **zero effect on a real Apple Vision Pro**.

It exists because the visionOS simulator gives a custom-Metal immersive Godot app no working
in-app keyboard and no ARKit hand anchors. This panel replaces the global key-tap
(`SimInputTap`) and the headless canned hand sender (`simhands_canned_sender`) with one window
you can click — and adds **live hand-placement calibration** you can dial in while watching the
sim.

## How it talks to the sim

Two output channels, both reusing existing, proven transports:

| Channel | Target | What it carries |
|---|---|---|
| **UDP `127.0.0.1:9999`** (loopback, no permission) | `test-project/simulator_input.gd` (sim-gated) | `N` immersion · `B` reset · `V` cycle hands · `C1`/`C0` grab down/up · **`K*` calibration** |
| **MultipeerConnectivity, service `"Bonjour"`** | `simhands_bridge.mm` (clancey fork, `GODOT_SIMHANDS=1`) | 21-landmark MediaPipe hand JSON @ 30 Hz, with panel-driven pinch |

### UDP protocol (extends the existing single-char protocol)

```
C1 / C0   grab down / up           N   toggle immersion / passthrough
B         reset sandbox            V   cycle hands (mesh / both / real)

K<key><float>   set a SimHands-bridge calibration value (persisted to user://simhands_calibration.cfg)
   KS<f>  hand_scale  (SIMHANDS_HAND_KNUCKLE_M, m — self-normalized hand size)
   KP<f>  plane       (SIMHANDS_PLANE_M, m — x/y travel across the image plane)
   KD<f>  depth       (SIMHANDS_DEPTH_M, m — wrist distance in front of the origin)
   KY<f>  y_offset    (SIMHANDS_Y_OFFSET_M, m — head-relative height, pre floor offset)
   KZ<f>  z_gain      (SIMHANDS_Z_SHAPE_GAIN — finger-curl depth from MediaPipe z)
KR        reset calibration to compiled defaults (deletes the cfg)
```

### Why calibration goes through the bridge (not the sender or GDScript)

The bridge **self-normalizes** hand size (`shape_scale = SIMHANDS_HAND_KNUCKLE_M / measured_span`),
so perturbing the normalized landmarks this app sends **cannot** change metric hand size — and
tuning in the bridge also calibrates the **real** VisionOS-SimHands webcam helper, not just our
canned feed. `apply_simhands_hand_states()` is the single chokepoint every joint flows through
(GDScript reads the tracker from 6+ scattered call sites), so calibration lives there. The panel
sends `K*` verbs on 9999 → `simulator_input.gd` writes `user://simhands_calibration.cfg` →
the bridge re-reads it ~9 Hz and applies it live. No per-tweak rebuild; calibration persists in
the sim container across relaunches.

## Quickstart

```sh
# 1. Build the panel (swiftc → ad-hoc-signed .app)
./tools/SimControlPanel/build.sh
open tools/SimControlPanel/SimControlPanel.app

# 2. Launch the Godot app in the booted sim WITH the hand bridge enabled
SIM=A540B3B5-CB1D-477D-A3B9-A6D41598B704
SIMCTL_CHILD_GODOT_SIMHANDS=1 xcrun simctl launch --terminate-running-process \
  "$SIM" com.agilelens.godotvisionpilot

# 3. In the panel: flip "Stream canned hand → bridge" ON, then tune the sliders.
```

> The `K*` calibration verbs only do anything when the app is launched with `GODOT_SIMHANDS=1`
> (the native bridge active). The `N/B/V/C` verbs work in any simulator run.
>
> If you also run `tools/simhands_canned_sender` (the CLI feed), stop it before using the panel's
> feed — otherwise both advertise `"Bonjour"` and the bridge gets two streams.

## Things to Try

1. **Move the immersive scene to passthrough.** Click **Scene ▸ Immersion** — the Godot scene
   toggles between mixed (passthrough) and full immersion (`N`).
2. **Reset the cascade.** Click **Scene ▸ Reset** to rebuild the sandbox (`B`), and **Hands** to
   cycle the hand visualization mode mesh → both → real (`V`).
3. **Drive a hand into the scene.** Flip **SimHands feed** ON; watch the panel's status dot go
   green ("connected: GodotVisionPilot"). Hold **Simulate pinch** to close the canned hand's
   index→thumb across the grab threshold.
4. **Lift the hands to eye level.** Drag **Y offset** up to ~`+1.5`. If the canned hand was
   sitting at the floor (STAGE play-area, no roomscale offset), this raises it to in front of
   your face. Drag **Depth** to push it nearer/farther.
5. **Resize the hand, then reset.** Drag **Hand scale** and watch the bridge's `thumb-index`
   distance change in the os_log; click **Reset** to drop back to first-light defaults.

To watch the bridge react:
```sh
xcrun simctl spawn "$SIM" log stream --level debug \
  --predicate 'subsystem == "com.agilelens.godotvisionpilot"' --style compact
# [SimHands] right tracked wrist=(0.00, 1.33, -0.80) thumb-index=0.087m pinch=0   ← after KY1.5 / KD0.8
```

## Files

- `SimControlPanel.swift` — the app (UDP sender + MC feed + SwiftUI window).
- `Info.plist` — bundle id `com.agilelens.simcontrolpanel`, Local Network + Bonjour keys for MC.
- `build.sh` — `swiftc -parse-as-library` → `.app` bundle → ad-hoc codesign.

Lineage: UDP send lifted from [`tools/SimInputTap.swift`](../SimInputTap.swift); MC feed lifted
from [`tools/simhands_canned_sender.swift`](../simhands_canned_sender.swift). Full background:
KB `intelligence/techniques/godot-avp-simulator-dev-tools.md`.
