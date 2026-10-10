# Integrate the revised nabla harp icon

This package supersedes the earlier plain triangular icon. The user's current design is the further enlarged seven-string harp in `source/icon.svg`, with a clean coral/crimson boundary and a single purple shadow translated exactly equally right and down.

1. Read `README.md` and `export-manifest.json`. Use the current master and exports; do not restore the old pale outline or unstringed triangle from `reference/`.
2. Inspect the app's asset setup. For a normal iOS target, copy `ios-single-size/AppIcon.appiconset` into `Assets.xcassets`. If explicit icon slots are needed, use `ios-all-sizes/AppIcon.appiconset` instead. Install one alternative only; preserve unrelated assets and other targets' icon sets.
3. Verify the intended target uses `AppIcon` as its app icon source. An existing Icon Composer `.icon` configuration may take precedence; inspect and choose the intended route deliberately. Build the IPA and inspect Home Screen, Settings, and Spotlight appearances on-device.
4. For a toolchain accepting one icon path, configure `png/icon-1024.png` using the existing project's convention.
5. Keep the top rail, both diagonal rails, and seven strings as geometric vectors. Strings run parallel to the left diagonal, terminate in the top/right rails, and leave one-and-a-half unused string spacings at each end. The foreground and shadow both use `harp-symbol` so the same complete harp is drawn twice.
6. Apply feathering only to the dark purple copy. Preserve the current `(24, 24)` shadow offset unless the user requests another visual adjustment. The equal horizontal and vertical translation is explicit; do not substitute a different ratio to equalize visible widths. Do not introduce a separate shadow on the lavender foreground or a pale border highlight.
7. For direct master edits, run `python scripts/export_icons.py`; it derives layers and icon assets from the chosen master. For changes in `design.json`, run `python scripts/build_sources.py` first. Rebuilding overwrites direct source edits. Exporting overwrites derived layers and presentation SVGs.
8. Keep the production image square and opaque. Transparent exterior corners and charcoal comparison-sheet backgrounds are preview-only. All isolated layers use the same 1024-unit canvas and must remain aligned.
9. For six- or eight-string variants, use `--strings 6` or `--strings 8` with the exporter, then verify the manifest. If selected as the new default, change `design.json` and rebuild all sources.
10. Report the final source/count, changed project configuration, build result, and on-device visual check. File validation in this package does not replace build validation.

For Icon Composer, use `icon-composer-layers/background.png`, `shadow.png`, then `foreground.png`. These are input layers rather than an authored `.icon` file. System glass/material settings may modify the appearance; avoid duplicating the purple shadow. Use the PNG catalog if exact reproduction is the priority.
