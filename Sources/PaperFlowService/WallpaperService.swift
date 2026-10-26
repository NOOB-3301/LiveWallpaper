import AppKit
import Core

// One renderer for one target (today: the desktop, all displays). The Orchestrator owns one of each kind and
// decides which one shows the current item; battery and power rules live in the Orchestrator, not here.

/// Render settings the Orchestrator hands to a running service (fps already capped for battery).
struct RenderOptions: Equatable {
    var fps: Int = LibraryState.defaultSceneFPS
    var scale: Double = 1
    var zoom: Double = 1
    var antialiasing = true
}

@MainActor class WallpaperService {
    /// The item could not be shown (user-facing reason, nil = no detail). The Orchestrator moves on.
    var onFailure: (@MainActor (VideoItem, String?) -> Void)?
    /// The item is on screen. The Orchestrator uses it to retire the previous wallpaper.
    var onReady: (@MainActor (VideoItem) -> Void)?
    private(set) var item: VideoItem?
    private(set) var options = RenderOptions()

    func start(_ item: VideoItem) { self.item = item }
    func stop() { item = nil }
    func setPaused(_ paused: Bool) {}
    func setMuted(_ muted: Bool) {}
    func setScreenLocked(_ locked: Bool) {}
    func apply(_ options: RenderOptions) { self.options = options }
}

/// Videos on the desktop through AVPlayer windows.
@MainActor final class VideoRenderService: WallpaperService {
    private let windows = WallpaperWindowManager()

    override init() {
        super.init()
        windows.onPlaybackFailure = { [weak self] url in
            guard let self, let item = self.item, item.url == url else { return }
            self.onFailure?(item, "Couldn’t play “\(item.name)”.")
        }
    }

    override func start(_ item: VideoItem) {
        super.start(item)
        windows.show(url: item.url)
    }

    override func stop() {
        super.stop()
        windows.hide()
    }

    override func setPaused(_ paused: Bool) { windows.setPaused(paused) }
    override func setMuted(_ muted: Bool) { windows.setMuted(muted) }
    override func setScreenLocked(_ locked: Bool) { windows.setScreenLocked(locked) }
}
