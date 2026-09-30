import Foundation
import Core

// Applies the library (state.json, written by the Settings app) to the desktop windows and the lock screen,
// rotates on a timer, handles failures and holds the App Nap activity. The non-UI half of the phase-1 AppModel.
// No UI, no SwiftUI/Combine, never any network (SPEC2.md sections 3.3 and 7).

@MainActor final class Orchestrator {
    private static let unreadableLibrary = "Couldn’t read your library. Using the previous list."

    /// Fired after any change of the observable properties below (status item and IPC status listen).
    var onChange: (@MainActor () -> Void)?

    /// Library + settings as last read from state.json (by bootstrap() and reload(revision:)).
    private(set) var state = LibraryState()
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var currentID: UUID?
    private(set) var failedIDs: Set<UUID> = []
    /// User-facing problem (orange line in the menu, `message` in AgentStatus). nil = fine.
    private(set) var statusMessage: String?
    /// True while the lock screen video is being converted/installed.
    private(set) var lockBusy = false
    /// Set by AgentMain while an older (phase-1) copy of the app is running; start() refuses and reports it.
    var blockedReason: String? { didSet { if blockedReason != oldValue { onChange?() } } }

    var currentItem: VideoItem? { state.videos.first { $0.id == currentID } }
    var canStart: Bool { state.canStart && blockedReason == nil }
    var canRotate: Bool { state.canRotate }
    /// What the menu and the status report: a blocked start outranks a playback problem.
    var message: String? { blockedReason ?? statusMessage }

    private let windows: WallpaperWindowManager
    private let lock: LockScreenWallpaper
    private var rotationTimer: Timer?
    private var activity: NSObjectProtocol?
    private var lockApplies = 0
    private var statusSequence = 0

    private var currentIndex: Int? { position(of: currentID) }

    // Builds the backends only; no windows, no timers, no file access.
    init() {
        windows = WallpaperWindowManager()
        lock = LockScreenWallpaper()
    }

    // MARK: Lifecycle (called by AgentMain)

    /// Once, after IPC is listening: loads state.json and agent.json; resumes when `wantsRunning`
    /// (and canStart), otherwise `lock.restore()` so a crashed run cannot leave Apple's Aerials swapped.
    func bootstrap() {
        windows.onPlaybackFailure = { [weak self] url in self?.playbackFailed(url) }
        state = StateStore.load() ?? LibraryState()
        let wantsRunning = AgentRecordStore.load().wantsRunning
        // An older copy owns the wallpapers while it runs: restoring them from under it would break it.
        guard blockedReason == nil else { return }
        if wantsRunning, state.canStart {
            start(at: nil)
        } else {
            setWantsRunning(false)
            lock.restore()
        }
    }

    /// state.json changed. `revision` is only a hint: the file decides. It is applied whenever its revision differs
    /// from the applied one (a lower revision means the file was replaced and still wins).
    func reload(revision: Int?) {
        guard let fresh = StateStore.load() else {
            statusMessage = Self.unreadableLibrary
            onChange?()
            return
        }
        if statusMessage == Self.unreadableLibrary { statusMessage = nil }
        if fresh.revision != state.revision { apply(fresh) }
        onChange?()
    }

    /// Begins at `id`, else state.selectedID, else the first video. No-op when already running or !canStart.
    /// Persists `wantsRunning = true`.
    func start(at id: UUID?) {
        guard !isRunning, canStart else { return }
        statusMessage = nil
        failedIDs = []
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Playing live wallpaper")
        setWantsRunning(true)
        applyItem(startingAt: position(of: id) ?? position(of: state.selectedID) ?? 0)
        onChange?()
    }

    /// Hides the windows, restores originals, persists `wantsRunning = false`. The agent stays alive.
    func stop() {
        guard isRunning else { return }
        halt()
        onChange?()
    }

    /// Jumps to `id` (starting playback if needed).
    func play(_ id: UUID) {
        guard let target = position(of: id) else { return }
        guard isRunning else {
            start(at: id)
            return
        }
        failedIDs.remove(id)  // asking for it by name is worth another try
        applyItem(startingAt: target)
        onChange?()
    }

    /// No-op unless running with more than one video.
    func next() {
        guard isRunning, canRotate else { return }
        applyItem(startingAt: (currentIndex ?? -1) + 1)
        onChange?()
    }

    /// Pauses/resumes the video AND the rotation timer.
    func setPaused(_ paused: Bool) {
        guard isRunning, paused != isPaused else { return }
        isPaused = paused
        windows.setPaused(paused)
        scheduleRotation()
        onChange?()
    }

