import Foundation
import Combine
import Core

// SCAFFOLD STUB (owner: SETTINGS). Signatures are the contract with ContentView.swift, WorkshopViews.swift,
// App.swift and (via connect) Workshop.swift; bodies are placeholders. Property names deliberately match the
// phase-1 AppModel so the phase-1 views adapt with a rename. Re-derive from
// `git show 66833da:Sources/LiveWallpaper/Model.swift` (AppModel and its didSet observers) and SPEC2.md 3.2.
//
// This model is the Settings app's only writer of state.json and its only IPC client. It never plays anything.

/// What the Settings app knows about the agent process.
enum AgentPresence: Equatable {
    case unknown       // nothing checked yet (app just launched)
    case notRunning    // no agent process
    case launching     // launched or found, waiting for its first status
    case running       // a status arrived
    case unresponsive  // process exists but did not answer a ping within ~3 s
}

@MainActor final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    static let minimumInterval: TimeInterval = LibraryState.minimumInterval

    // Persisted in state.json; UI-bound. Every change is written (StateStore.commit) and followed by a
    // `.reload` command to the agent. Assignments inside init/bootstrap must not write.
    @Published var videos: [VideoItem] = []
    @Published var selectedID: VideoItem.ID? = nil
    @Published var rotateEnabled: Bool = true
    @Published var intervalValue: Int = 5          // clamped to 1...999
    @Published var intervalUnit: IntervalUnit = .minutes
    @Published var applyToDesktop: Bool = true
    @Published var applyToLockScreen: Bool = true

    // Agent mirror (read-only for views).
    @Published private(set) var presence: AgentPresence = .unknown
    @Published private(set) var agentStatus: AgentStatus? = nil
    /// Videos imported from the phase-1 app on this launch (0 = none). Drives a dismissible banner.
    @Published private(set) var importedFromPhase1: Int = 0
    /// A phase-1 copy of the app is running; it would fight the agent over the wallpaper.
    @Published private(set) var legacyAppRunning: Bool = false
    /// Settings-side problem (could not launch the agent, could not write state.json); cleared by clearStatus().
    @Published private(set) var localMessage: String? = nil

    var isRunning: Bool { agentStatus?.isRunning ?? false }
    var isPaused: Bool { agentStatus?.isPaused ?? false }
    var currentID: VideoItem.ID? { agentStatus?.currentID }
    var failedIDs: Set<VideoItem.ID> { Set(agentStatus?.failedIDs ?? []) }
    var lockBusy: Bool { agentStatus?.lockBusy ?? false }
    var statusMessage: String? { localMessage ?? agentStatus?.message }

    /// The persisted fields as one value (what gets written to state.json).
    var snapshot: LibraryState {
        LibraryState(videos: videos, selectedID: selectedID, rotateEnabled: rotateEnabled,
                     intervalValue: intervalValue, intervalUnit: intervalUnit,
                     applyToDesktop: applyToDesktop, applyToLockScreen: applyToLockScreen)
    }

    var selectedItem: VideoItem? { videos.first { $0.id == selectedID } }
    var currentIndex: Int? { videos.firstIndex { $0.id == currentID } }
    var canStart: Bool { snapshot.canStart }
    var canRotate: Bool { snapshot.canRotate }
    var intervalSeconds: TimeInterval { snapshot.intervalSeconds }
    var intervalIsClamped: Bool { snapshot.intervalIsClamped }

    // Loads state only; bootstrap() starts the first real work.
    init() {}

    // MARK: Lifecycle (called by AppDelegate)

    /// Once, from applicationDidFinishLaunching: StateStore.loadOrMigrate, legacy-app check, SettingsEndpoint
    /// listening, NSWorkspace launch/terminate observers for IPC.agentBundleID, first ping.
    func bootstrap() {
        // TODO(SETTINGS)
    }

    /// From applicationWillTerminate. Does not stop the agent.
    func shutdown() {
        // TODO(SETTINGS)
    }

    // MARK: Library intents (phase-1 semantics)

    /// Filters non-video, dedupes by path, appends, selects the first added if nothing is selected.
    /// Returns the number added.
    @discardableResult func addVideos(urls: [URL]) -> Int {
        // TODO(SETTINGS)
        return 0
    }

    /// Called by the Workshop importer with a finished item (files already in AppPaths.libraryDirectory).
    func addImported(_ item: VideoItem) {
        // TODO(SETTINGS)
    }

    func hasWorkshopItem(_ workshopID: String) -> Bool {
        videos.contains { $0.workshopID == workshopID }
    }

    /// Removes from the library. Files are deleted only when AppPaths.isInsideLibrary(item.url)
    /// (imported Workshop copies); a local video is never touched.
    func remove(ids: Set<VideoItem.ID>) {
        // TODO(SETTINGS)
    }

    func removeAll() {
        remove(ids: Set(videos.map(\.id)))
    }

    // MARK: Agent intents

    /// Starts the agent if needed, then sends `.start` once it answers (queued, 10 s timeout -> localMessage).
    func start() {
        // TODO(SETTINGS)
    }

    func stop() {
        // TODO(SETTINGS)
    }

    func toggleRunning() {
        if isRunning { stop() } else { start() }
    }

    /// Selects `id` and jumps to it (starting playback, and the agent, if needed).
    func play(_ id: VideoItem.ID) {
        // TODO(SETTINGS)
    }

    /// Terminates the agent (`.quit`: it restores Apple's wallpapers first).
    func quitAgent() {
        // TODO(SETTINGS)
    }

    /// Launches the nested agent app if it is not running (idempotent).
    func launchAgentIfNeeded() {
        // TODO(SETTINGS)
    }

    /// Sends a ping; presence becomes .unresponsive if nothing answers.
    func refreshAgent() {
        // TODO(SETTINGS)
    }

    func clearStatus() {
        localMessage = nil
    }

    func dismissImportNotice() {
        importedFromPhase1 = 0
    }
}
