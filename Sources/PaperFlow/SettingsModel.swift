import Foundation
import AppKit
import Combine
import Core
import SceneFormat

// The Settings app's model. It holds the library and settings the user edits and the status the service reports;
// it never plays anything and never writes state.json. Every change is sent to the service as `.commit`.

@MainActor final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    static let minimumInterval: TimeInterval = LibraryState.minimumInterval

    // Persisted in state.json; UI-bound. Every change is sent to the service (`.commit`). Bulk changes go through `batch` (one write) and never write while loading.
    @Published var videos: [VideoItem] = [] { didSet { persist() } }
    @Published var selectedID: VideoItem.ID? = nil { didSet { persist() } }
    @Published var rotateEnabled: Bool = false { didSet { persist() } }   // rotation needs a curated playlist
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
    /// The desktop's curated playlist; nil = the whole library in library order (TargetConfig.playlist).
    @Published var desktopPlaylistIDs: [VideoItem.ID]? = nil { didSet { persist() } }
    // Schema v2. `selectedID`, `rotateEnabled`, `intervalValue`, `intervalUnit` and `applyToDesktop` above are
    // the DESKTOP config (shared with the lock screen while `sameForBoth`); `lockConfig` is the lock screen's own
    // config, used only while !sameForBoth, and its `enabled` is always `applyToLockScreen`. `sameForBoth` is
    // changed through `setSameForBoth` so the lock config starts from what the lock screen showed. `muted` is
    // sent as `.setMuted`.
    @Published private(set) var sameForBoth: Bool = true { didSet { persist() } }
    @Published var lockConfig: TargetConfig = TargetConfig() {
        didSet {
            let clamped = LibraryState.clampedInterval(lockConfig.intervalValue)
            if clamped != lockConfig.intervalValue { lockConfig.intervalValue = clamped }
            persist()
        }
    }
    @Published var sceneFPS: Int = LibraryState.defaultSceneFPS { didSet { persist() } }
    @Published var sceneOptions: [String: SceneOptions] = [:] { didSet { persist() } }
    @Published var power: PowerOptions = PowerOptions() { didSet { persist() } }
    @Published var muted: Bool = true {
        didSet {
            guard !writesSuspended, muted != oldValue else { return }
            changeMuted(muted)
        }
    }

    /// The library item shown in the Library's preview pane. UI state only (never written to state.json), kept here
    /// so "Show in Library" in the Workshop can point the Library at an item without changing any wallpaper.
    @Published var focusedID: VideoItem.ID? = nil

    // Service mirror (read-only for views).
    /// Videos imported from the phase-1 app on this launch (0 = none). Drives a dismissible banner.
    @Published private(set) var importedFromPhase1: Int = 0
    /// A phase-1 copy of the app is running; it would fight the service over the wallpaper.
    @Published private(set) var legacyAppRunning: Bool = false
    /// Settings-side problem (service unreachable, command failed); cleared by clearStatus().
    @Published private(set) var localMessage: String? = nil

    private var serviceStatus: ServiceStatus? { client.status }
    var isRunning: Bool { serviceStatus.map { $0.playback != .stopped } ?? false }
    var isPaused: Bool { serviceStatus?.playback == .paused }
    var currentID: VideoItem.ID? { serviceStatus?.slot(.desktop)?.itemID }
    /// Items a slot reported an error for.
    var failedIDs: Set<VideoItem.ID> {
        Set((serviceStatus?.slots ?? []).compactMap { $0.error == nil ? nil : $0.itemID })
    }
    /// The item the lock screen channel currently shows (the desktop one is `currentID`).
    var lockID: VideoItem.ID? { serviceStatus?.slot(.lock)?.itemID }
    // shortcut: ServiceStatus says only that a lock video is being made, not how far along; add progress if renders get slow.
    var lockBusy: Bool { serviceStatus?.lockBusy ?? false }
    var lockRender: LockRenderStatus? { nil }
    var statusMessage: String? {
        localMessage ?? serviceStatus?.message ?? serviceStatus?.slots.compactMap(\.error).first
    }

    /// The persisted fields as one value (what gets written to state.json).
    var snapshot: LibraryState {
        // Starts from what state.json last held so fields this model does not edit (muted) survive.
        var state = written
        state.videos = videos
        state.sameForBoth = sameForBoth
        state.desktop = TargetConfig(enabled: applyToDesktop, selectedID: selectedID, playlist: desktopPlaylistIDs,
                                     rotateEnabled: rotateEnabled, intervalValue: intervalValue,
                                     intervalUnit: intervalUnit)
        var lock = lockConfig
        lock.enabled = applyToLockScreen
        state.lock = lock
        state.muted = muted
        state.sceneFPS = sceneFPS
        state.sceneOptions = sceneOptions
        state.power = power
        state.normalize()
        return state
    }

    func sceneOptions(for id: UUID) -> SceneOptions { sceneOptions[id.uuidString] ?? SceneOptions() }

    /// Edits one scene's options and commits them to the service.
    func updateSceneOptions(_ id: UUID, _ change: (inout SceneOptions) -> Void) {
        var options = sceneOptions(for: id)
        change(&options)
        sceneOptions[id.uuidString] = options
    }

    /// Roles of an item for the badges: the enabled targets it is currently selected for.
    func roles(of id: VideoItem.ID) -> Set<WallpaperTarget> { snapshot.targets(of: id) }

    /// The wallpaper source of `target` as the service reports it: the library item currently shown there.
    func currentID(for target: WallpaperTarget) -> VideoItem.ID? {
        target == .desktop ? currentID : lockID
    }

    /// The "Same wallpaper for desktop and lock screen" switch. Turning it off gives the lock screen its own copy
    /// of what it showed so far; turning it on makes it follow the desktop again.
    func setSameForBoth(_ value: Bool) {
        guard value != sameForBoth else { return }
        batch {
            if !value { lockConfig = snapshot.config(for: .lock) }
            sameForBoth = value
        }
    }

    /// "Set as Desktop / Lock Screen / Both" (SPEC3.md 6.2). Commits through the service; starts nothing.
    func assign(_ id: VideoItem.ID, to targets: Set<WallpaperTarget>) {
        var state = snapshot
        state.assign(id, to: targets)
        guard state != snapshot else { return }
        batch { apply(state) }
    }

    // MARK: Playlists

    /// The target's stored playlist order; nil = the whole library in library order.
    func playlistIDs(for target: WallpaperTarget) -> [VideoItem.ID]? {
        snapshot.config(for: target).playlist
    }

    /// The items the target actually rotates through, in playlist order.
    func playlistItems(for target: WallpaperTarget) -> [VideoItem] {
        snapshot.items(for: target)
    }

    /// Writes the target's playlist (nil = use the entire library). Editing the lock screen's playlist
    /// separates it from the desktop's; editing the desktop's keeps both in step while they are shared.
    func setPlaylist(_ ids: [VideoItem.ID]?, for target: WallpaperTarget) {
        var state = snapshot
        let valid = Set(state.videos.map(\.id))
        let pruned = ids.map { $0.filter { valid.contains($0) } }
        if target == .lock, state.sameForBoth {
            let lockEnabled = state.lock.enabled
            state.lock = state.desktop          // the lock screen keeps what it showed so far…
            state.lock.enabled = lockEnabled
            state.sameForBoth = false           // …and from here on goes its own way
        }
        if target == .desktop { state.desktop.playlist = pruned } else { state.lock.playlist = pruned }
        state.normalize()
        guard state != snapshot else { return }
        batch { apply(state) }
    }

    var selectedItem: VideoItem? { videos.first { $0.id == selectedID } }
    var currentIndex: Int? { videos.firstIndex { $0.id == currentID } }
    var canStart: Bool { snapshot.canStart }
    var canRotate: Bool { snapshot.canRotate }
    var intervalSeconds: TimeInterval { snapshot.intervalSeconds }
    var intervalIsClamped: Bool { snapshot.intervalIsClamped }

    let client = ServiceClient.shared
    private var written = LibraryState()           // what state.json last held, revision included
    private var writesSuspended = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var clientWatch: [AnyCancellable] = []

    // Loads state only; bootstrap() starts the first real work.
    init() {}

    // MARK: Lifecycle (called by AppDelegate)

    /// Once, from applicationDidFinishLaunching: reads the library (to show it before the service answers),
    /// checks for a phase-1 copy and connects to the service. Never writes state.json.
    func bootstrap() {
        let loaded = StateStore.loadOrMigrate()
        batch(persisting: false) { apply(loaded.state) }
        written = loaded.state
        focusedID = selectedID
        reanalyzeStaleScenes()
        importedFromPhase1 = loaded.importedCount
        legacyAppRunning = Self.otherInstances().contains { $0.legacy }
        clientWatch = [
            client.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            client.$status.compactMap { $0 }.sink { [weak self] status in self?.statusReceived(status) },
        ]
        observeSystem()
        client.start()
    }

    /// From applicationWillTerminate. Does not stop the service.
    func shutdown() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        clientWatch = []
        client.stop()
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
            if focusedID == nil { focusedID = first.id }
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
            desktopPlaylistIDs = desktopPlaylistIDs?.filter { !ids.contains($0) }
            lockConfig.playlist = lockConfig.playlist?.filter { !ids.contains($0) }
            if selectedItem == nil {
                selectedID = videos.isEmpty ? nil : videos[min(firstIndex, videos.count - 1)].id
            }
            if !videos.contains(where: { $0.id == lockConfig.selectedID }) { lockConfig.selectedID = selectedID }
            if !videos.contains(where: { $0.id == focusedID }) { focusedID = selectedID }
        }
        for item in removed { Self.deleteDownloadedFiles(of: item) }
    }

    func removeAll() {
        remove(ids: Set(videos.map(\.id)))
    }

    // MARK: Playback intents (all go to the service)

    func start() { send(.start(itemID: nil, target: nil)) }   // each target starts with its own selection

    func stop() { send(.stop) }

    /// Starts only `id`, on the targets it is assigned to (desktop, lock screen or both). A wallpaper that is not
    /// assigned anywhere starts on the desktop.
    func startOnly(_ id: VideoItem.ID) {
        guard videos.contains(where: { $0.id == id }) else { return }
        var targets = roles(of: id)
        if targets.isEmpty { targets = [.desktop] }
        play(id, target: targets.count == WallpaperTarget.allCases.count ? nil : targets.first)
    }

    /// True when `id` is what the service shows on the desktop or the lock screen right now.
    func isPlaying(_ id: VideoItem.ID) -> Bool {
        isRunning && (currentID(for: .desktop) == id || currentID(for: .lock) == id)
    }

    func toggleRunning() {
        if isRunning { stop() } else { start() }
    }

    /// Selects `id` for `target` (nil = both) and jumps to it, starting playback if needed.
    func play(_ id: VideoItem.ID, target: WallpaperTarget? = nil) {
        guard videos.contains(where: { $0.id == id }) else { return }
        let targets: Set<WallpaperTarget> = target.map { Set([$0]) } ?? Set(WallpaperTarget.allCases)
        assign(id, to: targets)
        send(.start(itemID: id, target: target))
    }

    /// Terminates the service (`.quit`: it restores Apple's wallpapers first).
    func quitService() { send(.quit) }

    func restartService() { Task { await client.restart() } }

    /// Registers/connects to the service again.
    func startService() { client.start() }

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
        written = state
        send(.commit(state))   // the service writes state.json and bumps the revision
    }

    /// Scenes analysed by an older analyzer get a fresh support verdict (off the main thread; the files are tiny
    /// to read but can be large to scan).
    private func reanalyzeStaleScenes() {
        let stale = videos.filter { ($0.scene?.analysisRevision).map { $0 != SceneAnalysis.revision } ?? false }
        guard !stale.isEmpty else { return }
        Task { @MainActor [weak self] in
            let fresh = await Task.detached(priority: .utility) { stale.map { SceneImporter.reanalyze($0) } }.value
            self?.replace(fresh)
        }
    }

    private func replace(_ items: [VideoItem]) {
        batch {
            for item in items {
                if let index = videos.firstIndex(where: { $0.id == item.id }) { videos[index] = item }
            }
        }
    }

    private func apply(_ state: LibraryState) {
        videos = state.videos
        selectedID = state.selectedID
        rotateEnabled = state.rotateEnabled
        intervalValue = state.intervalValue
        intervalUnit = state.intervalUnit
        applyToDesktop = state.applyToDesktop
        applyToLockScreen = state.applyToLockScreen
        desktopPlaylistIDs = state.desktop.playlist
        sameForBoth = state.sameForBoth
        lockConfig = state.lock
        sceneFPS = state.sceneFPS
        sceneOptions = state.sceneOptions
        power = state.power
        muted = state.muted
    }

    /// Mute toggle: its own command so a stale snapshot can never undo the service menu's toggle.
    private func changeMuted(_ value: Bool) {
        written.muted = value
        send(.setMuted(value))
    }


    private static func deleteDownloadedFiles(of item: VideoItem) {
        let file = item.url.standardizedFileURL
        guard AppPaths.isInsideLibrary(file) else { return }
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: AppPaths.isInsideLibrary(folder) ? folder : file)
    }

    // MARK: Service

    /// Sends a command; a failure shows up as `localMessage`.
    private func send(_ command: ServiceCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.client.perform(command)
                if case .commit = command { self.written.revision = max(self.written.revision, status.stateRevision) }
            } catch {
                self.localMessage = error.localizedDescription
            }
        }
    }

    /// A status arrived (reply or push): the service owns `muted` (its menu can toggle it).
    private func statusReceived(_ status: ServiceStatus) {
        if status.muted != muted { batch(persisting: false) { muted = status.muted } }
    }


    // MARK: Workspace

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let appKey = NSWorkspace.applicationUserInfoKey
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[appKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor [weak self] in
                    if bundleID == AppIdentity.settingsBundleID { self?.legacyAppRunning = Self.otherInstances().contains { $0.legacy } }
                }
            }
            observers.append((workspace, token))
        }
    }

    // MARK: Other processes

    /// Other running copies of this app's bundle id. `legacy`: a phase-1 build (its Info.plist has no LWRole key).
    static func otherInstances() -> [(app: NSRunningApplication, legacy: Bool)] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.settingsBundleID)
            .compactMap { app -> (app: NSRunningApplication, legacy: Bool)? in
                guard app.processIdentifier != me, !app.isTerminated else { return nil }
                let role = app.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: AppIdentity.roleKey)
                return (app, role == nil)
            }
    }
}
