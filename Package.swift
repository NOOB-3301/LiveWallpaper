// swift-tools-version: 5.9
import PackageDescription

// Targets, one bundle (see build.sh):
//   Core                    (library)    settings model, state file, XPC/socket messages; no SwiftUI/AppKit
//   SceneFormat             (library)    scene package, texture and scene.json parsing; Foundation only
//   SceneRendererFFI/SceneBridge         Rust + Metal scene renderer (SceneRenderer/, built by scripts/build-scene-renderer.sh)
//   PaperFlowService        (executable) background service: menu bar, playback, lock screen, socket server
//   PaperFlow               (executable) settings app, SwiftUI; Steam sign-in and Workshop downloads
// API floor macOS 14: the scroll and inspector APIs the UI uses are 14-only, so the pre-14 fallbacks are
// gone. The install floor is higher — the Rust renderer compiles at MACOSX_DEPLOYMENT_TARGET=15.0, so the
// plists say 15.0. (tools-version 5.9 has no `.macOS(.v15)`; raising it would flip every target to Swift 6.)
let package = Package(
    name: "PaperFlow",
    platforms: [.macOS(.v14)],
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
            name: "PaperFlowService",
            dependencies: ["Core", "SceneBridge"],
            path: "Sources/PaperFlowService"
        ),
        .executableTarget(
            name: "PaperFlow",
            dependencies: ["Core", "SceneFormat"],
            path: "Sources/PaperFlow"
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
        // Swift Testing (not XCTest) so these also run with the Command Line Tools alone.
        .testTarget(
            name: "PaperFlowServiceTests",
            dependencies: ["PaperFlowService"],
            path: "Tests/PaperFlowServiceTests"
        ),
        .testTarget(
            name: "PaperFlowTests",
            dependencies: ["PaperFlow"],
            path: "Tests/PaperFlowTests"
        ),
    ]
)
