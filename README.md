# DiskGraph

A macOS disk-usage analyser: scan any folder and read it as an interactive sunburst pie
chart or a tree map. An independent reimplementation of **Disk Graph** by Nicolas Kick
(Desairem), built to match its behaviour and appearance closely.

Not affiliated with Desairem. No code, artwork or other assets from the original are used
here — see [Clean-room boundary](#clean-room-boundary).

## Build and run

```bash
swift test                                   # logic suites, no window server needed
brew install xcodegen                        # once
xcodegen generate --spec App/project.yml     # regenerates App/DiskGraph.xcodeproj
xcodebuild -project App/DiskGraph.xcodeproj -scheme DiskGraph build
open App/build/Build/Products/Debug/DiskGraph.app
```

Requires macOS 14+, Xcode 26, and the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

The app is **not sandboxed** and wants **Full Disk Access** so it can measure `~/Library`
and the system volume; it prompts on first launch and deep-links to the right settings
pane. Access is granted per binary, so a rebuild changes the hash and needs re-granting —
use a stable signing identity if that gets tedious.

## Layout

| Module | Contents |
|---|---|
| `Sources/DiskGraphCore` | `getattrlistbulk` scanner, the node store, size modes, formatting |
| `Sources/DiskGraphLayout` | sunburst and tree-map layouts, palette, hit testing, transitions |
| `Sources/DiskGraphRender` | Metal renderer, `Graph.metal`, the graph view and its overlay |
| `Sources/DiskGraphUI` | document, window, toolbar, menus, outline panel, file actions |
| `App/` | XcodeGen spec plus the bundle; compiles the shader into `default.metallib` |

`Core` and `Layout` have no UI dependencies, which is why they carry the tests.

### Three design decisions worth knowing

**The node store is parallel arrays, not objects.** Multi-million-node trees are the
normal case. Children of a node occupy a contiguous index range and always have higher
indices than the node itself, which is what makes the bottom-up size roll-up a single
reverse pass.

**One layout pass emits both geometries.** Every `CellInstance` carries its annular sector
*and* its rectangle. Switching graph type therefore needs no relayout at all — it is a
change of uniform. Navigation animates by blending two index-aligned instance buffers,
which is orthogonal and composes with it.

**Rendering is four instanced draw calls, whatever the cell count.** Cells are bucketed by
how much arc tessellation they need (1/4/16/64 subdivisions), so a hairline sliver costs
four vertices and only large wedges pay for a smooth curve. Borders are computed
analytically in the fragment shader from `fwidth`, so they cost no geometry and stay a
constant pixel width.

## Measured constants

Most of the visual detail here was measured off the installed reference app rather than
guessed. If you change any of it, re-measure the same way — capture both windows at the
same size and compare like-for-like screen grabs.

| Property | Value | How it was established |
|---|---|---|
| Hue | `hue° = (115 − θ°) mod 360`, θ clockwise from 12 o'clock | Sampled a folder of 8 equal files every 15°; the eight plateaus fall on a line of slope −1 through 115° |
| Start angle | 3 o'clock, largest child first, clockwise | A 50/30/20 folder puts the 50 % wedge exactly from 3 to 9 o'clock |
| Hole / ring width | 0.294 / 0.118 of half the view's smaller dimension | One-ring window measured 100 pt hole, 40 pt ring against a 340 pt half-minimum |
| Disc radius | `hole + rings × width`, capped at 0.96 | The disc *grows with depth* — a folder of packages draws a thin donut, a nested tree fills the view |
| Saturation / value | flat with depth | A fourth-ring cell is exactly as saturated as a first-ring one; all colour variation is angular |
| Background (dark) | `#424242` | Sampled from the reference window |
| Hard links | **deduplicated** (a deliberate departure) | The reference reports 22.52 GB for `/Applications`, which this scanner matches exactly with dedup *off*. `du` says 22.23 GB with it on, and that is what you would actually reclaim, so dedup is the default here. Switchable in Settings. |
| Packages | one cell, contents still counted | Why `/Applications` is a single ring in both apps despite every bundle being several levels deep |
| Default layout | `Stack` | Read out of the reference app's own View ▸ Layout menu |
| Defaults | Pie Chart, Size on Disk, Hue Wheel, Show Available Space on | Read out of the running app's menu checkmarks |

Two caveats:

- **Light mode is extrapolated, not measured.** Sampling it would mean switching the whole
  system appearance. The dark values are solid; re-derive light from a light-mode capture
  when convenient.
- **Palette values are pre-compensated.** This renderer's output measures lighter and less
  saturated than requested through this display's colour pipeline, so the numbers in
  `CellPalette` were solved backwards until a grab of our window matched a grab of the
  reference's. They are not the "true" HSV the original passes in.

### Menu structure

The View menu mirrors the reference: `Graph Type`, `Size Mode` and `Color Mode` are inline
**section headers** with flat items, not submenus. Only `Graph Options` is a real submenu,
and its contents depend on the graph type — `Graph Levels` for the pie; `Directory
Border`, `Layout` and the two tree-map toggles for the tree map. The continuous values are
`Decrease`/`Increase`/`Reset` triplets, as in the original.

## Getting the numbers right

Two macOS-specific traps, both of which produced visibly wrong totals before they were
fixed. They are worth knowing about before touching the scanner.

**Firmlinks make the boot volume look doubled.** On an APFS system volume group `/Users`,
`/Applications`, `/Library`, `/private` and a dozen more (see `/usr/share/firmlinks`)
appear under `/` but live on the Data volume — which is *also* mounted at
`/System/Volumes/Data`. Every one of them is reachable by two paths, and `stat` reports the
**same device id** for both, so the usual "don't cross device boundaries" check cannot tell
them apart. A naive walk of `/` counts most of the disk twice.

Two things prevent it. `VolumeMap` excludes `/System/Volumes/Data` when it is not the scan
root, since everything under it is reachable through the firmlinks. And every directory is
claimed by exact `(device, inode)` before being walked, so any second path to it — firmlink,
bind mount, `/Volumes/Macintosh HD` — finds it already taken. `du` has no such protection:
`du -sk /System` reports 540 GB on this machine because it walks straight into the Data
volume, against 70 GB for the System volume's actual content.

**Volume scope.** `VolumeScope` decides how far a scan may wander, defaulting to
`.sameDisk`: other volumes of the same APFS container are included (the System and Data
volumes are slices of one disk, and counting only one would under-report enormously) while
external drives and network mounts are not. `autofs` mount points such as `/net` and
`/home` are always skipped — they block waiting on a network mount.

**Progress needs a denominator.** Nothing can know a tree's size without walking it, so the
percentage has to come from outside the walk. In order of preference: the total this same
folder came to on a previous scan (remembered by `ScanHistory`), else the used bytes of its
volume from `statfs`. With neither, progress falls back to the share of discovered
directories finished — which barely moves on a depth-first walk, because the queue stays
short, so `ScanProgress.isEstimateMeaningful` is false and the UI shows an indeterminate bar
rather than a number it cannot stand behind.

**What no path walker can see.** APFS clones share blocks copy-on-write, and both paths
report their full size. A whole-volume total therefore reads somewhat higher than the
container's real usage — about 4 % on this machine. `du` has the same blind spot. Snapshots
are invisible too.

## Scope

Included: scanning, both graphs, hover tooltip, drill-down with Previous/Next, search
dimming, size and colour modes, Graph Options, all four tree-map layouts, Show List
outline, Reveal in Finder / Quick Look / Move to Bin with undo, document-per-folder
windows, animated transitions.

Not included: the Favorites launcher window, the predicate-based exclude filter, snapshot
export and snapshot sequences, iOS/visionOS targets, localisation beyond English.

Known gap: `Show Available Space` is wired through `GraphOptions` and the menu but the
layouts do not yet add a free-space cell for volume roots.

## Verification

`swift test` covers the scanner against fixture trees (hard links, symlink loops, packages,
unreadable directories, cancellation), the firmlink defences (`VolumeMap` exclusions,
directory claiming by inode, volume scopes nesting correctly), layout invariants (children
tile their parent with no overlap or gaps for all four strategies, angles sum correctly,
merge behaviour), the measured hue mapping and start angle, the tooltip and centre-label
text — including that a merged group reports its own total rather than zero or its parent's
— and the Swift↔Metal struct layouts.

Cross-check a total against `du -sk <folder>` on a subtree with no firmlinks in it;
`/Applications` and `~/Library` both agree byte-for-byte.

Measured on an M-series Mac: `/Applications` (340 k nodes) scans in 0.6 s and `~/Library`
(357 k nodes) in 1.1 s, both agreeing byte-for-byte with `du`. Worst-case layout — no
merging, 292 k cells, both graphs fused — takes 71 ms, and it happens on a background
queue, not per frame. Hit testing is analytic and runs at over 100 M probes/second.

## Clean-room boundary

The installed `Disk Graph Lite` was used as a *specification*: its `Localizable.strings`
for exact UI wording, its menus for structure and defaults, and screen grabs of it running
for geometry and colour. Its shader sources were deliberately not read, its binary was not
disassembled, and none of its assets — icon, asset catalogue, branding — are reused. This
project has its own bundle identifier and its own artwork.
