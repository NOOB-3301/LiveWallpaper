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

    var onPlaybackFailure: (@MainActor (URL) -> Void)?
    private(set) var currentURL: URL?
    var isShowing: Bool { currentURL != nil }

    private var windows: [NSWindow] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?  // looping silently stops if this is released
    private var statusObservations: [NSKeyValueObservation] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var wakeTask: Task<Void, Never>?
    private var failureReported = false
    private var userPaused = false
    private var occluded = false
    private var sleeping = false

    init() {}

    func show(url: URL) {
        if currentURL == url { return }
        currentURL = url
        failureReported = false
        if observers.isEmpty { installObservers() }
        if windows.isEmpty { rebuildWindows() }
        startPlayer(for: url)
    }

    func hide() {
        wakeTask?.cancel()
        wakeTask = nil
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
        attachPlayer()
        applyPlayback()
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
