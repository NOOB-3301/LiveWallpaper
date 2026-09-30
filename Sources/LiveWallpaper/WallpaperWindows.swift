import AppKit
import AVFoundation

@MainActor final class WallpaperWindowManager {
    var onPlaybackFailure: (@MainActor (URL) -> Void)?
    private(set) var currentURL: URL?
    var isShowing: Bool { currentURL != nil }

    init() {}

    func show(url: URL) { currentURL = url }
    func hide() { currentURL = nil }
    func setPaused(_ paused: Bool) {}
}
