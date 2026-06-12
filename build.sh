#!/usr/bin/env bash
#
# build.sh — one-command Godot visionOS build/run switcher: SIMULATOR or DEVICE.
#
#   ./build.sh sim       re-export the PCK → build for the visionOS Simulator → install + launch
#   ./build.sh device    re-export the PCK → build SIGNED for a real Apple Vision Pro → install
#   ./build.sh export    just re-export the Godot PCK (no Xcode build)
#   ./build.sh help      show this help
#
# WHY: the sim and device builds differ in three annoying ways — the xcodebuild -destination,
# code-signing, and the install tool (simctl vs devicectl). This wraps both so you never
# hand-type (or mis-type) the incantation again. Switching is just the first argument.
#
# REUSE ACROSS GODOT visionOS PROJECTS: every project-specific value lives in the CONFIG block
# below. Override any of them with an env var, or with a sibling `build.config` (KEY=VALUE lines).
# To reuse: copy this script into another Godot visionOS project and adjust the config.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# --------------------------------- CONFIG ---------------------------------
[ -f ./build.config ] && source ./build.config            # optional per-project overrides
GODOT="${GODOT:-$HOME/godot-visionos-pilot/Godot.app/Contents/MacOS/Godot}"
PROJECT_DIR="${PROJECT_DIR:-$PWD/test-project}"            # Godot project dir (has project.godot)
EXPORT_PRESET="${EXPORT_PRESET:-visionOS}"                 # name="..." in export_presets.cfg
XCODE_DIR="${XCODE_DIR:-$PWD/out/xcode-visionos}"          # exported Xcode project dir
PCK_OUT="${PCK_OUT:-$XCODE_DIR/GodotVisionPilot.pck}"      # PCK output (absolute!)
XCODEPROJ="${XCODEPROJ:-$XCODE_DIR/GodotVisionPilot.xcodeproj}"
SCHEME="${SCHEME:-GodotVisionPilot}"
BUNDLE_ID="${BUNDLE_ID:-com.agilelens.godotvisionpilot}"
SIM_UDID="${SIM_UDID:-A540B3B5-CB1D-477D-A3B9-A6D41598B704}"    # xcrun simctl list devices
DEVICE_ID="${DEVICE_ID:-2642855C-6B73-5D5B-9387-6B110E7A7CF3}"  # xcrun devicectl list devices
DEV_TEAM="${DEV_TEAM:-C624J4S2F8}"                        # signing team (device builds)
# Engine slices live in the xcframework (xros-arm64 = device, xros-arm64-simulator = sim);
# xcodebuild auto-selects per -destination, so no per-build slice swap is needed. (This project's
# device hand-tracking needs the Clancey lib restored ONCE via scripts/restore-engine-lib.sh after
# a fresh clone / full export — a PCK-only export like below does NOT disturb the xcframework.)
# --------------------------------------------------------------------------

c() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }

export_pck() {
  c "Export PCK ($EXPORT_PRESET) → $PCK_OUT"
  "$GODOT" --headless --path "$PROJECT_DIR" --export-pack "$EXPORT_PRESET" "$PCK_OUT"
}

find_app() {  # $1 = Debug-xrsimulator | Debug-xros
  ls -dt "$HOME/Library/Developer/Xcode/DerivedData/${SCHEME}-"*"/Build/Products/$1/${SCHEME}.app" 2>/dev/null | head -1
}

build_sim() {
  export_pck
  c "xcodebuild → visionOS Simulator ($SIM_UDID)"
  xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" -configuration Debug \
    -destination "platform=visionOS Simulator,id=$SIM_UDID" \
    CODE_SIGNING_ALLOWED=NO build
  local app; app="$(find_app Debug-xrsimulator)"; [ -n "$app" ] || { echo "ERROR: .app not found"; exit 1; }
  c "Boot sim + install + launch: $app"
  xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
  open -a Simulator
  xcrun simctl install "$SIM_UDID" "$app"
  xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
  c "Running in the Simulator. Keep it FRONTMOST — immersive apps suspend when backgrounded."
}

build_device() {
  export_pck
  c "xcodebuild → Apple Vision Pro device ($DEVICE_ID), team $DEV_TEAM"
  xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" -configuration Debug \
    -destination "platform=visionOS,id=$DEVICE_ID" \
    CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$DEV_TEAM" build
  local app; app="$(find_app Debug-xros)"; [ -n "$app" ] || { echo "ERROR: .app not found"; exit 1; }
  c "Install on device: $app"
  xcrun devicectl device install app --device "$DEVICE_ID" "$app"
  c "Installed. Open the app on the headset by hand (visionOS has no remote launch)."
}

case "${1:-help}" in
  sim)     build_sim ;;
  device)  build_device ;;
  export)  export_pck ;;
  *)       sed -n '3,17p' "$0" | sed 's/^#\s\{0,1\}//' ;;
esac
