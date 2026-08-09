// swift-tools-version: 6.0
import PackageDescription

// The graph logic lives in plain libraries so it can be unit tested without a window
// server. Only DiskGraphUI/DiskGraphRender touch AppKit and Metal.
//
// Swift 5 language mode: the scanner deliberately uses a hand-rolled worker pool over
// raw file descriptors and unsafe buffers, which strict concurrency cannot model without
// wrapping every hot-path access.
let package = Package(
    name: "DiskGraph",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskGraphCore", targets: ["DiskGraphCore"]),
        .library(name: "DiskGraphLayout", targets: ["DiskGraphLayout"]),
        .library(name: "DiskGraphRender", targets: ["DiskGraphRender"]),
        .library(name: "DiskGraphUI", targets: ["DiskGraphUI"]),
    ],
    targets: [
        .target(
            name: "DiskGraphCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DiskGraphLayout",
            dependencies: ["DiskGraphCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DiskGraphRender",
            dependencies: ["DiskGraphCore", "DiskGraphLayout"],
            // SwiftPM does not compile .metal files, so the shader ships as a resource.
            // The app target compiles the same file into default.metallib; tests fall
            // back to compiling this copy at runtime.
            resources: [.copy("Shaders/Graph.metal")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DiskGraphUI",
            dependencies: ["DiskGraphCore", "DiskGraphLayout", "DiskGraphRender"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DiskGraphCoreTests",
            dependencies: ["DiskGraphCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DiskGraphLayoutTests",
            dependencies: ["DiskGraphLayout", "DiskGraphCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
