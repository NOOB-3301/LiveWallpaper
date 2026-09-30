import Foundation
import Combine
import UniformTypeIdentifiers

struct VideoItem: Identifiable, Codable, Hashable {
    let id: UUID
    let path: String

    // Containers the system may not map to a movie type.
    private static let fallbackExtensions: Set<String> =
        ["mp4", "m4v", "mov", "mpg", "mpeg", "avi", "mkv", "webm"]

    init(url: URL) {
        self.id = UUID()
        self.path = url.standardizedFileURL.path
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }

    static func isVideo(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .movie) || type.conforms(to: .video) {
            return true
        }
        return fallbackExtensions.contains(ext)
    }
}

enum IntervalUnit: String, CaseIterable, Identifiable, Codable {
    case seconds, minutes, hours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .seconds: return "Seconds"
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        }
    }

    var multiplier: TimeInterval {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 3600
        }
    }
}

private struct PersistedState: Codable {
    var videos: [VideoItem]
    var selectedID: VideoItem.ID?
    var rotateEnabled: Bool
    var intervalValue: Int
    var intervalUnit: IntervalUnit
    var applyToDesktop: Bool
    var applyToLockScreen: Bool
    var wasRunning: Bool
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let minimumInterval: TimeInterval = 5
    private static let defaultsKey = "LiveWallpaper.state.v1"

    @Published var videos: [VideoItem] = [] { didSet { videosDidChange(from: oldValue) } }
    @Published var selectedID: VideoItem.ID? = nil { didSet { persist() } }
    @Published var rotateEnabled: Bool = true { didSet { rotationSettingsDidChange() } }
    @Published var intervalValue: Int = 5 {
        didSet {
            let clamped = Self.clampedInterval(intervalValue)
            if clamped != intervalValue { intervalValue = clamped }
            rotationSettingsDidChange()
        }
    }
    @Published var intervalUnit: IntervalUnit = .minutes { didSet { rotationSettingsDidChange() } }
    @Published var applyToDesktop: Bool = true { didSet { targetsDidChange(lockChanged: false) } }
    @Published var applyToLockScreen: Bool = true { didSet { targetsDidChange(lockChanged: true) } }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var currentID: VideoItem.ID? = nil
    @Published private(set) var failedIDs: Set<VideoItem.ID> = []
    @Published private(set) var statusMessage: String? = nil

    private let windows: WallpaperWindowManager
    private let lock: LockScreenWallpaper
    private var rotationTimer: Timer?
    private var activity: NSObjectProtocol?
    private var wasRunning = false { didSet { persist() } }

    var selectedItem: VideoItem? { videos.first { $0.id == selectedID } }
    var currentIndex: Int? { videos.firstIndex { $0.id == currentID } }
    var canStart: Bool { !videos.isEmpty && (applyToDesktop || applyToLockScreen) }
    var canRotate: Bool { videos.count > 1 }
    var intervalSeconds: TimeInterval {
        max(Self.minimumInterval, Double(intervalValue) * intervalUnit.multiplier)
    }
    var intervalIsClamped: Bool {
        Double(intervalValue) * intervalUnit.multiplier < Self.minimumInterval
    }

    // Loads state only; bootstrap() starts the first real work.
    init() {
        windows = WallpaperWindowManager()
        lock = LockScreenWallpaper()
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        wasRunning = state.wasRunning
        videos = state.videos
        selectedID = state.selectedID
        rotateEnabled = state.rotateEnabled
        intervalValue = Self.clampedInterval(state.intervalValue)
        intervalUnit = state.intervalUnit
        applyToDesktop = state.applyToDesktop
        applyToLockScreen = state.applyToLockScreen
    }

    // MARK: Intents

    func bootstrap() {
        windows.onPlaybackFailure = { [weak self] url in self?.playbackFailed(url) }
        if wasRunning, canStart {
            start()
        } else {
            wasRunning = false
            lock.restore()
        }
    }

    @discardableResult func addVideos(urls: [URL]) -> Int {
        var knownPaths = Set(videos.map(\.path))
        var added: [VideoItem] = []
        for url in urls where VideoItem.isVideo(url) {
            let item = VideoItem(url: url)
            if knownPaths.insert(item.path).inserted { added.append(item) }
        }
        guard let first = added.first else { return 0 }
        videos += added
        if selectedItem == nil { selectedID = first.id }
        return added.count
    }

