import AppKit
import Core

// SCAFFOLD STUB (owner: AGENT). Signatures are the contract with AgentMain.swift; bodies are placeholders.
// Re-derive the logic from the phase-1 AppModel: `git show 66833da:Sources/LiveWallpaper/Model.swift`
// (applyItem / firstPlayableIndex / playbackFailed / scheduleRotation / teardown / videosDidChange /
// rotationSettingsDidChange / targetsDidChange). See SPEC2.md sections 3.3 and 7.
//
// What the agent does: applies the library to the desktop windows and the lock screen, rotates on a timer,
// handles failures, holds the App Nap activity. No UI, no SwiftUI/Combine, never any network.

@MainActor final class Orchestrator {
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
    var blockedReason: String?

    var currentItem: VideoItem? { state.videos.first { $0.id == currentID } }
    var canStart: Bool { state.canStart && blockedReason == nil }
    var canRotate: Bool { state.canRotate }

    private let windows: WallpaperWindowManager
    private let lock: LockScreenWallpaper
    private var statusSequence = 0

    // Builds the backends only; no windows, no timers, no file access.
    init() {
        windows = WallpaperWindowManager()
        lock = LockScreenWallpaper()
    }

    // MARK: Lifecycle (called by AgentMain)

    /// Once, after IPC is listening: loads state.json and agent.json; resumes when `wantsRunning`
    /// (and canStart), otherwise `lock.restore()` so a crashed run cannot leave Apple's Aerials swapped.
    func bootstrap() {
        // TODO(AGENT)
    }

    /// state.json changed. Re-read it and apply the diff live (skip only when the file's revision equals the one
    /// already applied; a lower revision means the file was replaced and still wins): videos removed or added,
    /// rotation settings, desktop/lock targets, exactly like phase 1's didSet observers.
    func reload(revision: Int?) {
        // TODO(AGENT)
    }

    /// Begins at `id`, else state.selectedID, else the first video. No-op when already running or !canStart.
    /// Persists `wantsRunning = true`.
    func start(at id: UUID?) {
        // TODO(AGENT)
    }

    /// Hides the windows, restores originals, persists `wantsRunning = false`. The agent stays alive.
    func stop() {
        // TODO(AGENT)
    }

    /// Jumps to `id` (starting playback if needed).
    func play(_ id: UUID) {
        // TODO(AGENT)
    }

    /// No-op unless running with more than one video.
    func next() {
        // TODO(AGENT)
    }

    /// Pauses/resumes the video AND the rotation timer.
    func setPaused(_ paused: Bool) {
        // TODO(AGENT)
    }

    /// Tears everything down and restores originals. Idempotent (called from quit and from
    /// applicationShouldTerminate). `userQuit` true also persists `wantsRunning = false`;
    /// false (logout, SIGTERM, crash recovery path) leaves it so the next launch resumes.
    func shutdown(userQuit: Bool) {
        // TODO(AGENT)
    }

    /// Snapshot for IPC; bumps the per-run sequence number.
    func status(reply: String?) -> AgentStatus {
        statusSequence += 1
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return AgentStatus(seq: statusSequence, reply: reply, pid: ProcessInfo.processInfo.processIdentifier,
                           agentVersion: version, isRunning: isRunning, isPaused: isPaused,
                           currentID: currentID, failedIDs: Array(failedIDs),
                           message: blockedReason ?? statusMessage, lockBusy: lockBusy,
                           stateRevision: state.revision, quitting: false)
    }
}
