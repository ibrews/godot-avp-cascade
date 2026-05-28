#!/usr/bin/env python3
"""
fill_template.py — Manually perform Godot export-plugin variable substitution
on the extracted godot_visionos.zip bundle in out/xcode-visionos/.

Run from the repo root:
    python3 fill_template.py
"""

import os
import re
import shutil

BASE = os.path.join(os.path.dirname(__file__), "out", "xcode-visionos")

BINARY = "GodotVisionPilot"
BUNDLE_ID = "com.agilelens.godotvisionpilot"
TEAM_ID = "C624J4S2F8"

# ── Variable substitution map ────────────────────────────────────────────────
# ORDER MATTERS: longer / compound keys before their prefix.

SUBS = [
    # compound $binary.* variants — must precede bare $binary
    ("$binary.xcframework",             f"{BINARY}.xcframework"),
    ("$binary.xcodeproj",               f"{BINARY}.xcodeproj"),
    ("$binary.entitlements",            f"{BINARY}.entitlements"),
    ("$binary.pck",                     f"{BINARY}.pck"),
    ("$binary.app",                     f"{BINARY}.app"),
    ("$binary-Info.plist",              f"{BINARY}-Info.plist"),
    # bare $binary
    ("$binary",                         BINARY),
    # product name
    ("$name",                           BINARY),
    # project identifiers
    ("$bundle_identifier",              BUNDLE_ID),
    ("$team_id",                        TEAM_ID),
    # architectures / SDK
    ("$godot_archs",                    "arm64"),
    ("$valid_archs",                    "arm64"),
    ("$sdkroot",                        "xrsimulator"),
    ("$os_deployment_target",           "XROS_DEPLOYMENT_TARGET = 2.0;"),
    ("$targeted_device_family",         "7"),
    # code signing
    ("$code_sign_style_debug",          "Automatic"),
    ("$code_sign_style_release",        "Automatic"),
    ("$code_sign_identity_debug",       "iPhone Developer"),
    ("$code_sign_identity_release",     ""),
    ("$provisioning_profile_uuid_debug",    ""),
    ("$provisioning_profile_uuid_release",  ""),
    ("$provisioning_profile_specifier_debug",   ""),
    ("$provisioning_profile_specifier_release",  ""),
    ("$provisioning_profile_uuid",      ""),
    # versioning
    ("$short_version",                  "1.0"),
    ("$version",                        "1"),
    # build config
    ("$default_build_config",           "Debug"),
    # export options
    ("$export_method",                  "development"),
    # Info.plist — privacy / capabilities
    ("$signature",                      ""),
    ("$docs_in_place",                  "<false/>"),
    ("$docs_sharing",                   "<false/>"),
    ("$camera_usage_description",       ""),
    ("$microphone_usage_description",   ""),
    ("$photolibrary_usage_description", ""),
    # empty capabilities / orientations (visionOS doesn't use them)
    ("$required_device_capabilities",   ""),
    ("$interface_orientations",         ""),
    ("$ipad_interface_orientations",    ""),
    # Info.plist extra content
    ("$additional_plist_content",       ""),
    ("$plist_launch_screen_name",       ""),
    # Info.plist scene manifest — Immersive (app_role=1), Mixed (immersion_style=1)
    ("$application_scene_manifest_default_session_role",
        "<key>UIApplicationPreferredDefaultSceneSessionRole</key>\n"
        "\t\t\t<string>CPSceneSessionRoleImmersiveSpaceApplication</string>"),
    ("$application_scene_manifest_immersive_configuration",
        "<key>UISceneSessionRoleImmersiveSpaceApplication</key>\n"
        "\t\t\t\t<array>\n"
        "\t\t\t\t\t<dict>\n"
        "\t\t\t\t\t\t<key>UISceneInitialImmersionStyle</key>\n"
        "\t\t\t\t\t\t<string>UIImmersionStyleMixed</string>\n"
        "\t\t\t\t\t</dict>\n"
        "\t\t\t\t</array>"),
    # entitlements
    ("$entitlements_full",              ""),
    # PBX multi-line empty blocks
    ("$modules_buildfile",              ""),
    ("$modules_fileref",                ""),
    ("$modules_buildgrp",               ""),
    ("$modules_buildphase",             ""),
    ("$moltenvk_buildfile",             ""),
    ("$moltenvk_fileref",               ""),
    ("$moltenvk_buildgrp",              ""),
    ("$moltenvk_buildphase",            ""),
    ("$pbx_launch_screen_build_reference", ""),
    ("$pbx_launch_screen_file_reference",  ""),
    ("$pbx_launch_screen_build_phase",     ""),
    ("$pbx_launch_screen_copy_files",      ""),
    ("$pbx_locale_file_reference",         ""),
    ("$pbx_locale_build_reference",        ""),
    ("$additional_pbx_files",              ""),
    ("$additional_pbx_resources_refs",     ""),
    ("$additional_pbx_resources_build",    ""),
    ("$additional_pbx_frameworks_build",   ""),
    ("$additional_pbx_frameworks_refs",    ""),
    ("$pbx_embeded_frameworks",            ""),
    # linker
    ("$linker_flags",                   ""),
    # C++ plugin bridge (empty when no plugins)
    ("$cpp_code",                       "// No C++ plugin bridge code needed"),
]


