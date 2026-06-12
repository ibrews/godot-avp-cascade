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
| **UDP `127.0.0.1:9999`** (loopback, no permission) | `test-project/simulator_input.gd` (sim-gated) | `N1`/`N0` set immersion · `B` full reset · `V` cycle hands · `C1`/`C0` grab latch · `G`/`GR` head-track · `H0`/`H1`/`H2` hand source · **`K*` calibration** |
| **MultipeerConnectivity, service `"Bonjour"`** | `simhands_bridge.mm` (clancey fork, `GODOT_SIMHANDS=1`) | 21-landmark MediaPipe hand JSON @ 30 Hz, with panel-driven pinch + selectable driven hand (L/R) |

### UDP protocol (extends the existing single-char protocol)

```
C1 / C0   grab latch down / up     N         toggle immersion (legacy)
B         full scene reset         N1 / N0   set immersion immersive / mixed
V         cycle hands              H0/H1/H2  hand source off / canned / webcam
G<x>,<y>,<z>  fake head position   GR        head-track recenter / disengage

K<key><float>   set a SimHands-bridge calibration value (persisted to user://simhands_calibration.cfg)
   KS<f>  hand_scale  (SIMHANDS_HAND_KNUCKLE_M, m — self-normalized hand size; also scales travel)
   KP<f>  plane       (SIMHANDS_PLANE_M, m — x/y travel across the image plane)
   KD<f>  depth       (SIMHANDS_DEPTH_M, m — wrist distance in front of the origin)
   KY<f>  y_offset    (SIMHANDS_Y_OFFSET_M, m — head-relative height, pre floor offset)
   KZ<f>  z_gain      (SIMHANDS_Z_SHAPE_GAIN — finger-curl depth from MediaPipe z)
   KM<f>  smoothing   (SIMHANDS_SMOOTHING — 0 raw · 1 heavy · up to 3 glassy/promo)
KR        reset calibration to compiled defaults (deletes the cfg)
```
`N1`/`N0` set immersion explicitly so the panel stays authoritative and can label the state
Immersive/Mixed. `G`/`GR` drive a **prototype** head-tracking path: a fake head position (panel
pad, later webcam face detection) moves the `XROrigin` so the viewpoint travels with the head — its
travel scales with `KS` (hand scale), same as the hands. `H0/H1/H2` pick which `"Bonjour"` feed the
bridge lets drive, so the panel, the canned sender, and the real webcam helper can all stay
connected while only one drives.

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

# 3. In the panel: set Hand source ▸ Canned, then tune the sliders.
```

> The `K*` calibration verbs only do anything when the app is launched with `GODOT_SIMHANDS=1`
> (the native bridge active). The `N/B/V/C` verbs work in any simulator run.
>
> Use the **Hand source** picker (Off / Canned / Webcam) to choose which `"Bonjour"` feed drives:
> Canned streams this panel's hand; Webcam/Off stop it so the real VisionOS-SimHands helper takes
> over. Every feed can stay connected at once — only the selected source drives.

## Things to Try

1. **Flip immersion and read the state.** Use **Scene ▸ Mixed / Immersive** — the segmented
   control both sets the Godot scene (`N1`/`N0`) and shows which mode is active. **Reset** does a
   full cascade reset (clears cubes, recenters, restarts the round); **Hands** cycles the hand
   visualization mesh → both → real.
2. **Latch a grab and drive away.** Click **Grab** once to hold (it stays latched — the button
   reads "Holding"); if you reached an object at the view centre it rides the head while you
   WASD-drive the sim. Click **Grab** again to release.
3. **Drive a canned hand + pinch it.** Set **Hand source ▸ Canned** (status dot goes green), pick
   which hand it **Drives** (Left / Right), then tap **Pinch** for a single pinch+release or check
   **Loop** to cycle continuously across the grab threshold.
4. **Dial in placement, scale, and travel.** Drag **Y offset** up to ~`+1.5` to lift the hand to
   eye level and **Depth** to push it nearer/farther. Drag **Hand scale** up — the hand grows AND
   travels farther for the same motion (2× scale ≈ 2× travel). Push **Smoothing** toward `3` for a
   glassy, slow glide (promo capture); **Reset** drops calibration back to first-light defaults.
5. **Prototype head-tracking.** Enable **Head tracking**, drag the pad to "move your head" and the
   **Forward / back** slider to lean — the viewpoint (`XROrigin`) travels with it, scaled by Hand
   scale. **Recenter** snaps back. (This is the fake-signal prototype; webcam face detection feeds
   the same path later.)

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
