// swift-tools-version: 5.9
import PackageDescription

// Targets, one bundle (see build.sh):
//   Core                    (library)    settings model, state file, XPC/socket messages; no SwiftUI/AppKit
//   SceneFormat             (library)    scene package, texture and scene.json parsing; Foundation only
//   SceneRendererFFI/SceneBridge         Rust + Metal scene renderer (SceneRenderer/, built by scripts/build-scene-renderer.sh)
//   LiveWallpaperService    (executable) background service: menu bar, playback, lock screen, socket server
//   LiveWallpaper           (executable) settings app, SwiftUI; Steam sign-in and Workshop downloads
// Deployment target stays macOS 13 for every target: nothing in the scene engine needs newer API (SPEC3.md 0).
let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "SceneFormat", targets: ["SceneFormat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.11.0"),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")],
            path: "Sources/Core"
        ),
        .target(
            name: "SceneFormat",
            path: "Sources/SceneFormat"
        ),
        // Our own renderer (SceneRenderer/, a Rust library that draws scenes with Metal), via uniffi.
        // Build the static lib and regenerate these sources with scripts/build-scene-renderer.sh.
        .systemLibrary(
            name: "SceneRendererFFI",
            path: "Sources/SceneBridge/FFI"
        ),
        .target(
            name: "SceneBridge",
            dependencies: ["SceneRendererFFI"],
            path: "Sources/SceneBridge",
            exclude: ["FFI"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", Context.packageDirectory + "/SceneRenderer/target/release",
                    "-lscene_renderer",
                ]),
                .linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"), .linkedFramework("CoreText"), .linkedFramework("Foundation"),
                .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
            ]
        ),
        // Background service: the only writer of state.json, plays wallpapers, XPC to the UI. AppKit only.
        .executableTarget(
            name: "LiveWallpaperService",
            dependencies: ["Core", "SceneBridge"],
            path: "Sources/LiveWallpaperService"
        ),
        .executableTarget(
            name: "LiveWallpaper",
            dependencies: ["Core", "SceneFormat"],
            path: "Sources/LiveWallpaper"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "SceneFormatTests",
            dependencies: ["SceneFormat"],
            path: "Tests/SceneFormatTests"
        ),
    ]
)
