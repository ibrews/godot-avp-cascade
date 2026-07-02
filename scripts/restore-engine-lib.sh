#!/usr/bin/env bash
# restore-engine-lib.sh
#
# Restores the Clancey hand-tracking engine lib into the xcframework after a
# fresh clone (or any --export that regenerated the xcframework with the
# render-only rsanchezsaez engine).
#
# WHY THIS EXISTS
#   Hand tracking ONLY works with Clancey's visionos_master_pr build of libgodot.a
#   (the Clancey fork, NOT rsanchezsaez's render-only branch). Marshall Nowak packaged
#   and relayed that prebuilt binary to us — he did not author it. It is 181MB and
#   borrowed (licensing unclear), so it is intentionally NOT committed to this PUBLIC
#   repo. A fresh clone builds fine but reverts to the render-only engine and silently
#   loses hand tracking (cubes render, nothing grabbable, no permission prompt).
#   Because it is just Clancey's build, a from-source build of Clancey visionos_master_pr
#   reproduces an equivalent hand-tracking lib.
#
#   This script copies the known-good lib from the local durable archive into
#   the xcframework. Run it once after cloning, and after any full --export.
#
# CANONICAL LIB
#   sha256: 179446a8434682f197aab1c709e832d1c6ba3b5c7374b36353861613052901fc
#   This is the build that was verified working on device 2026-05-30 (the one
#   that drives the white skinned hand mesh + grab/throw).

set -euo pipefail

ARCHIVE_DIR="${GODOT_ENGINE_ARCHIVE:-$HOME/godot-engine-bin-archive/clancey-handtracking-4.6.2}"
ARCHIVE_LIB="$ARCHIVE_DIR/libgodot.a.xros-arm64.WORKING-179446a8"
EXPECTED_SHA="179446a8434682f197aab1c709e832d1c6ba3b5c7374b36353861613052901fc"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK="$REPO_ROOT/out/xcode-visionos/GodotVisionPilot.xcframework"
DEVICE_SLICE="$XCFRAMEWORK/xros-arm64/libgodot.a"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$ARCHIVE_LIB" ] || fail "archived lib not found: $ARCHIVE_LIB
  Set GODOT_ENGINE_ARCHIVE or restore the archive from offsite/NAS backup.
  Ask Marshall Nowak (Slack U04MR6H85K6) if the archive is lost entirely."

ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE_LIB" | awk '{print $1}')"
[ "$ARCHIVE_SHA" = "$EXPECTED_SHA" ] || fail "archive sha mismatch
  expected $EXPECTED_SHA
  got      $ARCHIVE_SHA"

[ -d "$XCFRAMEWORK/xros-arm64" ] || fail "xcframework device slice dir missing: $XCFRAMEWORK/xros-arm64
  Did you run the Xcode/export build at least once?"

# Back up whatever is currently there (likely the render-only rsanchezsaez lib).
if [ -f "$DEVICE_SLICE" ]; then
  CURRENT_SHA="$(shasum -a 256 "$DEVICE_SLICE" | awk '{print $1}')"
  if [ "$CURRENT_SHA" = "$EXPECTED_SHA" ]; then
    echo "Device slice already the canonical hand-tracking lib ($EXPECTED_SHA). Nothing to do."
    exit 0
  fi
  cp "$DEVICE_SLICE" "$DEVICE_SLICE.replaced-$CURRENT_SHA.bak"
  echo "Backed up existing device lib → $DEVICE_SLICE.replaced-$CURRENT_SHA.bak"
fi

cp "$ARCHIVE_LIB" "$DEVICE_SLICE"
RESULT_SHA="$(shasum -a 256 "$DEVICE_SLICE" | awk '{print $1}')"
[ "$RESULT_SHA" = "$EXPECTED_SHA" ] || fail "post-copy sha mismatch ($RESULT_SHA) — copy failed"

echo "Restored Clancey hand-tracking lib → $DEVICE_SLICE"
echo "sha256 $RESULT_SHA  ✓"
echo
echo "Next: rebuild in Xcode and reinstall. Hand tracking should be back."