    func remove(ids: Set<VideoItem.ID>) {
        guard let firstIndex = videos.firstIndex(where: { ids.contains($0.id) }) else { return }
        videos.removeAll { ids.contains($0.id) }
        if selectedItem == nil {
            selectedID = videos.isEmpty ? nil : videos[min(firstIndex, videos.count - 1)].id
        }
    }

    func removeAll() {
        remove(ids: Set(videos.map(\.id)))
    }

    func start() {
        guard !isRunning, canStart else { return }
        statusMessage = nil
        failedIDs = []
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Playing live wallpaper")
        wasRunning = true
        applyItem(startingAt: videos.firstIndex(where: { $0.id == selectedID }) ?? 0)
    }

    func stop() {
        teardown()
        statusMessage = nil
        wasRunning = false
    }

    func toggleRunning() {
        if isRunning { stop() } else { start() }
    }

    func play(_ id: VideoItem.ID) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        selectedID = id
        if isRunning { applyItem(startingAt: index) } else { start() }
    }

    func next() {
        guard isRunning, canRotate else { return }
        applyItem(startingAt: (currentIndex ?? -1) + 1)
    }

    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
        windows.setPaused(isPaused)
        scheduleRotation()
    }

    func clearStatus() {
        statusMessage = nil
    }

    // Keeps the persisted wasRunning so the next launch resumes.
    func shutdown() {
        teardown()
    }

    // MARK: Observers

    private func videosDidChange(from old: [VideoItem]) {
        failedIDs.formIntersection(videos.map(\.id))
        persist()
        guard isRunning else { return }
        guard !videos.isEmpty else { stop(); return }
        if currentIndex == nil {
            // The current video was removed: continue with whatever now sits at its index.
            let oldIndex = old.firstIndex { $0.id == currentID } ?? 0
            applyItem(startingAt: min(oldIndex, videos.count))
        } else if (old.count > 1) != canRotate {
            scheduleRotation()
        }
    }

    private func rotationSettingsDidChange() {
        persist()
        scheduleRotation()
    }

    private func targetsDidChange(lockChanged: Bool) {
        persist()
        guard isRunning, let url = currentURL else { return }
        guard applyToDesktop || applyToLockScreen else { stop(); return }
        if lockChanged { applyLock(url) } else { applyDesktop(url) }
    }

    private func playbackFailed(_ url: URL) {
        guard isRunning, let item = videos.first(where: { $0.path == url.path }) else { return }
        failedIDs.insert(item.id)
        if item.id == currentID { applyItem(startingAt: (currentIndex ?? -1) + 1) }
    }

    // MARK: Applying

    private var currentURL: URL? { currentIndex.map { videos[$0].url } }

    private static func clampedInterval(_ value: Int) -> Int {
        min(max(value, 1), 999)
    }

    // Applies the first playable video at or after `start` (wrapping), then restarts the rotation timer.
    private func applyItem(startingAt start: Int) {
        guard let index = firstPlayableIndex(from: start) else {
            stop()
            statusMessage = "None of your videos can be played."
            return
        }
        let url = videos[index].url
        currentID = videos[index].id
        applyDesktop(url)
        applyLock(url)
        scheduleRotation()
    }

    private func firstPlayableIndex(from start: Int) -> Int? {
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
        if applyToDesktop {
            windows.show(url: url)
            windows.setPaused(isPaused)
        } else {
            windows.hide()
        }
    }

    private func applyLock(_ url: URL) {
        guard applyToLockScreen else {
            lock.restore()
            return
        }
        Task {
            do {
                try await self.lock.apply(from: url)
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    private func teardown() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        windows.hide()
        lock.restore()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        isRunning = false
        isPaused = false
        currentID = nil
    }

    private func scheduleRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard isRunning, !isPaused, rotateEnabled, canRotate else { return }
        let interval = intervalSeconds
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
        }
        timer.tolerance = min(interval * 0.1, 5)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func persist() {
        let state = PersistedState(
            videos: videos, selectedID: selectedID, rotateEnabled: rotateEnabled,
            intervalValue: intervalValue, intervalUnit: intervalUnit,
            applyToDesktop: applyToDesktop, applyToLockScreen: applyToLockScreen,
            wasRunning: wasRunning)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
