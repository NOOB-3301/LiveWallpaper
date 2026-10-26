import AppKit
import Core

// Adapted for the service: the desktop is drawn by a
// WallpaperService (VideoRenderService or SceneRenderService) instead of the agent's windows + the old scene host,
// and the service is the only writer of state.json (StateStore.commit / setMuted). Two channels, one per
// WallpaperTarget (SPEC3.md section 1.2): a changed config of one target never restarts the other.

@MainActor final class Orchestrator {
    private static let unreadableLibrary = "Couldn’t read your library. Using the previous list."
    private static let nothingPlayable = "None of your wallpapers can be played."
    private static let screenDebounce: UInt64 = 3_000_000_000

    /// Fired after any change of the observable properties below (status item and XPC status listen).
    var onChange: (@MainActor () -> Void)?

    /// Library + settings as last read from state.json.
    private(set) var state = LibraryState()
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var failedIDs: Set<UUID> = []
    /// User-facing problem (orange line in the menu, `message` in ServiceStatus). nil = fine.
    private(set) var statusMessage: String?
    /// Why the last item on a target could not play (ServiceStatus.Slot.error); cleared by start and play.
    private(set) var slotErrors: [WallpaperTarget: String] = [:]

    var lockBusy: Bool { lockApplies > 0 }
    var muted: Bool { state.muted }
    var canStart: Bool { hasPlayableTarget }
    var message: String? { statusMessage }

    func currentID(for target: WallpaperTarget) -> UUID? { current[target] }
    func currentItem(for target: WallpaperTarget) -> VideoItem? { state.videos.first { $0.id == current[target] } }
    func canRotate(_ target: WallpaperTarget) -> Bool { isRunning && current[target] != nil && state.hasMultipleItems(target) }

    private var hasPlayableTarget: Bool { WallpaperTarget.allCases.contains { state.canPlay($0) } }

    private let video = VideoRenderService()
    private let scene = SceneRenderService()
    private let lock = LockScreenWallpaper()
    private var current: [WallpaperTarget: UUID] = [:]
    private var rotationTimers: [WallpaperTarget: Timer] = [:]
    private var activity: NSObjectProtocol?
    private var lockApplies = 0
    private var lockRender: Task<Void, Never>?
    private var showDepth = 0  // > 0 while show() runs: a render service may report a failure synchronously
    private var screenTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init() {
        // The scene is on screen: the previous (video) wallpaper can go.
        scene.onReady = { [weak self] _ in self?.video.stop() }
    }

    // MARK: Lifecycle

    /// Once at launch: loads state.json and agent.json; resumes when `wantsRunning` (and canStart), otherwise
    /// `lock.restore()` so a crashed run cannot leave Apple's Aerials swapped.
    func bootstrap() {
        for service in [video, scene] as [WallpaperService] {
            service.onFailure = { [weak self] item, message in self?.desktopFailed(item, message) }
        }
        state = StateStore.load() ?? LibraryState()
        video.setMuted(state.muted)
        scene.setMuted(state.muted)
        if AgentRecordStore.load().wantsRunning, hasPlayableTarget {
            start(at: nil)
        } else {
            setWantsRunning(false)
            lock.restore()
        }
    }

    /// The UI's edited library: written to state.json with the service's own `muted`, then applied.
    /// Returns false when state.json could not be written (nothing is applied then).
    func commit(_ edited: LibraryState) -> Bool {
        var fresh = edited
        fresh.muted = state.muted
        guard StateStore.commit(&fresh) else { return false }
        reload()
        return true
    }

    /// Re-reads state.json and applies it when its revision differs from the applied one.
    func reload() {
        guard let fresh = StateStore.load() else {
            statusMessage = Self.unreadableLibrary
            onChange?()
            return
        }
        if statusMessage == Self.unreadableLibrary { statusMessage = nil }
        if fresh.revision != state.revision { apply(fresh) }
        changed()
    }

