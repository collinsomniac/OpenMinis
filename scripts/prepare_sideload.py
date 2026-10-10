#!/usr/bin/env python3
"""Prepare the OpenMinis Xcode project for a free-Apple-ID sideload build.

Run in CI before xcodebuild. Leaves the repository's real project untouched in git history, so
upstream merges stay clean. What it does:

  1. Main app only: removes the three embedded extensions (Share, File Provider, Widget) and their
     target dependencies. A free team gets ~10 App IDs per week; each extension needs its own.
  2. Bundle id: com.openminis.app -> io.github.collinsomniac.openminis, so the build installs
     alongside the App Store Minis instead of replacing it.
  3. Entitlements: keeps only what a free team can sign (application-groups is dropped too: it needs
     a registered group) and ADDS increased-memory-limit, which on-device inference needs
     (~6 GB usable instead of ~3.25 GB).

Usage: python3 prepare_sideload.py [path/to/src/ios]
"""
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "src/ios")
PBX = ROOT / "Minis.xcodeproj" / "project.pbxproj"
ENT = ROOT / "Minis.entitlements"
NEW_BUNDLE = "io.github.collinsomniac.openminis"

text = PBX.read_text()
before = len(text)

# --- 1. drop embedded extensions --------------------------------------------------------------
# build-file lines that embed the .appex products
for appex in ("MinisShare.appex", "MinisFileProvider.appex", "AgentWidgetExtension.appex"):
    # references inside the "Embed Foundation Extensions" phase's file list
    text = re.sub(rf"^\s*\w+ /\* {re.escape(appex)} in Embed Foundation Extensions \*/,\n", "", text, flags=re.M)

# target dependencies of the main app on the extension targets
for dep in ("E5E000080", "E5H000080", "E5FP00080"):
    text = re.sub(rf"^\s*{dep} /\* PBXTargetDependency \*/,\n", "", text, flags=re.M)

# --- 2. bundle id ------------------------------------------------------------------------------
n_bundle = text.count("PRODUCT_BUNDLE_IDENTIFIER = com.openminis.app;")
text = text.replace("PRODUCT_BUNDLE_IDENTIFIER = com.openminis.app;",
                    f"PRODUCT_BUNDLE_IDENTIFIER = {NEW_BUNDLE};")

PBX.write_text(text)
print(f"project: {before} -> {len(text)} bytes; bundle id replaced {n_bundle}x")
for appex in ("MinisShare.appex", "MinisFileProvider.appex", "AgentWidgetExtension.appex"):
    still = len(re.findall(rf"{re.escape(appex)} in Embed Foundation Extensions \*/,", text))
    print(f"  {appex}: embed references left = {still}")

# --- 3. entitlements ---------------------------------------------------------------------------
ents = plistlib.loads(ENT.read_bytes())
print("entitlements before:", sorted(ents))
keep = {}  # nothing in the stock set is signable by a free team except app groups, which needs registration
keep["com.apple.developer.kernel.increased-memory-limit"] = True
ENT.write_bytes(plistlib.dumps(keep))
print("entitlements after: ", sorted(keep))
