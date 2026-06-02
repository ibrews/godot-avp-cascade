# CLAUDE.md — godot-avp-cascade

You are working on an Apple Vision Pro Godot pilot. Read this before doing anything.

## Read the KB first

The bulk of project knowledge lives in the maintainer's private knowledge base, not in this repo. Before working, read these (paths are within that KB):

1. `intelligence/techniques/godot-visionos-xr.md` — engine build/deploy recipe, all the gotchas, the **`XROrigin3D.current=true` silent killer**, the alpha-0 background rule
2. `intelligence/techniques/godot-avp-falling-cascade.md` — this specific demo's patterns, perf numbers, gotchas (contact_monitor + body_entered)
3. `intelligence/research/godot-avp-demo-landscape.md` — public bar, ecosystem context
4. `context/team/team-marshall.md` — Marshall Nowak (aka Nocxr) is doing complementary in-house work on Clancey's hand-tracking fork

If you're confused about Godot on AVP, the KB has the answer. Do not improvise around the KB without first checking it.

## Critical constraints

- **Mobile renderer only.** Forward+ silently renders nothing. The recipe is `renderer/rendering_method="mobile"` in `project.godot`.
- **`XROrigin3D.current = true`** must be set on the XR origin in the scene. The most common silent failure: 90 FPS achieved, nothing renders.
- **AVP minimum near plane is 0.1.** `XRCamera3D.near=0.15` in this project for safety.
- **`WorldEnvironment` background_color alpha must be 0** (mixed-immersion CompositorServices halos otherwise).
- **`run/main_scene = "res://main_v2.tscn"`** — the cascade. `main.tscn` is the historical 14-box minimal scene; keep it as a fallback.
- Forward+ off. Vulkan/D3D12/OpenGL fallback off. All three are explicitly disabled in `project.godot`.

## Iteration loop (proven, ~3-4 min per round-trip)

```bash
# 1. Edit test-project/main_v2.gd or project.godot
# 2. Re-export PCK  (output path MUST be absolute — relative paths resolve from the project dir, not cwd)
~/godot-visionos-pilot/Godot.app/Contents/MacOS/Godot --headless \
  --path /Users/alex/godot-visionos-pilot/test-project \
  --export-pack "visionOS" \
  /Users/alex/godot-visionos-pilot/out/xcode-visionos/GodotVisionPilot.pck

# 3. xcodebuild
xcodebuild \
  -project out/xcode-visionos/GodotVisionPilot.xcodeproj \
  -scheme GodotVisionPilot \
  -configuration Debug \
  -destination "platform=visionOS,id=2642855C-6B73-5D5B-9387-6B110E7A7CF3" \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="C624J4S2F8" \
  build

# 4. Install (no remote launch — Alex opens app manually on AVP)
xcrun devicectl device install app \
  --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  $(ls -d ~/Library/Developer/Xcode/DerivedData/GodotVisionPilot-*/Build/Products/Debug-xros/GodotVisionPilot.app)

# 5. Alex puts on headset, taps icon, observes
# 6. Pull diagnostic frame count
xcrun devicectl device copy from \
  --device 2642855C-6B73-5D5B-9387-6B110E7A7CF3 \
  --source "Documents/xr_diag.txt" \
  --destination /tmp/xr_diag.txt \
  --domain-type appDataContainer \
  --domain-identifier com.agilelens.godotvisionpilot
```

`Documents/xr_diag.txt` per-5s frame delta should be **450** (= 90 FPS exactly). Anything less = perf wall hit; back off the most recent change.

## Capture (Dev Strap is attached as of 2026-05-27)

- High-fidelity: Xcode → Window → Devices and Simulators → select AVP → Take Screenshot / Record Screen. Native resolution, no AirPlay one-eye limit.
- CLI alternative: investigate `xcrun devicectl device capture` for headless recording.
- Fallback (no strap): AirPlay mirror → QuickTime "New Movie Recording" with AVP as camera source. One eye, ~30fps.

## Do NOT

- Rebuild the engine (`rsanchezsaez-godot/`) unless a specific upstream change requires it. 30-90 min on M1 Max. The current `libgodot.a` works.
- Switch to Forward+. It silently renders nothing.
- Try the visionOS simulator. CompositorServices `.layered` is hardware-only; Metal cube arrays absent in simulator GPU emulation. Hardware-only target.
- Connect `body_entered` BEFORE `add_child()` on a `RigidBody3D`. First frame's collisions get swallowed.
- Forget `contact_monitor=true` and `max_contacts_reported≥1` on new `RigidBody3D` instances — silent miss on signals.

## When you've done something interesting

- Write to `~/knowledge/intelligence/techniques/godot-avp-*.md` (one file per topic; keep small)
- Update `~/knowledge/intelligence/techniques/godot-visionos-xr.md` with new gotchas if discovered
- Append session to `~/knowledge/daily/YYYY-MM-DD-alex-mbp.md`
- Commit KB and push (`cd ~/knowledge && git pull --rebase && git push`)
- Commit this repo (no auto-sync — manual push to origin)
