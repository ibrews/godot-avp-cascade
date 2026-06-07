# Engine patches

Local build patches for the **borrowed** Godot engine forks. These are *not* committed to the
forks and are **not** submitted upstream — the Godot project does not accept AI-assisted
contributions, so nothing here is PR'd to Godot or its forks. We keep the diffs in our own repo
so our changes are reproducible.

## `clancey-visionos-sim-rendering.patch`

Makes the **clancey-godot** fork build and render in the **visionOS Simulator** (XRSimulator
26.5+). The simulator is otherwise unusable for this engine; with this patch the full app renders
(single-eye, `.dedicated` layout, ~30–45% host CPU). Device builds are unaffected (those use the
**rsanchezsaez** fork, left pristine).

Three simulator-only fixes (all `#if TARGET_OS_SIMULATOR` / `#if !TARGET_OS_SIMULATOR`):

1. **MetalFX guards** — `MetalFX.framework` is absent from the sim SDK (device-only). Guards the
   import + `MTLFX*` use in `servers/rendering/renderer_rd/effects/metal_fx.mm` and
   `drivers/metal/metal_device_properties.mm` (the feature is gated off in the sim anyway).
2. **`presentDrawable:` guard** — `presentDrawable:afterMinimumDuration:` is unavailable on the
   sim's `MTLCommandBuffer`; use the plain selector (`drivers/metal/rendering_context_driver_metal.mm`).
3. **Apple4 GPU-family gate bypass** — `RenderingDeviceDriverMetal::initialize` hard-fails if
   `highestFamily < MTLGPUFamilyApple4`; the sim reports a sub-Apple4 family even though it's
   host-GPU-backed and renders fine, so the gate is skipped in the simulator
   (`drivers/metal/rendering_device_driver_metal.mm`). This was the real "rendering_device init
   failed" cause — not an SDK incompatibility.

Input is **not** in this patch: the in-app keyboard channel is dead in the sim, so interaction is
handled in our own GDScript via a localhost UDP bridge (`test-project/simulator_input.gd`) driven
by `tools/` senders. See KB `intelligence/techniques/godot-avp-simulator-input.md`.

### Apply + rebuild
```bash
# clancey-godot is a separate (git-ignored) clone; base commit when the patch was made:
#   0954ef50f469bde58fcddb9c0b1fa117eb097a13
cd clancey-godot
git checkout 0954ef50f469bde58fcddb9c0b1fa117eb097a13   # or your current clancey checkout
git apply ../engine-patches/clancey-visionos-sim-rendering.patch
scons platform=visionos arch=arm64 simulator=yes target=template_debug -j10
# then swap bin/libgodot.visionos.template_debug.arm64.simulator.a into
# out/xcode-visionos/GodotVisionPilot.xcframework/xros-arm64-simulator/libgodot.a and xcodebuild.
```