    /// Begins at `id` (on `target` only, or on both channels when nil), else each target's selected item, else its
    /// first. No-op when already running or nothing can be played. Persists `wantsRunning = true`.
    func start(at id: UUID?, target: WallpaperTarget? = nil) {
        guard !isRunning, canStart else { return }
        statusMessage = nil
        failedIDs = []
        slotErrors = [:]
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Playing live wallpaper")
        setWantsRunning(true)
        observeSystem()
        // A start for one target starts only that target; nil starts every playable one.
        for channel in WallpaperTarget.allCases where state.canPlay(channel) && (target == nil || target == channel) {
            let items = state.items(for: channel)
            applyItem(on: channel, startingAt: items.firstIndex { $0.id == id } ?? selectedIndex(of: channel))
        }
        changed()
    }

    /// Hides the windows, restores originals, persists `wantsRunning = false`. The service stays alive.
    func stop() {
        guard isRunning else { return }
        halt()
        changed()
    }

    /// Jumps to `id` on `target` (nil = both), starting playback if needed.
    func play(_ id: UUID, target: WallpaperTarget? = nil) {
        guard state.videos.contains(where: { $0.id == id }) else { return }
        guard isRunning else {
            start(at: id, target: target)
            return
        }
        failedIDs.remove(id)  // asking for it by name is worth another try
        for channel in channels(target) where state.canPlay(channel) {
            if let index = state.items(for: channel).firstIndex(where: { $0.id == id }) {
                slotErrors[channel] = nil
                applyItem(on: channel, startingAt: index)
            }
        }
        changed()
    }

    /// Moves `target` (nil = both) on; a channel with fewer than two items stays where it is.
    func next(target: WallpaperTarget? = nil) {
        guard isRunning else { return }
        for channel in channels(target) where current[channel] != nil && state.hasMultipleItems(channel) {
            let items = state.items(for: channel)
            applyItem(on: channel, startingAt: (items.firstIndex { $0.id == current[channel] } ?? -1) + 1)
        }
        changed()
    }

    /// Pauses/resumes the desktop AND the rotation timers.
    func setPaused(_ paused: Bool) {
        guard isRunning, paused != isPaused else { return }
        isPaused = paused
        video.setPaused(paused)
        scene.setPaused(paused)
        WallpaperTarget.allCases.forEach(scheduleRotation)
        changed()
    }

    /// Written to state.json and applied at once.
    func setMuted(_ muted: Bool) {
        guard StateStore.setMuted(muted) != nil else { return }
        reload()
    }

    /// Tears everything down and restores originals. Idempotent. `userQuit` true also persists
    /// `wantsRunning = false`; false (logout, SIGTERM) leaves it so the next launch resumes.
    func shutdown(userQuit: Bool) {
        if userQuit { setWantsRunning(false) }
        if isRunning { teardown() }
    }

    func status() -> ServiceStatus {
        ServiceStatus(
            playback: isRunning ? (isPaused ? .paused : .playing) : .stopped,
            slots: WallpaperTarget.allCases.map { ServiceStatus.Slot(target: $0, itemID: current[$0], error: slotErrors[$0]) },
            stateRevision: state.revision, muted: state.muted, message: message, lockBusy: lockBusy)
    }

    // MARK: Library changes

    // Runs once for a whole new state: each channel compares its own config, so one target's change never
    // touches the other. Adding videos never changes what is playing.
    private func apply(_ fresh: LibraryState) {
        let old = state
        state = fresh  // first, so canPlay and friends read the new values
        failedIDs.formIntersection(fresh.videos.map(\.id))
        if old.muted != fresh.muted {
            video.setMuted(fresh.muted)
            scene.setMuted(fresh.muted)
        }
        scene.update(fresh)  // diffs itself; no restart
        guard isRunning else { return }
        guard hasPlayableTarget else {
            halt()
            return
        }
        WallpaperTarget.allCases.forEach { reconcile($0, from: old) }
    }

