# Nabla harp app icon — revision 3

Use `source/icon.svg` as the authoritative editable design master. This revision follows the user’s drawn spacing reference, keeps seven strings, enlarges the prior harp, and uses exactly equal horizontal and vertical shadow offsets.

## Design changes

| Element | Current design |
| --- | --- |
| Strings | Seven 14.4-unit-wide diagonal strings; each is an individually named vector path |
| String arrangement | Parallel to the left diagonal, anchored between the horizontal top rail and right diagonal rail |
| End spacing | One-and-a-half unused string spacings at both ends of the sequence; strings stop at their rails |
| Symbol scale | Frame width and rail thickness enlarged another 20% from revision 2 (41.6% above revision 1) |
| Position | Center x = 500, top y = 170 on a 1024-unit canvas; the symbol and its shadow are centered together |
| Shadow | The exact same complete harp geometry, translated x = 24, y = 24, exactly |
| Feather | One Gaussian blur, sigma 3.5; no additional foreground drop shadow |
| Tile boundary | Pale highlight stroke removed; crimson rim meets the coral gradient directly |

The previous harp shadow moved x = 18, y = 41.569219. This revision follows the explicit request for **equal X/Y displacement**: the unchanged shared harp geometry is copied beneath the foreground, recolored dark purple, and translated (24, 24). There is no independent scaling or adjustment of the shadow copy.

The nearest symbol/shadow extents, allowing about three blur sigmas, leave approximately 7.4% of the full canvas to the external right edge and 10.1% to the external bottom edge. Left clearance is about 8.4%; top clearance is larger. These are geometric estimates; final system masking should be inspected on-device.

The seven-string group now spans two-thirds of the opening instead of three-quarters. The `blank_end_slots` parameter is 1.5: along each anchor rail, the opening corner to the first/last string centerline is one-and-a-half normal centerline spacings. This includes a hypothetical unused string position plus extra room, rather than distributing bars evenly across the entire opening. String thickness remains independently editable.

The foreground and shadow both reference **one shared `harp-symbol` group**, including the triangular ring and strings. Their sizes cannot drift independently. The strings' ends extend a few units into their rails for seamless joins. They are filled vector quadrilaterals, not bitmap lines or flattened strokes.

## Files and integration

| File/folder | Purpose |
| --- | --- |
| `source/icon.svg` | Default seven-string production master; fully opaque square background |
| `source/icon-six-strings.svg`, `icon-seven-strings.svg`, `icon-eight-strings.svg` | Comparable string-count alternatives |
| `source/background.svg`, `shadow.svg`, `foreground.svg` | Derived aligned editable layers on 1024-unit canvases |
| `source/mark.svg` | Foreground and shadow on a transparent canvas |
| `source/presentation.svg` | Rounded standalone tile; preview/presentation use |
| `ios-single-size/AppIcon.appiconset` | Modern single-1024-image iOS asset catalog |
| `ios-all-sizes/AppIcon.appiconset` | Explicit iPhone, iPad, and App Store entries; 18 slots |
| `png/` | Opaque RGB sRGB icon exports |
| `icon-composer-layers/` | Aligned 1024-pixel background RGB and foreground/shadow RGBA layers |
| `preview/` | Revision comparison, six/seven/eight-string options, and actual-size sheet |
| `reference/` | User-supplied images and previous vector reconstruction for comparison |
| `AGENT-HANDOFF.md` | Integration instructions for the app-development agent |

PNG dimensions: **20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 512, 1024, 2048, 4096 pixels**. Every size is rendered from SVG. Smaller PNGs are not enlarged to make larger ones.

For a standard iOS app, copy **one** `AppIcon.appiconset` directory into `Assets.xcassets` and select `AppIcon` for the intended target. The two catalogs are alternatives. Xcode can generate smaller iOS variations from the single 1024 image. For a cross-platform toolchain accepting one icon file, use `png/icon-1024.png` in the project's existing icon configuration.

The production square is fully opaque. The rounded *inset* is the decorative rim design; iOS provides the exterior mask. Do not use the transparent-corner presentation SVG or page-background previews as production inputs.

For Icon Composer, import background, shadow, then foreground from `icon-composer-layers/`, keeping their full 1024-pixel canvases registered. This package supplies source layers, **not a compiled `.icon` document**. System materials or extra shadows may alter the appearance. Avoid duplicating the purple shadow. Use the flattened PNG asset catalog when preserving this exact artwork is the priority. Custom dark, tinted, and clear appearances are not authored here.

## Editing and regeneration

Requirements: Inkscape and Python with Pillow (`python -m pip install -r requirements.txt`).

- **Direct edits:** Edit `source/icon.svg`, including the individually named string paths in its `defs`, then run `python scripts/export_icons.py`. It reads the master without rebuilding it and derives the layer SVGs, presentation SVG, PNGs, and catalogs from it.
- **Parametric edits:** Edit `design.json`, then run `python scripts/build_sources.py` and `python scripts/export_icons.py`. The builder overwrites all nine generated SVGs, including direct edits. Count, width, endpoint spacing, geometry, colors, shadow position, opacity, and feathering are configurable.
- **Alternative count:** Run `python scripts/export_icons.py --strings 6` or `--strings 8` to export the corresponding alternative into the catalogs. Check `export-manifest.json` for the active source. To make that count the primary master, change the count in `design.json` and rebuild.
- **Previews:** Run `python scripts/make_previews.py` after exporting. Its outside corner mask is an approximation for previews, not Apple's exact system mask.

Treat the master as authoritative: exporting overwrites derived background/shadow/foreground/mark/presentation SVGs. Changes made only in those derived files are not merged back into the master.

SVG paths and gradients remain scalable without a fixed-resolution source bitmap. Gaussian feathering is evaluated at each output resolution. PNGs use lossless compression but retain their specified finite pixel dimensions.

## Validation and limits

Shipping PNG dimensions, complete image decoding, RGB mode without an alpha channel, embedded sRGB profiles, and all 19 references across both catalogs are verified. Shared harp geometry, seven independently named strings, one feather filter, and absence of the former border stroke are also verified. The revised icon and actual-size sheet were visually inspected. SVGs contain no raster images, external assets, or scripts.

Xcode compilation and on-device installation have not been performed here. The package's validity does not certify an app build. Twenty- and 29-pixel icons retain the overall harp silhouette; their seven individual strings naturally become harder to separate at those sizes.

## Naming inspiration and Apple references

C. G. Knott's *Life and Scientific Work of Peter Guthrie Tait* (1911), printed page 143, records Robertson Smith's suggestion of “Nabla” because the inverted delta resembled an Assyrian harp. This design nods to that account; it is not a claim to reconstruct a particular historical instrument.

- [Knott's biography of Tait](https://webhomes.maths.ed.ac.uk/~v1ranick/papers/taitbio.pdf)
- [Configure app icons in an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [App icon design guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Create an icon with Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
