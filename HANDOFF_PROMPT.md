# HANDOFF — Next session pickup brief

**Current state as of 2026-05-27:** Phase 2 complete. Falling Cascade physics demo confirmed working at 90 FPS locked on real AVP via the Apple-official rsanchezsaez `apple/visionos-xr` branch. First documented Godot RigidBody3D-in-immersive-on-AVP. Sample capture in `captures/cascade-2026-05-27.mp4`.

**Read this whole file before doing anything.** It's a self-contained pickup brief — you don't need the prior chat transcript.

## What's working right now

- Engine: rsanchezsaez `apple/visionos-xr` branch, built once at `Godot.app/Contents/MacOS/Godot`. Do not rebuild unless something specifically demands it (30–90 min on M1 Max).
- Project: `test-project/main_v2.tscn` is the Cascade. Runs at 90 FPS locked, 0 variance, ~475 collisions in 95s.
- Output: `out/xcode-visionos/GodotVisionPilot.xcodeproj` is the Xcode wrapper. `GodotVisionPilot.pck` is the exported game.
- Capture: Dev Strap is plugged in (Agile Alex M2 AVP, UDID `2642855C-6B73-5D5B-9387-6B110E7A7CF3`). Higher-fidelity capture available via Xcode UI than what was used for `captures/cascade-2026-05-27.mp4` (which was AVP screen recording → AirDrop, 1080p30).

## Read these FIRST

1. [`CLAUDE.md`](CLAUDE.md) — project-specific behavioral rules, build loop, do-nots
2. KB: [`intelligence/techniques/godot-visionos-xr.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-visionos-xr.md) — engine recipe + gotchas
3. KB: [`intelligence/techniques/godot-avp-falling-cascade.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/techniques/godot-avp-falling-cascade.md) — demo-specific notes
4. KB: [`intelligence/research/godot-avp-demo-landscape.md`](https://github.com/AgileLens/agile-lens-kb/blob/master/intelligence/research/godot-avp-demo-landscape.md) — public bar context

## Possible next phases (rough preference order; ask Alex which)

### Phase 3a: v2 polish — make the Cascade publishable

1. **Positional audio.** Move from `AudioStreamPlayer` (2D) to `AudioStreamPlayer3D`. Pool 4 reusable players, reposition per collision. Validate `XRCamera3D` is the listener on visionOS. Capture before+after audio comparison.
2. **Mixed-immersion passthrough.** Change `application/immersion_style` in `export_presets.cfg`. Cubes composite onto user's room. Watch for halo artifacts — alpha-0 background already set, but huisedenanhai's PR comments call out additional edge cases. Capture comparison.
3. **Particle trails.** `GPUParticles3D` child of each cube, short lifetime, follows trajectory. Mobile renderer supports GPUParticles3D but cap node count (~25 trails = ~25 emitters; verify perf).
4. **Cascade tiers.** Second plate below first at `y=−0.5`, rotated `+15°` X (catches what falls off plate 1). Coin-pusher feel. Maybe a third tier into a "drain."
5. **Music bed.** Second `AudioStreamGenerator` running a continuous sine + slow LFO. Chimes ride on top. Use Godot's audio bus system to mix.

### Phase 3b: hand-tracking integration (collaborate with Marshall)

Marshall (Nocxr) is on Clancey's `visionos_interactions_master_rebase` branch which has hands working. Sync with him on the gotchas there, then either:
- Port the Cascade to Clancey's branch and add hand-driven cube spawning ("pinch to release a cube")
- Wait for Apple's hand-tracking PR to land upstream (post-#109975 merge — could be weeks or months)

This is the highest-impact next step but requires Marshall's input on Clancey-branch state.

### Phase 3c: capture the canonical demo video using the dev strap

Re-capture at full fidelity (no AirPlay one-eye limit). Try Xcode → Devices and Simulators → Record Screen, or `xcrun devicectl device capture` (verify it works for immersive apps; PR #109975 body says capture is "not currently supported" but Apple keeps shipping new flags). Aim for 30-60s, both eyes if possible, ProRes if available. Replace `captures/cascade-2026-05-27.mp4` as the canonical version.

### Phase 3d: shareable build for the Godot AVP community

- Sign with a distribution profile (currently Debug + Apple Development)
- Bundle: a clean `Godot_visionOS_AVP_Cascade_v1.zip` containing the `.app` + setup instructions
- Post in the Godot AVP discord (Marshall has access)
- Consider crediting via a PR comment on rsanchezsaez#109975 — "Built a physics demo on your branch, here's perf data."

## v2 visual ideas (lower priority but captured)

- Randomize cube color hue across `0.05–0.15` (orange-yellow band) and size in `0.06–0.12 m`
- Add reactive `DirectionalLight3D` pulse per collision
- Replace `BoxMesh` with `CylinderMesh` for marbles instead of cubes — different aesthetic
- A subtle starfield via `GPUParticles3D` in the background (immersive black gets less stark)
- Try `viewport.use_hdr_2d = true` — the official `VisionOSXRInterface.xml` example sets this, but the canonical demo project doesn't. Untested whether it affects emissive brightness.

## Don't break what works

- `main.tscn` is the fallback minimal scene. Keep it. If you break `main_v2.tscn`, flip `run/main_scene` back and you have a verified-working baseline.
- The whole `[xr]` and `[rendering]` block in `project.godot` is load-bearing. Don't simplify it.
- `XROrigin3D.current = true` in main_v2.tscn — the single biggest silent killer in this stack.

## Critical contacts

- **Marshall Nowak** (Nocxr) — Agile Lens, doing Clancey-fork experiments with hand tracking. See [team-marshall.md](https://github.com/AgileLens/agile-lens-kb/blob/master/context/team/team-marshall.md). Slack `U04MR6H85K6`. Timezone: Arizona (no DST).
- **Alex Coulombe** — pilot owner. Will manually open the app on the headset for every test (no remote-launch). One device round-trip ≈ 3-4 min. Plan changes accordingly.

## State of the working tree

```
Pilot repo: /Users/alex/godot-visionos-pilot/ (git, branch main, public on GitHub)
KB: ~/knowledge/ (separate repo, sync via kb-sync.sh every 15 min)

Critical files:
  test-project/main_v2.tscn          # the Cascade
  test-project/main.tscn             # fallback minimal scene
  test-project/project.godot         # XR project settings
  test-project/export_presets.cfg    # visionOS export config
  out/xcode-visionos/                # Xcode wrapper (regenerable via export)
  Godot.app/                         # custom Godot binary (gitignored, regenerable)
  rsanchezsaez-godot/                # engine source (gitignored, regenerable)
  captures/                          # screen recordings + stills
  fill_template.py                   # automation for filling Apple Xcode template
```

## How to verify the demo still works

1. `cd /Users/alex/godot-visionos-pilot/`
2. Re-export PCK + xcodebuild + install (see CLAUDE.md)
3. Ask Alex to open app on AVP, observe for 30s, then take off
4. `xcrun devicectl device copy from --device 2642855C-... --source Documents/xr_diag.txt ...`
5. `cat /tmp/xr_diag.txt` — confirm per-5s frame delta is 450 (90 FPS)
6. If frame delta drops, investigate. Don't push further until baseline is restored.
