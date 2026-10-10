#!/usr/bin/env python3
"""Rebrand the fork as **Nabla**: an independent app that cannot collide with the installed Minis.

Why every identifier changes:
  - bundle id        — a different App ID is what makes it install *alongside* Minis, not over it
  - app group        — Minis' group is shared with its extensions; reading it from another app is
                       impossible, and code that force-unwraps the container crashes (that was the
                       launch crash: MinisApp.swift `containerURL(...)!`)
  - iCloud container — same reasoning; a free team cannot sign the original container anyway
  - URL scheme       — two apps registering `minis://` is a genuine conflict: iOS picks one
  - document type    — `.minisbak` would make Nabla offer to open Minis' backups
  - display name     — what the user actually sees

Applied to text sources only (swift/plist/entitlements/pbxproj/xcconfig/strings/xcstrings/json).
Order matters: longer, more specific ids first, or `com.openminis.app` would corrupt them.

Usage: python3 scripts/rebrand_nabla.py [src/ios]
"""
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "src/ios")

OLD = "com.openminis.app"
NEW = "io.github.collinsomniac.nabla"
DISPLAY_OLD, DISPLAY_NEW = "Minis", "Nabla"

# (pattern, replacement) in application order
PAIRS = [
    (f"group.{OLD}", f"group.{NEW}"),
    (f"iCloud.{OLD}", f"iCloud.{NEW}"),
    ("minis-mcp", "nabla-mcp"),
    (OLD, NEW),
    ("minisbak", "nablabak"),          # backup UTType + filename extension
    ("MinisConfig", "NablaConfig"),    # app-group subdirectory
    ("MinisBackup", "NablaBackup"),
    ("Minis Backup", "Nabla Backup"),
    ("minis://", "nabla://"),
    ("Minis-Swift.h", "Nabla-Swift.h"),   # ObjC -> generated Swift header follows PRODUCT_NAME
]

TEXT_EXT = {".swift", ".plist", ".entitlements", ".pbxproj", ".xcconfig",
            ".strings", ".stringsdict", ".xcstrings", ".json", ".md", ".h", ".m"}

changed = {}
for p in sorted(ROOT.rglob("*")):
    if not p.is_file() or p.suffix not in TEXT_EXT:
        continue
    if ".git/" in str(p):
        continue
    try:
        t = orig = p.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    for old, new in PAIRS:
        t = t.replace(old, new)
    if t != orig:
        p.write_text(t, encoding="utf-8")
        n = sum(orig.count(o) for o, _ in PAIRS)
        changed[str(p.relative_to(ROOT))] = n

print(f"rewrote {len(changed)} files ({sum(changed.values())} substitutions)")
for k in sorted(changed)[:24]:
    print(f"   {changed[k]:4d}  {k}")
if len(changed) > 24:
    print(f"   ... and {len(changed) - 24} more")

# --- app target naming -----------------------------------------------------------------------
pbx = ROOT / "Minis.xcodeproj" / "project.pbxproj"
t = pbx.read_text()
# the app target ships no explicit display name, so it falls back to PRODUCT_NAME ("Minis")
n_disp = t.count('PRODUCT_BUNDLE_IDENTIFIER = "%s";' % NEW)
n_prod = len(re.findall(r'PRODUCT_NAME = "\$\(TARGET_NAME\)";', t))
t = t.replace('PRODUCT_NAME = "$(TARGET_NAME)";', f'PRODUCT_NAME = "{DISPLAY_NEW}";')
# give the app its own display name explicitly (extensions are stripped from the sideload build)
t = re.sub(r'(\n(\s*)PRODUCT_BUNDLE_IDENTIFIER = "%s";)' % re.escape(NEW),
           r'\1\n\2INFOPLIST_KEY_CFBundleDisplayName = "%s";' % DISPLAY_NEW, t)
pbx.write_text(t)
print(f"project: product name set on {n_prod} configs; display name on {n_disp} app configs")
