import AppKit
import AVFoundation

/// Layer-backed view whose backing layer is the AVPlayerLayer itself.
private final class PlayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true  // after super.init, so makeBackingLayer() is what creates the layer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set { (layer as? AVPlayerLayer)?.player = newValue }
    }
}

/// File-level on purpose: closures made here are nonisolated, which matters because
/// KVO callbacks arrive on whatever thread AVFoundation picks.
private func observeFailures(of looper: AVPlayerLooper, item: AVPlayerItem,
                             report: @escaping @Sendable () -> Void) -> [NSKeyValueObservation] {
    [
        looper.observe(\.status) { observed, _ in if observed.status == .failed { report() } },
        item.observe(\.status) { observed, _ in if observed.status == .failed { report() } },
    ]
}

@MainActor final class WallpaperWindowManager {
    private static let pauseWhenOccluded = true
    // A fully covered desktop needs no decoder: the player (the biggest allocation) is released after this long.
    private static let releaseDelay: UInt64 = 10_000_000_000

    var onPlaybackFailure: (@MainActor (URL) -> Void)?
    private(set) var currentURL: URL?
    var isShowing: Bool { currentURL != nil }

    private var windows: [NSWindow] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?  // looping silently stops if this is released
    private var statusObservations: [NSKeyValueObservation] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var wakeTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var resumeTime: CMTime?  // where the released player was, for its replacement
    private var failureReported = false
    private var userPaused = false
    private var occluded = false
    private var sleeping = false
    private var playerReleased = false  // the windows stay (black) while the player is gone

    init() {}

    func show(url: URL) {
        if currentURL == url { return }
        currentURL = url
        failureReported = false
        resumeTime = nil  // a new video starts from its beginning
        if observers.isEmpty { installObservers() }
        if windows.isEmpty { rebuildWindows() }
        // While the desktop is covered the new video only starts once it is uncovered (restorePlayerIfReleased).
        if !playerReleased { startPlayer(for: url) }
    }

    func hide() {
        wakeTask?.cancel()
        wakeTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        tearDownPlayer()
        attachPlayer()  // detach from the layers so nothing keeps the old player alive
        windows.forEach { $0.close() }
        windows.removeAll()
        currentURL = nil
        // A stopped wallpaper is never user-paused, so the next show() starts playing.
        userPaused = false
        occluded = false
        sleeping = false
        playerReleased = false
        resumeTime = nil
    }

    func setPaused(_ paused: Bool) {
        userPaused = paused
        applyPlayback()
    }

    // MARK: Windows

    private static func makeWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // ARC owns the window; the default would over-release on close()
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.backgroundColor = .black
        window.contentView = PlayerView(frame: .zero)
        window.orderFrontRegardless()
        return window
    }

    private func rebuildWindows() {
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { Self.makeWindow(on: $0) }
        occluded = false  // new windows report their real state through the occlusion notification
        attachPlayer()
        applyPlayback()
        restorePlayerIfReleased()
    }

    private func attachPlayer() {
        for window in windows { (window.contentView as? PlayerView)?.player = player }
    }

    // MARK: Player

    private func startPlayer(for url: URL) {
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.allowsExternalPlayback = false
        let item = AVPlayerItem(url: url)
        let newLooper = AVPlayerLooper(player: queue, templateItem: item)
        let report: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.reportFailure(for: url) }
        }
        let observations = observeFailures(of: newLooper, item: item, report: report)

        tearDownPlayer()  // the old player goes only after its replacement exists
        player = queue
        looper = newLooper
        statusObservations = observations
        playerReleased = false
        releaseTask?.cancel()  // it belonged to the player that was just replaced
        releaseTask = nil
        if let time = resumeTime {
            queue.seek(to: time)
            resumeTime = nil
        }
        attachPlayer()
        applyPlayback()
        if occluded { scheduleRelease() }
    }

    private func tearDownPlayer() {
        statusObservations.forEach { $0.invalidate() }
        statusObservations.removeAll()
        looper?.disableLooping()
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
    }

    /// Frees the decoder while the desktop is covered; updateOcclusion() builds a new player when it is uncovered.
    private func releasePlayer() {
        releaseTask = nil
        resumeTime = player?.currentTime()
        tearDownPlayer()
        attachPlayer()
        playerReleased = true
    }

    private func scheduleRelease() {
        guard releaseTask == nil, player != nil else { return }
        releaseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.releaseDelay) } catch { return }
            self?.releasePlayer()
        }
    }

    /// Ends a pending release and brings back a released player, unless the machine is asleep (wake rebuilds it).
    private func restorePlayerIfReleased() {
        releaseTask?.cancel()
        releaseTask = nil
        if playerReleased, !sleeping, let url = currentURL { startPlayer(for: url) }
    }

    private func reportFailure(for url: URL) {
        guard url == currentURL, !failureReported else { return }
        failureReported = true
        onPlaybackFailure?(url)
    }

    /// Plays only when neither the user nor the manager itself (sleep, occlusion) wants it paused.
    private func applyPlayback() {
        if userPaused || sleeping || (Self.pauseWhenOccluded && occluded) {
            player?.pause()
        } else {
            player?.play()
        }
    }

    // MARK: System events

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        listen(NSApplication.didChangeScreenParametersNotification) { $0.rebuildWindows() }
        listen(NSWindow.didChangeOcclusionStateNotification) { $0.updateOcclusion() }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            listen(name, on: workspace) { $0.pauseForSleep() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            listen(name, on: workspace) { $0.scheduleWakeRebuild() }
        }
    }

    private func listen(_ name: Notification.Name, on center: NotificationCenter = .default,
                        _ handler: @escaping @MainActor @Sendable (WallpaperWindowManager) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // Nothing from the Notification is sent along; handlers re-read live state instead.
            Task { @MainActor [weak self] in
                if let self { handler(self) }
            }
        }
        observers.append((center, token))
    }

    private func updateOcclusion() {
        occluded = !windows.isEmpty && windows.allSatisfy { !$0.occlusionState.contains(.visible) }
        if occluded { scheduleRelease() } else { restorePlayerIfReleased() }
        applyPlayback()
    }

    private func pauseForSleep() {
        wakeTask?.cancel()
        wakeTask = nil
        sleeping = true
        applyPlayback()
    }

    /// didWake and screensDidWake both fire; re-arming keeps it to one rebuild, after displays settle.
    private func scheduleWakeRebuild() {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            self?.finishWake()
        }
    }

    private func finishWake() {
        wakeTask = nil
        sleeping = false
        occluded = false
        guard let url = currentURL else { return }
        startPlayer(for: url)
    }
}
