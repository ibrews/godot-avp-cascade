# HANDOFF — Next session pickup brief

**Current state as of 2026-05-27:** Phase 3a in progress. v3 build deployed to AVP. New features: positional 3D audio (4-player pool), GPUParticles3D trails per cube, second catch plate (tier 2). Awaiting perf verification on device.

**Read this whole file before doing anything.** It's a self-contained pickup brief — you don't need the prior chat transcript.

## What's working right now

- Engine: rsanchezsaez `apple/visionos-xr` branch, built once at `Godot.app/Contents/MacOS/Godot`. Do not rebuild unless something specifically demands it (30–90 min on M1 Max).
- Project script: **`test-project/main_v2.gd`** (external file, was formerly embedded in .tscn). `test-project/main_v2.tscn` now references it via `ExtResource`.
- Output: `out/xcode-visionos/GodotVisionPilot.xcodeproj` is the Xcode wrapper. `GodotVisionPilot.pck` is the exported game.
- Capture: Dev Strap plugged in (Agile Alex M2 AVP, UDID `2642855C-6B73-5D5B-9387-6B110E7A7CF3`). Xcode Devices & Simulators shows "Take Screenshot" but no "Record Screen" for AVP in Xcode 26. Capture via `xcrun devicectl` does not have a capture subcommand. Best current option: AirPlay → QuickTime or Xcode screenshot button (stills only via dev strap).
- README: now has a looping GIF (`captures/cascade.gif`, 720×405 7s at 15fps). Dead `frame_2s.jpg` link replaced.

## What changed in this session (v3)

1. **Script externalised** — `main_v2.gd` is now a standalone file. Easier to edit; no more escaping newlines inside .tscn. .tscn uses `ExtResource("Script_1")`.
2. **Positional audio** — replaced single `AudioStreamPlayer` with a pool of 4 `AudioStreamPlayer3D` nodes (round-robin). Each is repositioned to `cube.global_position` on collision. Chime frequency still randomised (440±220 Hz). `XRCamera3D` auto-acts as audio listener in visionOS — no extra `AudioListener3D` node needed.
3. **Particle trails** — `GPUParticles3D` (8 particles, 0.3s lifetime) added as child of each `RigidBody3D` cube. Shared `_particle_material` (ParticleProcessMaterial) and `_particle_mesh` (QuadMesh, 18×18mm, emissive orange). 25 cubes × 8 particles = 200 particles max — should be within mobile renderer budget.
4. **Tier 2 catch plate** — second `StaticBody3D` plate at y=−0.05, z=FORWARD_Z−0.35, rotated +15° X. `_build_plate()` helper DRYs the two plate definitions.
5. **Build pipeline fix** — PCK export output path must be **absolute**. Relative paths are resolved from the project directory (not cwd), causing silent write failures. CLAUDE.md updated.

## ⚠️ Verify before proceeding

The v3 build is on the device but perf has not been confirmed. Before adding more features:

```bash
xcrun devicectl device copy from \
  --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  --source "Documents/xr_diag.txt" \
  --destination /tmp/xr_diag.txt \
  --domain-type appDataContainer \
  --domain-identifier com.agilelens.godotvisionpilot
cat /tmp/xr_diag.txt
```

Per-5s frame delta must still be **450** (= 90 FPS). Particles + 3D audio are the new cost centres — if delta drops, cull particles first (reduce `amount` from 8 → 4, or raise `lifetime` threshold before emitting).

## Read these FIRST

1. [`CLAUDE.md`](CLAUDE.md) — project-specific behavioral rules, build loop, do-nots
2. KB: [`intelligence/techniques/godot-visionos-xr.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-visionos-xr.md) — engine recipe + gotchas
3. KB: [`intelligence/techniques/godot-avp-falling-cascade.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-avp-falling-cascade.md) — demo-specific notes
4. KB: [`intelligence/research/godot-avp-demo-landscape.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/research/godot-avp-demo-landscape.md) — public bar context

## Remaining Phase 3a items

1. **Music bed** — second `AudioStreamGenerator` with continuous sine + slow LFO. Chimes ride on top.
2. **Mixed-immersion passthrough** — change `application/immersion_style` in `export_presets.cfg`. Watch for halo artifacts (alpha-0 background already set).
3. **PR comment on rsanchezsaez#109975** — draft ready (see last chat), pending Alex's approval to post.

## Phase 3b: hand-tracking (blocked on Marshall)

Marshall (Nocxr) is on Clancey's `visionos_interactions_master_rebase` branch. Waiting for his input on branch state. Options: port Cascade to Clancey's branch + add pinch-to-spawn, or wait for upstream hand-tracking PR.

## Phase 3c: canonical video capture

Xcode 26 "Record Screen" not present for AVP in Devices & Simulators (only "Take Screenshot"). `xcrun devicectl` has no capture subcommand. Best current options:
- AirPlay mirror → QuickTime "New Movie Recording" with AVP as source (one eye, ~30fps)
- Wait for Apple to add a CLI capture path in a future Xcode release

## Phase 3d: community distribution

- Sign with distribution profile
- Bundle `.app` + setup instructions as `Godot_visionOS_AVP_Cascade_v1.zip`
- Post in Godot AVP Discord (Marshall has access)

## Visual ideas queue

- Randomize cube color hue (orange-yellow band) and size (0.06–0.12 m)
- Reactive `DirectionalLight3D` pulse per collision
- Replace `BoxMesh` with `CylinderMesh` for marble aesthetic
- Starfield `GPUParticles3D` in background
- `viewport.use_hdr_2d = true` — untested on this path

## Critical contacts

- **Marshall Nowak** (Nocxr) — Agile Lens, Clancey-fork hand tracking. Slack `U04MR6H85K6`. Timezone: Arizona (no DST).
- **Alex Coulombe** — pilot owner. Opens app manually on AVP for every test. One round-trip ≈ 3-4 min.

## Don't break what works

- `main.tscn` is the fallback minimal scene. Keep it. Flip `run/main_scene` back if main_v2 breaks.
- The `[xr]` and `[rendering]` block in `project.godot` is load-bearing. Don't simplify it.
- `XROrigin3D.current = true` in main_v2.tscn — the single biggest silent killer in this stack.
- Connect `body_entered` AFTER `add_child()` on RigidBody3D — otherwise first-frame collisions are swallowed.

## State of the working tree

```
Pilot repo: /Users/alex/godot-visionos-pilot/ (git, branch main, public on GitHub)
KB: ~/knowledge/ (separate repo)

Critical files:
  test-project/main_v2.gd            # Cascade script (external, replaces embedded in .tscn)
  test-project/main_v2.tscn          # scene (references main_v2.gd via ExtResource)
  test-project/main.tscn             # fallback minimal scene
  test-project/project.godot         # XR project settings
  test-project/export_presets.cfg    # visionOS export config
  out/xcode-visionos/                # Xcode wrapper (regenerable via export)
  Godot.app/                         # custom Godot binary (gitignored, regenerable)
  rsanchezsaez-godot/                # engine source (gitignored, regenerable)
  captures/                          # stills + recordings (cascade.gif is the README hero)
  fill_template.py                   # automation for filling Apple Xcode template
```
