#!/usr/bin/env python3
"""Register new source files in the Xcode project (idempotent).

The Minis project lists every source explicitly, so a file created on disk but not registered here is
simply not compiled — and the only symptom is "cannot find X in scope".

Three independent steps per file, each applied only if missing:
  1. a PBXFileReference,
  2. a child entry in the named group (cosmetic, for navigation),
  3. a build-file entry in **the app target's** Sources phase  ← the one that actually compiles it.

Step 3 is the subtle one: the first `PBXSourcesBuildPhase` in the file belongs to MinisUITests, so
"the first phase" is the wrong phase. The app target is found by `productType = application` using a
brace-balanced block scan, not a regex that can run across target boundaries.

Usage:
  python3 scripts/add_sources.py <src/ios> <group> <file> [<file> ...]
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


def balanced(text: str, start: int) -> str:
    """Substring from `start` (a '{') to its matching '}'."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return text[start:]


def app_sources_phase_id(text: str) -> str | None:
    """The Sources build phase of the target whose productType is an application."""
    for m in re.finditer(r"isa = PBXNativeTarget;", text):
        block_start = text.rfind("{", 0, m.start())
        block = balanced(text, block_start)
        if 'productType = "com.apple.product-type.application"' not in block:
            continue
        phases = re.search(r"buildPhases = \((.*?)\);", block, re.S)
        if not phases:
            continue
        # ids here are mixed: full 24-char uuids (AA8A56872F6FBB7A00A3E54E) and short readable ones
        # (E51000041). Matching only {24} silently skipped the app target's own Sources phase.
        for pid, name in re.findall(r"([0-9A-F]{8,24}) /\* ([^*]+) \*/", phases.group(1)):
            if name.strip() == "Sources":
                return pid
    return None


t = PBX.read_text()

phase_id = app_sources_phase_id(t)
print(f"app target Sources phase: {phase_id}")

added = []
for rel in FILES:
    rel = rel.replace("\\", "/")
    name = rel.split("/")[-1]
    fref, bref = uid("fref:" + rel), uid("bref:" + rel)
    ext = rel.rsplit(".", 1)[-1]
    ftype = {"swift": "sourcecode.swift", "m": "sourcecode.c.objc", "h": "sourcecode.c.h",
             "plist": "text.plist.xml", "entitlements": "text.plist.entitlements"}.get(ext, "text")
    did = []

    # 1. file reference
    if f"path = {name};" not in t:
        s = t.index("/* Begin PBXFileReference section */")
        t = t[:s] + (f'\t\t{fref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; '
                     f'path = {name}; sourceTree = "<group>"; }};\n') + t[s:]
        did.append("fileRef")

    # 2. build file (the definition the phase refers to)
    if f"{bref} /* {name} in Sources */ = {{isa = PBXBuildFile" not in t:
        s = t.index("/* Begin PBXBuildFile section */")
        t = t[:s] + (f'\t\t{bref} /* {name} in Sources */ = {{isa = PBXBuildFile; '
                     f'fileRef = {fref} /* {name} */; }};\n') + t[s:]
        did.append("buildFile")

    # 3. the app target's Sources phase
    if phase_id and f"{bref} /* {name} in Sources */," not in t:
        m = re.search(re.escape(phase_id) + r' /\* Sources \*/ = \{\n\t*isa = PBXSourcesBuildPhase;.*?files = \(\n', t, re.S)
        if m:
            t = t[:m.end()] + f'\t\t\t\t{bref} /* {name} in Sources */,\n' + t[m.end():]
            did.append("phase")

    # 4. group child (navigation only)
    leaf = GROUP.split("/")[-1]
    gm = re.search(rf'/\* {re.escape(leaf)} \*/ = \{{\n(\s*)isa = PBXGroup;.*?\n\s*children = \(\n(.*?)\n(\s*)\);',
                   t, re.S)
    if gm and f"{fref} /* {name} */," not in t:
        indent = gm.group(1) + "\t"
        t = t[:gm.start(2)] + f"\n{indent}{fref} /* {name} */," + t[gm.start(2):]
        did.append("group")

    print(f"   {name}: {', '.join(did) if did else 'already complete'}")
    added.append(name)

PBX.write_text(t)
print(f"done: {added}")

# verify
t2 = PBX.read_text()
ok = all(f"{uid('bref:' + f.replace(chr(92), '/'))} /* {f.split('/')[-1]} in Sources */," in t2 for f in FILES)
print("all files in the app Sources phase:", ok)
