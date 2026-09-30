// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LiveWallpaper",
            path: "Sources/LiveWallpaper"
        )
    ]
)
