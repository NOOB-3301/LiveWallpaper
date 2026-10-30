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
}