def substitute(text: str) -> str:
    for src, dst in SUBS:
        text = text.replace(src, dst)
    # warn about any remaining $-variables (excluding Xcode $ vars like $(inherited))
    remaining = re.findall(r'\$(?![({(])[a-z_]+', text)
    if remaining:
        print(f"  ⚠  Unresolved variables: {set(remaining)}")
    return text


def process_file(path: str) -> None:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    new_content = substitute(content)
    if new_content != content:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
        print(f"  ✓ substituted: {os.path.relpath(path, BASE)}")


# ── Files to process ─────────────────────────────────────────────────────────

FILES_TO_PROCESS = [
    "godot_apple_embedded.xcodeproj/project.pbxproj",
    "godot_apple_embedded.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
    "godot_apple_embedded.xcodeproj/xcshareddata/xcschemes/godot_apple_embedded.xcscheme",
    "godot_apple_embedded/godot_apple_embedded-Info.plist",
    "godot_apple_embedded/godot_apple_embedded.entitlements",
    "godot_apple_embedded/export_options.plist",
    "godot_apple_embedded/dummy.cpp",
]


def main():
    print(f"Base: {BASE}")
    if not os.path.isdir(BASE):
        raise SystemExit(f"ERROR: directory not found: {BASE}")

    # 1. Substitute variables in files (before renaming so paths still resolve)
    print("\n── Step 1: Variable substitution ──")
    for rel in FILES_TO_PROCESS:
        full = os.path.join(BASE, rel)
        if os.path.isfile(full):
            process_file(full)
        else:
            print(f"  ⚠  not found (skip): {rel}")

    # 2. Rename individual files inside the old-named directories
    print("\n── Step 2: Rename files ──")
    renames = [
        ("godot_apple_embedded/godot_apple_embedded-Info.plist",
         "godot_apple_embedded/GodotVisionPilot-Info.plist"),
        ("godot_apple_embedded/godot_apple_embedded.entitlements",
         "godot_apple_embedded/GodotVisionPilot.entitlements"),
        ("godot_apple_embedded.xcodeproj/xcshareddata/xcschemes/godot_apple_embedded.xcscheme",
         "godot_apple_embedded.xcodeproj/xcshareddata/xcschemes/GodotVisionPilot.xcscheme"),
        ("data.pck",
         "GodotVisionPilot.pck"),
    ]
    for src_rel, dst_rel in renames:
        src = os.path.join(BASE, src_rel)
        dst = os.path.join(BASE, dst_rel)
        if os.path.isfile(src):
            os.rename(src, dst)
            print(f"  ✓ {src_rel}  →  {dst_rel}")
        else:
            print(f"  ⚠  not found (skip rename): {src_rel}")

    # 3. Rename the xcframework (static lib → GodotVisionPilot.xcframework)
    print("\n── Step 3: Rename xcframework ──")
    xcfw_src = os.path.join(BASE, "libgodot.visionos.debug.xcframework")
    xcfw_dst = os.path.join(BASE, f"{BINARY}.xcframework")
    if os.path.isdir(xcfw_src):
        if os.path.exists(xcfw_dst):
            shutil.rmtree(xcfw_dst)
        os.rename(xcfw_src, xcfw_dst)
        print(f"  ✓ libgodot.visionos.debug.xcframework  →  {BINARY}.xcframework")
    else:
        print(f"  ⚠  xcframework src not found (skip)")

    # 4. Rename godot_apple_embedded/ → GodotVisionPilot/
    print("\n── Step 4: Rename source directory ──")
    app_src = os.path.join(BASE, "godot_apple_embedded")
    app_dst = os.path.join(BASE, BINARY)
    if os.path.isdir(app_src):
        if os.path.exists(app_dst):
            shutil.rmtree(app_dst)
        os.rename(app_src, app_dst)
        print(f"  ✓ godot_apple_embedded/  →  {BINARY}/")
    else:
        print(f"  ⚠  source dir not found (skip)")

    # 5. Rename godot_apple_embedded.xcodeproj → GodotVisionPilot.xcodeproj
    print("\n── Step 5: Rename xcodeproj directory ──")
    xcproj_src = os.path.join(BASE, "godot_apple_embedded.xcodeproj")
    xcproj_dst = os.path.join(BASE, f"{BINARY}.xcodeproj")
    if os.path.isdir(xcproj_src):
        if os.path.exists(xcproj_dst):
            shutil.rmtree(xcproj_dst)
        os.rename(xcproj_src, xcproj_dst)
        print(f"  ✓ godot_apple_embedded.xcodeproj/  →  {BINARY}.xcodeproj/")
    else:
        print(f"  ⚠  xcodeproj dir not found (skip — may already be renamed)")

    # 6. Final structure report
    print("\n── Final structure ──")
    for entry in sorted(os.listdir(BASE)):
        print(f"  {entry}/") if os.path.isdir(os.path.join(BASE, entry)) else print(f"  {entry}")

    print(f"\n✅  Done. Build with:")
    print(f"xcodebuild \\")
    print(f"  -project {BASE}/{BINARY}.xcodeproj \\")
    print(f"  -scheme {BINARY} \\")
    print(f"  -configuration Debug \\")
    print(f'  -destination "platform=visionOS Simulator,name=Apple Vision Pro" \\')
    print(f"  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO")


if __name__ == "__main__":
    main()
