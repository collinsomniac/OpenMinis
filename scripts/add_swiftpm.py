#!/usr/bin/env python3
"""Add SwiftPM package dependencies to the Xcode project (idempotent).

Adding a package to a pbxproj by hand means five coordinated edits, and missing any one of them
produces a different confusing failure:

  1. `XCRemoteSwiftPackageReference`            — the package itself
  2. `XCSwiftPackageProductDependency`          — one per *product* (a package can vend several)
  3. the PBXProject's `packageReferences` list
  4. the app target's `packageProductDependencies` list
  5. a PBXBuildFile with `productRef` in the app target's **Frameworks** phase

Step 5 is the one that actually links it. Missing it, the package resolves and the product still
cannot be imported.

Usage:
  python3 scripts/add_swiftpm.py <src/ios>
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "src/ios")
PBX = ROOT / "Minis.xcodeproj" / "project.pbxproj"

# (package name, repository url, requirement kind, requirement version, [products])
PACKAGES = [
    ("mlx-swift-lm", "https://github.com/ml-explore/mlx-swift-lm",
     "upToNextMinorVersion", "3.32.3", ["MLXLLM", "MLXLMCommon", "MLXHuggingFace"]),
    ("mlx-swift", "https://github.com/ml-explore/mlx-swift",
     "upToNextMinorVersion", "0.32.3", ["MLX"]),
    ("swift-huggingface", "https://github.com/huggingface/swift-huggingface",
     "upToNextMajorVersion", "0.9.0", ["HuggingFace"]),
    ("swift-transformers", "https://github.com/huggingface/swift-transformers",
     "upToNextMajorVersion", "1.3.0", ["Tokenizers"]),
]


def uid(seed: str) -> str:
    return "E7A" + hashlib.sha1(seed.encode()).hexdigest()[:21].upper()


def balanced(text: str, start: int) -> str:
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return text[start:]


def app_target(text: str) -> tuple[str, str] | None:
    """(target id, Frameworks phase id) for the application target."""
    for m in re.finditer(r"\t+([0-9A-F]{8,24}) /\* ([^*]+) \*/ = \{\n\t+isa = PBXNativeTarget;", text):
        tid = m.group(1)
        block = balanced(text, text.index("{", m.start()))
        if 'productType = "com.apple.product-type.application"' not in block:
            continue
        build = re.search(r"buildPhases = \((.*?)\);", block, re.S)
        if not build:
            continue
        for pid, name in re.findall(r"([0-9A-F]{8,24}) /\* ([^*]+) \*/", build.group(1)):
            if name.strip() == "Frameworks":
                return tid, pid
    return None


t = PBX.read_text()
target = app_target(t)
if not target:
    sys.exit("could not find the application target")
target_id, frameworks_id = target
print(f"app target {target_id}  Frameworks phase {frameworks_id}")

inserted = []

for name, url, kind, version, products in PACKAGES:
    ref = uid("ref:" + name)
    if f'repositoryURL = "{url}"' not in t:
        s = t.index("/* Begin XCRemoteSwiftPackageReference section */")
        s = t.index("\n", s) + 1
        t = t[:s] + (f'\t\t{ref} /* XCRemoteSwiftPackageReference "{name}" */ = {{\n'
                     f'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
                     f'\t\t\trepositoryURL = "{url}";\n'
                     f'\t\t\trequirement = {{\n\t\t\t\tkind = {kind};\n'
                     f'\t\t\t\tminimumVersion = {version};\n\t\t\t}};\n\t\t}};\n') + t[s:]
        # project packageReferences
        anchor = "\t\t\tpackageReferences = (\n"
        i = t.index(anchor) + len(anchor)
        t = t[:i] + f'\t\t\t\t{ref} /* XCRemoteSwiftPackageReference "{name}" */,\n' + t[i:]
        inserted.append(name)

    for product in products:
        pid, bid = uid("prod:" + name + product), uid("bf:" + name + product)
        if f"productName = {product};" in t or f'productName = "{product}";' in t:
            continue
        s = t.index("/* Begin XCSwiftPackageProductDependency section */")
        s = t.index("\n", s) + 1
        t = t[:s] + (f'\t\t{pid} /* {product} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n'
                     f'\t\t\tpackage = {ref} /* XCRemoteSwiftPackageReference "{name}" */;\n'
                     f'\t\t\tproductName = {product};\n\t\t}};\n') + t[s:]
        # build file
        s = t.index("/* Begin PBXBuildFile section */")
        s = t.index("\n", s) + 1
        t = t[:s] + (f'\t\t{bid} /* {product} in Frameworks */ = {{isa = PBXBuildFile; '
                     f'productRef = {pid} /* {product} */; }};\n') + t[s:]
        # target product deps
        m = re.search(re.escape(target_id) + r" /\* [^*]+ \*/ = \{.*?packageProductDependencies = \(\n",
                      t, re.S)
        if m:
            t = t[:m.end()] + f"\t\t\t\t{pid} /* {product} */,\n" + t[m.end():]
        else:
            m2 = re.search(re.escape(target_id) + r" /\* [^*]+ \*/ = \{", t)
            t = t[:m2.end()] + f"\n\t\t\tpackageProductDependencies = (\n\t\t\t\t{pid} /* {product} */,\n\t\t\t);" + t[m2.end():]
        # frameworks phase files
        m3 = re.search(re.escape(frameworks_id) + r' /\* Frameworks \*/ = \{\n\t*isa = PBXFrameworksBuildPhase;.*?files = \(\n', t, re.S)
        t = t[:m3.end()] + f'\t\t\t\t{bid} /* {product} in Frameworks */,\n' + t[m3.end():]
        inserted.append(name + "/" + product)

PBX.write_text(t)
t2 = PBX.read_text()
print("inserted:", inserted if inserted else "nothing (already present)")
for _, _, _, _, products in PACKAGES:
    for product in products:
        n = t2.count(f"productName = {product};") + t2.count(f'productName = "{product}";')
        fw = f"in Frameworks */," 
        print(f"   {product:16s} productDep={n}  braceBalance={t2.count('{') - t2.count('}')}")
print("frameworks entries:", t2.count("in Frameworks */,"))
