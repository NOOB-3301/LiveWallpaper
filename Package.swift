// swift-tools-version: 5.9
import PackageDescription

// Three targets, one bundle (see build.sh):
//   Core                (library)    shared model, state files, IPC; no SwiftUI/AppKit/Combine
//   LiveWallpaperAgent  (executable) headless wallpaper player, AppKit only
//   LiveWallpaper       (executable) Settings app, SwiftUI; also does Steam Workshop downloads
let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "LiveWallpaperAgent",
            dependencies: ["Core"],
            path: "Sources/LiveWallpaperAgent"
        ),
        .executableTarget(
            name: "LiveWallpaper",
            dependencies: ["Core"],
            path: "Sources/LiveWallpaper"
        ),
    ]
)