    /// Tears everything down and restores originals. Idempotent (called from quit and from
    /// applicationShouldTerminate). `userQuit` true also persists `wantsRunning = false`;
    /// false (logout, SIGTERM, crash recovery path) leaves it so the next launch resumes.
    func shutdown(userQuit: Bool) {
        if userQuit { setWantsRunning(false) }
        if isRunning { teardown() }
    }

    /// Snapshot for IPC; bumps the per-run sequence number.
    func status(reply: String?) -> AgentStatus {
        statusSequence += 1
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return AgentStatus(seq: statusSequence, reply: reply, pid: ProcessInfo.processInfo.processIdentifier,
                           agentVersion: version, isRunning: isRunning, isPaused: isPaused,
                           currentID: currentID, failedIDs: Array(failedIDs),
                           message: message, lockBusy: lockBusy,
                           stateRevision: state.revision, quitting: false)
    }

    // MARK: Library changes

    // The phase-1 didSet observers, run once for a whole new state. Adding videos never changes the current one.
    private func apply(_ fresh: LibraryState) {
        let old = state
        state = fresh  // first, so canStart and friends read the new values
        failedIDs.formIntersection(fresh.videos.map(\.id))
        guard isRunning else { return }
        guard fresh.canStart else {
            halt()
            return
        }
        guard let index = currentIndex else {
            // The current video was removed: continue with whatever now sits at its index.
            let oldIndex = old.videos.firstIndex { $0.id == currentID } ?? 0
            applyItem(startingAt: min(oldIndex, fresh.videos.count))
            return
        }
        let url = fresh.videos[index].url
        if old.applyToDesktop != fresh.applyToDesktop { applyDesktop(url) }
        if old.applyToLockScreen != fresh.applyToLockScreen { applyLock(url) }
        if old.canRotate != fresh.canRotate || old.rotateEnabled != fresh.rotateEnabled
            || old.intervalSeconds != fresh.intervalSeconds {
            scheduleRotation()
        }
    }

    private func playbackFailed(_ url: URL) {
        guard isRunning, let item = state.videos.first(where: { $0.path == url.path }) else { return }
        failedIDs.insert(item.id)
        if item.id == currentID { applyItem(startingAt: (currentIndex ?? -1) + 1) }
        onChange?()
    }

    // MARK: Applying

    private func position(of id: UUID?) -> Int? {
        state.videos.firstIndex { $0.id == id }
    }

    // Applies the first playable video at or after `start` (wrapping), then restarts the rotation timer.
    private func applyItem(startingAt start: Int) {
        guard let index = firstPlayableIndex(from: start) else {
            halt()
            statusMessage = "None of your videos can be played."
            return
        }
        statusMessage = nil
        let item = state.videos[index]
        // The lock screen conversion is expensive, so the video that is already showing is left alone.
        if item.id != currentID {
            currentID = item.id
            applyDesktop(item.url)
            applyLock(item.url)
        }
        scheduleRotation()
    }

    private func firstPlayableIndex(from start: Int) -> Int? {
        let videos = state.videos
        for offset in 0..<videos.count {
            let index = (start + offset) % videos.count
            let item = videos[index]
            if failedIDs.contains(item.id) { continue }
            if FileManager.default.fileExists(atPath: item.path) { return index }
            failedIDs.insert(item.id)
        }
        return nil
    }

    private func applyDesktop(_ url: URL) {
        if state.applyToDesktop {
            windows.show(url: url)
            windows.setPaused(isPaused)
        } else {
            windows.hide()
        }
    }

    private func applyLock(_ url: URL) {
        guard state.applyToLockScreen else {
            lock.restore()
            return
        }
        // Overlapping applies are coalesced by the lock screen backend, so the flag tracks how many are in flight.
        lockApplies += 1
        lockBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failure: String?
            do { try await self.lock.apply(from: url) } catch { failure = error.localizedDescription }
            self.lockApplies -= 1
            self.lockBusy = self.lockApplies > 0
            if let failure, self.isRunning { self.statusMessage = failure }
            self.onChange?()
        }
    }

    private func scheduleRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard isRunning, !isPaused, state.rotationActive else { return }
        let interval = state.intervalSeconds
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
        }
        timer.tolerance = min(interval * 0.1, 5)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    // MARK: Stopping

    private func teardown() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        windows.hide()
        lock.restore()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        isPaused = false
        currentID = nil
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
