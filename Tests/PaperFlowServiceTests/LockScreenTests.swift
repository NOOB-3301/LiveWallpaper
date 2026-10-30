import Foundation
import Testing
@testable import PaperFlowService

@MainActor
struct LockScreenTests {
    // macOS 27 regression: restarting only the extension left the agent on a dead connection,
    // and every lock after the first was black.
    @Test func unlockRestartsAgentAndExtension() {
        let names = LockScreenWallpaper.processesToRestart(locked: false, aerialInstalled: true)
        #expect(Set(names) == ["WallpaperAerialsExtension", "WallpaperAgent"])
    }

    // Killing the renderer while locked would blank the lock screen itself.
    @Test func lockRestartsNothing() {
        #expect(LockScreenWallpaper.processesToRestart(locked: true, aerialInstalled: true).isEmpty)
    }

    // Without an installed video the lock screen shows Apple's own aerial; leave it alone.
    @Test func unlockWithoutInstalledVideoRestartsNothing() {
        #expect(LockScreenWallpaper.processesToRestart(locked: false, aerialInstalled: false).isEmpty)
    }

    // macOS 27 re-downloads (and overwrites) an in-use aerial whose SourceURL attribute is missing.
    @Test func installedVideoKeepsOriginalDownloadAttributes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original.mov"), ours = dir.appendingPathComponent("ours.mov")
        try Data([0]).write(to: original)
        try Data([1]).write(to: ours)
        let url = Array("https://sylvan.apple.com/a.mov".utf8)
        #expect(setxattr(original.path, "SourceURL", url, url.count, 0, 0) == 0)

        AerialFiles.copyDownloadAttributes(from: original, to: ours)

        var value = [UInt8](repeating: 0, count: url.count)
        #expect(getxattr(ours.path, "SourceURL", &value, value.count, 0, 0) == url.count)
        #expect(value == url)
        #expect(getxattr(ours.path, "LastETag", nil, 0, 0, 0) == -1)
    }
}
