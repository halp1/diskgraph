# Diskplot

A macOS disk-usage analyser: scan any folder and read it as an interactive sunburst pie
chart or a tree map. An independent reimplementation of **Disk Graph** by Nicolas Kick
(Desairem), built to match its behaviour and appearance closely.

Not affiliated with Desairem. No code, artwork or other assets from the original are used
here.

## Build and run

```bash
swift test                                   # logic suites, no window server needed
brew install xcodegen                        # once
xcodegen generate --spec App/project.yml     # regenerates App/DiskGraph.xcodeproj
xcodebuild -project App/DiskGraph.xcodeproj -scheme DiskGraph \
           -configuration Release -derivedDataPath App/build build
open App/build/Build/Products/Release/DiskGraph.app
```

Rebuild **both** configurations, or install the one you actually launch.

Requires macOS 14+, Xcode 26, and the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

The app is **not sandboxed** and wants **Full Disk Access** so it can measure `~/Library`
and the system volume. It prompts on first launch and deep-links to the right settings
pane. Access is granted per binary, so a rebuild changes the hash and needs re-granting.
Use a stable signing identity if that gets tedious.