    private func reconcile(_ channel: WallpaperTarget, from old: LibraryState) {
        guard state.canPlay(channel) else {
            deactivate(channel)
            return
        }
        guard let playing = current[channel] else {
            if !old.canPlay(channel) { applyItem(on: channel, startingAt: selectedIndex(of: channel)) }
            return
        }
        let items = state.items(for: channel)
        let selected = state.config(for: channel).selectedID
        if !items.contains(where: { $0.id == playing }) {
            // The current item was removed: continue with whatever now sits at its index.
            let oldIndex = old.items(for: channel).firstIndex { $0.id == playing } ?? 0
            applyItem(on: channel, startingAt: min(oldIndex, items.count))
        } else if selected != old.config(for: channel).selectedID, let selected,
                  let index = items.firstIndex(where: { $0.id == selected }) {
            failedIDs.remove(selected)
            slotErrors[channel] = nil
            applyItem(on: channel, startingAt: index)
        }
        if old.rotates(channel) != state.rotates(channel) || old.interval(for: channel) != state.interval(for: channel) {
            scheduleRotation(channel)
        }
    }

    // From a render service: only the item currently on the desktop counts.
    private func desktopFailed(_ item: VideoItem, _ message: String?) {
        guard isRunning, item.id == current[.desktop] else { return }
        fail(item, on: .desktop, message)
        if showDepth == 0 { changed() }  // inside show() the public entry point that called it ends with changed()
    }

    // The status item reads `onChange`, so every public entry point ends here. A run whose channels all ran out of
    // playable items stops, keeping the message that says why.
    private func changed() {
        if isRunning, current.isEmpty {
            let reason = statusMessage ?? Self.nothingPlayable
            halt()
            statusMessage = reason
        }
        onChange?()
    }

    // MARK: Applying

    private func channels(_ target: WallpaperTarget?) -> [WallpaperTarget] {
        target.map { [$0] } ?? WallpaperTarget.allCases
    }

    private func selectedIndex(of channel: WallpaperTarget) -> Int {
        let selected = state.config(for: channel).selectedID
        return state.items(for: channel).firstIndex { $0.id == selected } ?? 0
    }

    // Applies the first playable item at or after `start` (wrapping), then restarts that channel's rotation timer.
    private func applyItem(on channel: WallpaperTarget, startingAt start: Int) {
        let items = state.items(for: channel)
        guard let index = firstPlayableIndex(in: items, from: start) else {
            deactivate(channel)
            statusMessage = Self.nothingPlayable
            return
        }
        statusMessage = nil
        let item = items[index]
        // The lock screen conversion is expensive, so the item that is already showing is left alone.
        if item.id != current[channel] {
            current[channel] = item.id
            show(item, on: channel)
        }
        scheduleRotation(channel)
    }

    private func firstPlayableIndex(in items: [VideoItem], from start: Int) -> Int? {
        for offset in 0..<items.count {
            let index = (start + offset) % items.count
            let item = items[index]
            if failedIDs.contains(item.id) { continue }
            if FileManager.default.fileExists(atPath: item.path) { return index }
            failedIDs.insert(item.id)
        }
        return nil
    }

    // Marks `item` failed on `channel`, moves that channel to the next item and keeps the reason.
    private func fail(_ item: VideoItem, on channel: WallpaperTarget, _ message: String?) {
        failedIDs.insert(item.id)
        slotErrors[channel] = message
        let items = state.items(for: channel)
        applyItem(on: channel, startingAt: (items.firstIndex { $0.id == item.id } ?? -1) + 1)
        if let message { statusMessage = message }
    }

    private func show(_ item: VideoItem, on channel: WallpaperTarget) {
        showDepth += 1
        defer { showDepth -= 1 }
        switch (channel, item.isScene) {
        case (.desktop, false):
            scene.stop()
            video.start(item)
            video.setPaused(isPaused)
        case (.desktop, true):
            // The video windows stay up (previous wallpaper) until the scene renderer shows its first frame.
            scene.update(state)
            scene.start(item)
            if scene.item?.id == item.id { scene.setPaused(isPaused) }
        case (.lock, false):
            applyLock(item.url)
        case (.lock, true):
            showLockScene(item)
        }
    }

