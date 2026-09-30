import Foundation
import AppKit
import Combine
import Core

// The Settings app's model: the only writer of state.json and the only IPC client of the wallpaper agent.
// It never plays anything. Persisted changes are committed and announced with a `.reload` command; the agent
// (a separate process) applies them. SPEC2.md sections 3.4 and 3.6.

/// What the Settings app knows about the agent process.
enum AgentPresence: Equatable {
    case unknown       // nothing checked yet (app just launched)
    case notRunning    // no agent process
    case launching     // launched or found, waiting for its first status
    case running       // a status arrived
    case unresponsive  // process exists but did not answer within ~4.5 s (three tries)
}

@MainActor final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    static let minimumInterval: TimeInterval = LibraryState.minimumInterval
    private static let launchFailure = "Couldn’t start the wallpaper agent."

    // Persisted in state.json; UI-bound. Every change is written (StateStore.commit) and followed by a
    // `.reload` command to the agent. Bulk changes go through `batch` (one write) and never write while loading.
    @Published var videos: [VideoItem] = [] { didSet { persist() } }
    @Published var selectedID: VideoItem.ID? = nil { didSet { persist() } }
    @Published var rotateEnabled: Bool = true { didSet { persist() } }
    @Published var intervalValue: Int = 5 {          // clamped to 1...999
        didSet {
            let clamped = LibraryState.clampedInterval(intervalValue)
            if clamped != intervalValue { intervalValue = clamped }
            persist()
        }
    }
    @Published var intervalUnit: IntervalUnit = .minutes { didSet { persist() } }
    @Published var applyToDesktop: Bool = true { didSet { persist() } }
    @Published var applyToLockScreen: Bool = true { didSet { persist() } }

    // Agent mirror (read-only for views).
    @Published private(set) var presence: AgentPresence = .unknown
    @Published private(set) var agentStatus: AgentStatus? = nil
    /// Videos imported from the phase-1 app on this launch (0 = none). Drives a dismissible banner.
    @Published private(set) var importedFromPhase1: Int = 0
    /// A phase-1 copy of the app is running; it would fight the agent over the wallpaper.
    @Published private(set) var legacyAppRunning: Bool = false
    /// The agent process ended without announcing it (crash or kill). Cleared by the next launch.
    @Published private(set) var agentStoppedUnexpectedly: Bool = false
    /// Settings-side problem (could not launch the agent, could not write state.json); cleared by clearStatus().
    @Published private(set) var localMessage: String? = nil

    var isRunning: Bool { agentStatus?.isRunning ?? false }
    var isPaused: Bool { agentStatus?.isPaused ?? false }
    var currentID: VideoItem.ID? { agentStatus?.currentID }
    var failedIDs: Set<VideoItem.ID> { Set(agentStatus?.failedIDs ?? []) }
    var lockBusy: Bool { agentStatus?.lockBusy ?? false }
    var statusMessage: String? { localMessage ?? agentStatus?.message }

    /// An agent process exists (whether or not it answers).
    var agentIsAlive: Bool { presence != .notRunning && presence != .unknown }
    /// The running agent comes from another build of the app (an old process that survived a bundle replacement).
    var agentIsOutdated: Bool {
        guard let running = agentStatus?.agentVersion, !running.isEmpty,
              let own = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return false }
        return running != own
    }

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

    private let endpoint = SettingsEndpoint()
    private var written = LibraryState()           // what state.json last held, revision included
    private var writesSuspended = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var queued: AgentCommand?              // the wanted command, sent when the agent's first status arrives
    private var awaiting: [String: Task<Void, Never>] = [:]   // command id -> retransmit chain
    private var launchTimeout: Task<Void, Never>?
    private var reloadGuard: Task<Void, Never>?
    private var lastPID: Int32 = 0
    private var lastSeq = 0
    private var expectedExit = false               // the agent announced (or was told) that it quits
    private var restartPending = false

    // Loads state only; bootstrap() starts the first real work.
    init() {}

    // MARK: Lifecycle (called by AppDelegate)

    /// Once, from applicationDidFinishLaunching: loads (or migrates) the library, checks for a phase-1 copy,
    /// listens for agent statuses and launches/terminations, then pings. Does not launch the agent.
    func bootstrap() {
        let loaded = StateStore.loadOrMigrate()
        batch(persisting: false) { apply(loaded.state) }
        written = loaded.state
        importedFromPhase1 = loaded.importedCount
        legacyAppRunning = Self.otherInstances().contains { $0.legacy }
        endpoint.onStatus = { [weak self] status in self?.received(status) }
        endpoint.startListening()
        observeSystem()
        refreshAgent()
    }

    /// From applicationWillTerminate. Does not stop the agent.
    func shutdown() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        endpoint.onStatus = nil
        [launchTimeout, reloadGuard].forEach { $0?.cancel() }
        awaiting.values.forEach { $0.cancel() }
    }

    // MARK: Library intents (phase-1 semantics)

    /// Filters non-video, dedupes by path, appends, selects the first added if nothing is selected.
    /// Returns the number added.
    @discardableResult func addVideos(urls: [URL]) -> Int {
        var knownPaths = Set(videos.map(\.path))
        var added: [VideoItem] = []
        for url in urls where VideoItem.isVideo(url) {
            let item = VideoItem(url: url)
            if knownPaths.insert(item.path).inserted { added.append(item) }
        }
        guard let first = added.first else { return 0 }
        batch {
            videos += added
            if selectedItem == nil { selectedID = first.id }
        }
        return added.count
    }

    /// Called by the Workshop importer with a finished item (files already in AppPaths.libraryDirectory).
    /// A re-download replaces the earlier copy of the same Workshop item in place.
    func addImported(_ item: VideoItem) {
        batch {
            if let index = videos.firstIndex(where: { $0.workshopID != nil && $0.workshopID == item.workshopID }) {
                if selectedID == videos[index].id { selectedID = item.id }
                videos[index] = item
            } else {
                videos.append(item)
            }
            if selectedItem == nil { selectedID = item.id }
        }
    }

    func hasWorkshopItem(_ workshopID: String) -> Bool {
        videos.contains { $0.workshopID == workshopID }
    }

    /// Removes from the library. Files are deleted only when AppPaths.isInsideLibrary(item.url)
    /// (imported Workshop copies); a local video is never touched.
    func remove(ids: Set<VideoItem.ID>) {
        guard let firstIndex = videos.firstIndex(where: { ids.contains($0.id) }) else { return }
        let removed = videos.filter { ids.contains($0.id) }
        batch {
            videos.removeAll { ids.contains($0.id) }
            if selectedItem == nil {
                selectedID = videos.isEmpty ? nil : videos[min(firstIndex, videos.count - 1)].id
            }
        }
        for item in removed { Self.deleteDownloadedFiles(of: item) }
    }

    func removeAll() {
        remove(ids: Set(videos.map(\.id)))
    }

    // MARK: Agent intents

    /// Starts the agent if needed, then sends `.start` once it answers (queued, 10 s timeout -> localMessage).
    func start() {
        deliver(AgentCommand(kind: .start, videoID: selectedID))
    }

    func stop() {
        queued = nil
        if agentIsAlive { send(AgentCommand(kind: .stop)) }
    }

    func toggleRunning() {
        if isRunning { stop() } else { start() }
    }

    /// Selects `id` and jumps to it (starting playback, and the agent, if needed).
    func play(_ id: VideoItem.ID) {
        guard videos.contains(where: { $0.id == id }) else { return }
        if selectedID != id { selectedID = id }
        deliver(AgentCommand(kind: .play, videoID: id))
    }

    /// Terminates the agent (`.quit`: it restores Apple's wallpapers first).
    func quitAgent() {
        expectedExit = true
        send(AgentCommand(kind: .quit))
        if presence == .unresponsive { Self.agentApplications().forEach { $0.terminate() } }
    }

    /// Quits a running agent and launches a fresh one once the old process is gone.
    func restartAgent() {
        guard agentIsAlive else { launchAgentIfNeeded(); return }
        restartPending = true
        quitAgent()
    }

    /// Launches the nested agent app if it is not running (idempotent).
    func launchAgentIfNeeded() {
        guard presence == .notRunning || presence == .unknown else { return }
        presence = .launching
        agentStoppedUnexpectedly = false
        expectedExit = false
        launchTimeout?.cancel()
        launchTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.presence == .launching else { return }
            self.launchFailed()
        }
        if Self.agentApplications().isEmpty { openAgent() } else { ping() }
    }

    /// Sends a ping; presence becomes .unresponsive if nothing answers.
    func refreshAgent() {
        if Self.agentApplications().isEmpty {
            markAgentGone()
        } else {
            if !agentIsAlive { presence = .launching }
            ping()
        }
    }

    func clearStatus() {
        localMessage = nil
    }

    func dismissImportNotice() {
        importedFromPhase1 = 0
    }

    // MARK: Persistence

    /// Runs `body` with writes suspended, then commits once (unless `persisting` is false).
    private func batch(persisting: Bool = true, _ body: () -> Void) {
        writesSuspended = true
        body()
        writesSuspended = false
        if persisting { persist() }
    }

    private func persist() {
        guard !writesSuspended else { return }
        var state = snapshot
        state.revision = written.revision
        guard state != written else { return }
        guard StateStore.commit(&state) else {
            localMessage = "Couldn’t save your changes."
            return
        }
        written = state
        sendReload(revision: state.revision)
    }

    private func apply(_ state: LibraryState) {
        videos = state.videos
        selectedID = state.selectedID
        rotateEnabled = state.rotateEnabled
        intervalValue = state.intervalValue
        intervalUnit = state.intervalUnit
        applyToDesktop = state.applyToDesktop
        applyToLockScreen = state.applyToLockScreen
    }

    /// Another writer (a second Settings process) committed while this one was in the background.
    private func adoptDiskStateIfNewer() {
        guard let disk = StateStore.load(), disk.revision > written.revision else { return }
        batch(persisting: false) { apply(disk) }
        written = disk
    }

    private static func deleteDownloadedFiles(of item: VideoItem) {
        let file = item.url.standardizedFileURL
        guard AppPaths.isInsideLibrary(file) else { return }
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: AppPaths.isInsideLibrary(folder) ? folder : file)
    }

    // MARK: IPC

    private func sendReload(revision: Int) {
        send(AgentCommand(kind: .reload, revision: revision))
        reloadGuard?.cancel()
        reloadGuard = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.presence == .running,
                  let applied = self.agentStatus?.stateRevision, applied < revision else { return }
            self.send(AgentCommand(kind: .reload, revision: revision))   // once: a lost message self-heals
        }
    }

    /// Sends now when an agent process answers, else queues the command and launches the agent.
    private func deliver(_ command: AgentCommand) {
        switch presence {
        case .running, .unresponsive:
            send(command)
        case .launching:
            queued = command
        case .unknown, .notRunning:
            queued = command
            launchAgentIfNeeded()
        }
    }

    private func ping() {
        send(AgentCommand(kind: .ping))
    }

    /// Posts the command. While an agent process exists it is retransmitted (same id, the agent de-duplicates)
    /// after 1.5 s and 3 s; with no answer after 4.5 s the agent counts as unresponsive.
    private func send(_ command: AgentCommand) {
        endpoint.send(command)
        guard agentIsAlive else { return }
        awaiting[command.id]?.cancel()
        awaiting[command.id] = Task { @MainActor [weak self] in
            for _ in 1...2 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.endpoint.send(command)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.awaiting[command.id] = nil
            if self.agentIsAlive { self.presence = .unresponsive }
        }
    }

    private func received(_ status: AgentStatus) {
        if let reply = status.reply { awaiting.removeValue(forKey: reply)?.cancel() }
        guard accept(status) else { return }
        if status.quitting {
            expectedExit = true
            markAgentGone()
            return
        }
        agentStatus = status
        presence = .running
        agentStoppedUnexpectedly = false
        launchTimeout?.cancel()
        if localMessage == Self.launchFailure { localMessage = nil }
        if let command = queued {
            queued = nil
            send(command)
        }
    }

    /// Ignores statuses that are older than one already seen from the same agent process.
    private func accept(_ status: AgentStatus) -> Bool {
        if status.pid != lastPID {
            lastPID = status.pid
            lastSeq = 0
        }
        guard status.seq > lastSeq else { return false }
        lastSeq = status.seq
        return true
    }

    private func launchFailed() {
        queued = nil
        launchTimeout?.cancel()
        localMessage = Self.launchFailure
        presence = Self.agentApplications().isEmpty ? .notRunning : .unresponsive
    }

    private func markAgentGone() {
        presence = .notRunning
        agentStatus = nil
        lastPID = 0
        lastSeq = 0
        awaiting.values.forEach { $0.cancel() }
        awaiting = [:]
        reloadGuard?.cancel()
    }

    // MARK: Workspace

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let appKey = NSWorkspace.applicationUserInfoKey
        let events = [(NSWorkspace.didLaunchApplicationNotification, true),
                      (NSWorkspace.didTerminateApplicationNotification, false)]
        for (name, launched) in events {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[appKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor [weak self] in self?.applicationChanged(bundleID, launched: launched) }
            }
            observers.append((workspace, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.adoptDiskStateIfNewer() }
        }
        observers.append((center, token))
    }

    private func applicationChanged(_ bundleID: String?, launched: Bool) {
        if bundleID == IPC.settingsBundleID {
            legacyAppRunning = Self.otherInstances().contains { $0.legacy }
        } else if bundleID == IPC.agentBundleID {
            if launched { agentLaunched() } else { agentTerminated() }
        }
    }

    /// The agent was started by someone else (Finder, a login item): find out whether it answers.
    private func agentLaunched() {
        guard !agentIsAlive else { return }
        presence = .launching
        expectedExit = false
        ping()
    }

    private func agentTerminated() {
        guard Self.agentApplications().isEmpty else { return }   // a second agent gave way; the first one stays
        markAgentGone()
        agentStoppedUnexpectedly = !expectedExit
        expectedExit = false
        if restartPending || queued != nil {   // a restart, or a Start pressed while the old agent was quitting
            restartPending = false
            launchAgentIfNeeded()
        }
    }

    private func openAgent() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/LiveWallpaperAgent.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.launchFailed() }
        }
    }

    // MARK: Other processes

    /// Other running copies of this app's bundle id. `legacy`: a phase-1 build (its Info.plist has no LWRole key).
    static func otherInstances() -> [(app: NSRunningApplication, legacy: Bool)] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: IPC.settingsBundleID)
            .compactMap { app -> (app: NSRunningApplication, legacy: Bool)? in
                guard app.processIdentifier != me, !app.isTerminated else { return nil }
                let role = app.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: IPC.roleKey)
                return (app, role == nil)
            }
    }

    private static func agentApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: IPC.agentBundleID).filter { !$0.isTerminated }
    }
}
