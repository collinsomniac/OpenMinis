#!/usr/bin/env python3
"""Register new source files in the Xcode project.

The Minis project uses explicit PBXFileReference/PBXBuildFile entries for everything except a few
`PBXFileSystemSynchronizedRootGroup` folders (Terminal, tests). A file created on disk but not
registered here is simply not compiled — the first symptom is a "cannot find X in scope" error.

Usage:
  python3 scripts/add_sources.py <src/ios> <group> <file> [<file> ...]

  e.g. python3 scripts/add_sources.py src/ios Shared Shared/AppGroupResolver.swift
       python3 scripts/add_sources.py src/ios Providers/LocalMLX \
              Providers/LocalMLX/LocalModelHost.swift Providers/LocalMLX/LocalMLXProvider.swift

Adds each file to the app target's Sources phase and to the group whose path matches `group`
(creating nothing else). IDs are derived from the path, so re-running is a no-op, not a duplicate.
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "src/ios")
GROUP = sys.argv[2] if len(sys.argv) > 2 else "Shared"
FILES = sys.argv[3:]

PBX = ROOT / "Minis.xcodeproj" / "project.pbxproj"


def uid(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


t = PBX.read_text()


def section(name: str) -> int:
    return t.index(f"/* Begin {name} section */")


added = []
for rel in FILES:
    rel = rel.replace("\\", "/")
    name = rel.split("/")[-1]
    if f"path = {name};" in t and f"/* {name} */ = {{isa = PBXFileReference" in t:
        print(f"   already registered: {name}")
        continue
    fref, bref = uid("fref:" + rel), uid("bref:" + rel)
    ext = rel.rsplit(".", 1)[-1]
    ftype = {"swift": "sourcecode.swift", "m": "sourcecode.c.objc", "h": "sourcecode.c.h",
             "plist": "text.plist.xml", "entitlements": "text.plist.entitlements"}.get(ext, "text")

    s = section("PBXBuildFile")
    t = t[:s] + (f'\t\t{bref} /* {name} in Sources */ = {{isa = PBXBuildFile; '
                 f'fileRef = {fref} /* {name} */; }};\n') + t[s:]
    s = section("PBXFileReference")
    t = t[:s] + (f'\t\t{fref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; '
                 f'path = {name}; sourceTree = "<group>"; }};\n') + t[s:]

    leaf = GROUP.split("/")[-1]
    gm = re.search(rf'/\* {re.escape(leaf)} \*/ = \{{\n(\s*)isa = PBXGroup;.*?\n\s*children = \(\n(.*?)\n(\s*)\);',
                   t, re.S)
    if gm:
        indent = gm.group(1) + "\t"
        t = t[:gm.start(2)] + f"\n{indent}{fref} /* {name} */," + t[gm.start(2):]
    else:
        print(f"   WARNING: group '{leaf}' not found; file reference added but not grouped")

    # target the APP target's Sources phase, not the first one in the file (that belongs to
    # MinisUITests, and a file added there is silently never compiled)
    app = re.search(r'isa = PBXNativeTarget;.*?productType = "com.apple.product-type.application";', t, re.S)
    sm = None
    if app:
        head = t.rfind("isa = PBXNativeTarget;", 0, app.start())
        tid = re.search(r'([0-9A-F]{24}) /\* [^*]+ \*/ = \{\n\t*isa = PBXNativeTarget;', t[:head + 40][::-1])
        phases = re.search(r'buildPhases = \((.*?)\);', t[head:app.end()], re.S)
        if phases:
            src = [pid for pid, nm in re.findall(r'([0-9A-F]{24}) /\* ([^*]+) \*/', phases.group(1))
                   if nm.strip() == "Sources"]
            if src:
                sm = re.search(r'(' + src[0] + r' /\* Sources \*/ = \{\n\t*isa = PBXSourcesBuildPhase;.*?files = \(\n)(.*?)(\n\s*\);)',
                               t, re.S)
    if sm:
        ind = re.search(r'\n(\s*)\S', sm.group(2))
        indent = ind.group(1) if ind else "\t\t\t\t"
        t = t[:sm.start(2)] + f"\n{indent}{bref} /* {name} in Sources */," + t[sm.start(2):]
    else:
        print("   WARNING: app target Sources phase not found; file will NOT be compiled")
    added.append(name)

PBX.write_text(t)
print(f"registered {len(added)} file(s) in group '{GROUP}': {added}")