    // Stops one channel and gives its target back to Apple.
    private func deactivate(_ channel: WallpaperTarget) {
        rotationTimers[channel]?.invalidate()
        rotationTimers[channel] = nil
        guard current[channel] != nil else { return }
        current[channel] = nil
        switch channel {
        case .desktop:
            video.stop()
            scene.stop()
            case .lock:
            lockRender?.cancel()
            lockRender = nil
            lock.restore()
        }
    }

    // MARK: Lock screen

    private func applyLock(_ url: URL) {
        // Overlapping applies are coalesced by the lock screen backend, so the flag tracks how many are in flight.
        lockApplies += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failure: String?
            do { try await self.lock.apply(from: url) } catch { failure = error.localizedDescription }
            self.lockApplies -= 1
            if let failure, self.isRunning { self.statusMessage = failure }
            self.onChange?()
        }
    }

    private func lockPixelSize() -> (width: Int, height: Int) {
        let size = LockScreenWallpaper.largestScreenPixelSize() ?? CGSize(width: 1920, height: 1080)
        return (Int(size.width.rounded()) & ~1, Int(size.height.rounded()) & ~1)
    }

    // A scene on the lock screen is a video rendered once per resolution and cached next to the scene.
    private func showLockScene(_ item: VideoItem) {
        let size = lockPixelSize()
        lockRender?.cancel()
        lockRender = nil
        if LockRenderCache.isValid(for: item, width: size.width, height: size.height) {
            applyLock(LockRenderCache.videoURL(for: item, width: size.width, height: size.height))
            return
        }
        lockApplies += 1
        // Detached, so cancelling it (another item, lock screen turned off) stops the render itself.
        lockRender = Task.detached(priority: .utility) { [weak self] in
            let result: Result<URL, Error>
            do {
                result = .success(try await LockSceneRecorder.render(item, width: size.width, height: size.height))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lockApplies -= 1
                guard !Task.isCancelled, self.current[.lock] == item.id else { return }
                switch result {
                case .success(let url): self.applyLock(url)
                case .failure(let error): self.fail(item, on: .lock, error.localizedDescription)
                }
                self.onChange?()
            }
        }
    }

    // MARK: System events

    private func observeSystem() {
        video.setScreenLocked(false)
        scene.setScreenLocked(false)
        lock.onScreenLock = { [weak self] locked in
            self?.video.setScreenLocked(locked)
            self?.scene.setScreenLocked(locked)
        }
        lock.startObservingLock()
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screensChanged() }
        }
    }

    // Debounced: a display change fires several notifications. A new size may have a different cached lock video.
    private func screensChanged() {
        screenTask?.cancel()
        screenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.screenDebounce)
            guard !Task.isCancelled, let self else { return }
            self.screenTask = nil
            if self.isRunning, let item = self.currentItem(for: .lock), item.isScene {
                self.showLockScene(item)
                self.changed()
            }
        }
    }

    private func scheduleRotation(_ channel: WallpaperTarget) {
        rotationTimers[channel]?.invalidate()
        rotationTimers[channel] = nil
        guard isRunning, !isPaused, current[channel] != nil, state.rotates(channel) else { return }
        let interval = state.interval(for: channel)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next(target: channel) }
        }
        timer.tolerance = min(interval * 0.1, 5)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimers[channel] = timer
    }

    // MARK: Stopping

    private func teardown() {
        rotationTimers.values.forEach { $0.invalidate() }
        rotationTimers.removeAll()
        screenTask?.cancel()
        screenTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        video.stop()
        scene.stop()
        lock.onScreenLock = nil
        lock.restore()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        isPaused = false
        current.removeAll()
    }

    // An explicit or automatic stop: back to Apple's wallpapers, and nothing to resume at the next launch.
    private func halt() {
        teardown()
        statusMessage = nil
        setWantsRunning(false)
    }

    private func setWantsRunning(_ wants: Bool) {
        AgentRecordStore.update { $0.wantsRunning = wants }
    }
}
