import Foundation
import CoreGraphics
import CoreMedia
import AVFoundation
import UniformTypeIdentifiers

// Shared model, persistence and file locations for both processes (Settings app and wallpaper agent).
// Core never imports SwiftUI, AppKit or Combine, so the agent does not link them.
// Everything other targets touch is `public`, with an explicit public init.

// MARK: - Library items

public struct VideoItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String           // absolute path of the playable file
    public var title: String?         // display title (Workshop items); nil = file name
    public var author: String?
    public var workshopID: String?    // non-nil = downloaded from the Steam Workshop
    public var previewPath: String?   // absolute path of a preview image, if any
    public var tags: [String]?
    /// Non-nil = a Wallpaper Engine scene (schema v2). `path` is then the scene package (`scene.pkg`) or
    /// the folder's `scene.json`, `previewPath` the preview image shown when the scene cannot be rendered.
    public var scene: SceneInfo?

    // Containers the system may not map to a movie type.
    private static let fallbackExtensions: Set<String> =
        ["mp4", "m4v", "mov", "mpg", "mpeg", "avi", "mkv", "webm"]

    // New fields are optional so phase-1 records ({"id","path"}) still decode.
    public init(id: UUID = UUID(), path: String, title: String? = nil, author: String? = nil,
                workshopID: String? = nil, previewPath: String? = nil, tags: [String]? = nil,
                scene: SceneInfo? = nil) {
        self.id = id
        self.path = path
        self.title = title
        self.author = author
        self.workshopID = workshopID
        self.previewPath = previewPath
        self.tags = tags
        self.scene = scene
    }

    public init(url: URL) {
        self.init(path: url.standardizedFileURL.path)
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { title ?? url.deletingPathExtension().lastPathComponent }
    public var isWorkshop: Bool { workshopID != nil }
    public var kind: ItemKind { scene == nil ? .video : .scene }
    public var isScene: Bool { scene != nil }

    public static func isVideo(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .movie) || type.conforms(to: .video) {
            return true
        }
        return fallbackExtensions.contains(ext)
    }
}

public enum IntervalUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case seconds, minutes, hours

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .seconds: return "Seconds"
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        }
    }

    public var multiplier: TimeInterval {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 3600
        }
    }
}

// MARK: - Targets and scenes (schema v2)

/// The two places a wallpaper can be shown. The agent runs one channel per target.
public enum WallpaperTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case desktop, lock

    public var id: String { rawValue }
    public var label: String { self == .desktop ? "Desktop" : "Lock Screen" }
}

public enum ItemKind: String, Codable, Sendable {
    case video, scene
}

/// How much of a scene the engine can show (the badge in the UI). Decided by SceneFormat's analyzer when the
/// scene is imported and stored here, so the UI and the agent never need the SceneFormat module.
public enum SceneSupport: String, Codable, Sendable {
    case full          // everything the scene uses is supported
    case partial       // plays, but some effects, particles, sounds or scripts are ignored
    case previewOnly   // the preview image is shown instead
}

public struct SceneInfo: Codable, Hashable, Sendable {
    public var support: SceneSupport
    public var notes: [String]            // short user-facing reasons, e.g. "Particles are not supported yet."
    public var designWidth: Int           // scene design resolution (orthogonal projection)
    public var designHeight: Int
    public var loopSeconds: Double?       // the scene's own period if the analyzer found one
    public var needsSharedAssets: Bool    // references files that only Wallpaper Engine's shared assets have
    public var analysisRevision: Int      // SceneFormat analyzer revision that produced this record

    public init(support: SceneSupport, notes: [String] = [], designWidth: Int = 1920, designHeight: Int = 1080,
                loopSeconds: Double? = nil, needsSharedAssets: Bool = false, analysisRevision: Int = 1) {
        self.support = support
        self.notes = notes
        self.designWidth = designWidth
        self.designHeight = designHeight
        self.loopSeconds = loopSeconds
        self.needsSharedAssets = needsSharedAssets
        self.analysisRevision = analysisRevision
    }
}

// MARK: - Library + settings (state.json, written only by the Settings app)

/// What one target plays and how it rotates.
public struct TargetConfig: Codable, Equatable, Sendable {
    public var enabled: Bool              // false = this target is left alone (Apple's wallpaper stays)
    public var selectedID: UUID?          // starting / current choice
    public var playlist: [UUID]?          // nil = every library item in library order; else this order
    public var playlistID: UUID?          // the SavedPlaylist `playlist` was applied from (nil = whole library)
    public var rotateEnabled: Bool
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    public var shuffle: Bool              // playlist order is shuffled (a full shuffled pass before any repeat)
    public var changeOnWake: Bool         // also move on when the Mac wakes and when the service starts at login

    public init(enabled: Bool = true, selectedID: UUID? = nil, playlist: [UUID]? = nil, playlistID: UUID? = nil,
                rotateEnabled: Bool = false, intervalValue: Int = 5, intervalUnit: IntervalUnit = .minutes,
                shuffle: Bool = false, changeOnWake: Bool = false) {
        self.shuffle = shuffle
        self.changeOnWake = changeOnWake
        self.enabled = enabled
        self.selectedID = selectedID
        self.playlist = playlist
        self.playlistID = playlistID
        self.rotateEnabled = rotateEnabled
        self.intervalValue = intervalValue
        self.intervalUnit = intervalUnit
    }

    // Files written before shuffle / changeOnWake existed lack those keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        selectedID = try c.decodeIfPresent(UUID.self, forKey: .selectedID)
        playlist = try c.decodeIfPresent([UUID].self, forKey: .playlist)
        playlistID = try c.decodeIfPresent(UUID.self, forKey: .playlistID)
        rotateEnabled = try c.decodeIfPresent(Bool.self, forKey: .rotateEnabled) ?? false
        intervalValue = try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 5
        intervalUnit = try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .minutes
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        changeOnWake = try c.decodeIfPresent(Bool.self, forKey: .changeOnWake) ?? false
    }

    /// The playback rules of this target; a saved playlist's rules are copied here while it is applied.
    public var rules: PlaylistRules {
        get { PlaylistRules(shuffle: shuffle, rotateEnabled: rotateEnabled, intervalValue: intervalValue,
                            intervalUnit: intervalUnit, changeOnWake: changeOnWake) }
        set {
            shuffle = newValue.shuffle
            rotateEnabled = newValue.rotateEnabled
            intervalValue = newValue.intervalValue
            intervalUnit = newValue.intervalUnit
            changeOnWake = newValue.changeOnWake
        }
    }

    public var intervalSeconds: TimeInterval {
        max(LibraryState.minimumInterval, Double(intervalValue) * intervalUnit.multiplier)
    }
    public var intervalIsClamped: Bool {
        Double(intervalValue) * intervalUnit.multiplier < LibraryState.minimumInterval
    }
}

/// How a playlist advances. Owned by the playlist; copied onto each screen that runs it.
public struct PlaylistRules: Codable, Equatable, Sendable {
    public var shuffle: Bool
    public var rotateEnabled: Bool       // advance on a timer
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    public var changeOnWake: Bool        // also advance when the Mac wakes and when the service starts at login

    public init(shuffle: Bool = false, rotateEnabled: Bool = true, intervalValue: Int = 5,
                intervalUnit: IntervalUnit = .minutes, changeOnWake: Bool = false) {
        self.shuffle = shuffle
        self.rotateEnabled = rotateEnabled
        self.intervalValue = intervalValue
        self.intervalUnit = intervalUnit
        self.changeOnWake = changeOnWake
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        rotateEnabled = try c.decodeIfPresent(Bool.self, forKey: .rotateEnabled) ?? true
        intervalValue = LibraryState.clampedInterval(try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 5)
        intervalUnit = try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .minutes
        changeOnWake = try c.decodeIfPresent(Bool.self, forKey: .changeOnWake) ?? false
    }
}

/// A named, ordered set of library wallpapers plus its playback rules, applied to the desktop and/or lock screen.
public struct SavedPlaylist: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var itemIDs: [UUID]
    public var rules: PlaylistRules

    public init(id: UUID = UUID(), name: String, itemIDs: [UUID], rules: PlaylistRules = PlaylistRules()) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
        self.rules = rules
    }

    // v7.0.0 files have no `rules`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        itemIDs = try c.decode([UUID].self, forKey: .itemIDs)
        rules = try c.decodeIfPresent(PlaylistRules.self, forKey: .rules) ?? PlaylistRules()
    }
}

public struct LibraryState: Codable, Equatable, Sendable {
    public static let minimumInterval: TimeInterval = 5
    public static let currentSchema = 2

    public var schema: Int
    public var revision: Int          // bumped by StateStore.commit on every write
    public var videos: [VideoItem]    // the whole library (videos and scenes); the name is a phase-1 leftover
    public var muted: Bool            // default true; changed only through StateStore.setMuted
    public var sceneFPS: Int          // frame rate cap for live scenes; the agent lowers it on battery
    public var sceneZoom: Double      // 1 = as authored; below 1 shows more of the scene (edges go black), above crops in
    public var sameForBoth: Bool      // default true: the lock screen follows the desktop config (except `enabled`)
    public var desktop: TargetConfig
    public var lock: TargetConfig     // ignored apart from `enabled` while sameForBoth
    public var sceneOptions: [String: SceneOptions] = [:]   // per scene, keyed by VideoItem.id.uuidString
    public var power: PowerOptions = PowerOptions()           // global scene settings
    public var playlists: [SavedPlaylist] = []                // named playlists; a target runs one via TargetConfig.playlistID

    public init(schema: Int = LibraryState.currentSchema, revision: Int = 0, videos: [VideoItem] = [],
                muted: Bool = true, sceneFPS: Int = LibraryState.defaultSceneFPS, sceneZoom: Double = 1.0, sameForBoth: Bool = true,
                desktop: TargetConfig = TargetConfig(), lock: TargetConfig = TargetConfig()) {
        self.schema = schema
        self.revision = revision
        self.videos = videos
        self.muted = muted
        self.sceneFPS = LibraryState.clampedSceneFPS(sceneFPS)
        self.sceneZoom = LibraryState.clampedSceneZoom(sceneZoom)
        self.sameForBoth = sameForBoth
        self.desktop = desktop
        self.lock = lock
    }

    public static let defaultSceneFPS = 30
    public static func clampedSceneFPS(_ fps: Int) -> Int { min(max(fps, 10), 120) }
    public static func clampedSceneZoom(_ zoom: Double) -> Double { min(max(zoom, 0.5), 2.0) }

    // MARK: Codable with v1 migration (schema 1 files have no desktop/lock sections)

    private enum CodingKeys: String, CodingKey {
        case schema, revision, videos, muted, sceneFPS, sceneZoom, sameForBoth, desktop, lock, sceneOptions, power, playlists
        // schema 1 only
        case selectedID, rotateEnabled, intervalValue, intervalUnit, applyToDesktop, applyToLockScreen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let diskSchema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        videos = try c.decodeIfPresent([VideoItem].self, forKey: .videos) ?? []
        schema = LibraryState.currentSchema
        sceneFPS = LibraryState.clampedSceneFPS(try c.decodeIfPresent(Int.self, forKey: .sceneFPS) ?? Self.defaultSceneFPS)
        sceneZoom = LibraryState.clampedSceneZoom(try c.decodeIfPresent(Double.self, forKey: .sceneZoom) ?? 1.0)
        sceneOptions = try c.decodeIfPresent([String: SceneOptions].self, forKey: .sceneOptions) ?? [:]
        power = try c.decodeIfPresent(PowerOptions.self, forKey: .power) ?? PowerOptions()
        playlists = try c.decodeIfPresent([SavedPlaylist].self, forKey: .playlists) ?? []
        if diskSchema >= 2 || c.contains(.desktop) {
            muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true
            sameForBoth = try c.decodeIfPresent(Bool.self, forKey: .sameForBoth) ?? true
            desktop = try c.decodeIfPresent(TargetConfig.self, forKey: .desktop) ?? TargetConfig()
            lock = try c.decodeIfPresent(TargetConfig.self, forKey: .lock) ?? TargetConfig()
        } else {
            // v1: one selection / rotation setting and two "apply to" flags become a shared config.
            let selected = try c.decodeIfPresent(UUID.self, forKey: .selectedID)
            let rotate = try c.decodeIfPresent(Bool.self, forKey: .rotateEnabled) ?? true
            let value = try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 5
            let unit = try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .minutes
            let onDesktop = try c.decodeIfPresent(Bool.self, forKey: .applyToDesktop) ?? true
            let onLock = try c.decodeIfPresent(Bool.self, forKey: .applyToLockScreen) ?? true
            muted = true
            sameForBoth = true
            desktop = TargetConfig(enabled: onDesktop, selectedID: selected, rotateEnabled: rotate,
                                   intervalValue: value, intervalUnit: unit)
            lock = TargetConfig(enabled: onLock, selectedID: selected, rotateEnabled: rotate,
                                intervalValue: value, intervalUnit: unit)
        }
        desktop.intervalValue = LibraryState.clampedInterval(desktop.intervalValue)
        lock.intervalValue = LibraryState.clampedInterval(lock.intervalValue)
        adoptUnnamedPlaylists()
        normalize()
    }

    private static let desktopPlaylistUUID = UUID(uuidString: "6D1E0A52-7B1B-4C55-9E55-0D5E5C0A0001")!
    private static let lockPlaylistUUID = UUID(uuidString: "6D1E0A52-7B1B-4C55-9E55-0D5E5C0A0002")!

    /// A screen that has a curated list from before playlists were named becomes a saved playlist, with that
    /// screen's rotation settings as its rules. Fixed ids, so the app and the service decode the same one.
    private mutating func adoptUnnamedPlaylists() {
        if let ids = desktop.playlist, desktop.playlistID == nil {
            playlists.append(SavedPlaylist(id: Self.desktopPlaylistUUID, name: "Desktop Playlist",
                                           itemIDs: ids, rules: desktop.rules))
            desktop.playlistID = Self.desktopPlaylistUUID
        }
        if !sameForBoth, let ids = lock.playlist, lock.playlistID == nil {
            playlists.append(SavedPlaylist(id: Self.lockPlaylistUUID, name: "Lock Screen Playlist",
                                           itemIDs: ids, rules: lock.rules))
            lock.playlistID = Self.lockPlaylistUUID
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(revision, forKey: .revision)
        try c.encode(videos, forKey: .videos)
        try c.encode(muted, forKey: .muted)
        try c.encode(sceneFPS, forKey: .sceneFPS)
        try c.encode(sceneZoom, forKey: .sceneZoom)
        try c.encode(sceneOptions, forKey: .sceneOptions)
        try c.encode(power, forKey: .power)
        try c.encode(playlists, forKey: .playlists)
        try c.encode(sameForBoth, forKey: .sameForBoth)
        try c.encode(desktop, forKey: .desktop)
        try c.encode(lock, forKey: .lock)
    }

    // MARK: Per-target reads

    /// The config that actually applies to `target` (the lock screen mirrors the desktop while sameForBoth,
    /// but keeps its own `enabled`).
    public func config(for target: WallpaperTarget) -> TargetConfig {
        switch target {
        case .desktop:
            return desktop
        case .lock:
            guard sameForBoth else { return lock }
            var shared = desktop
            shared.enabled = lock.enabled
            return shared
        }
    }

    /// True when `id` is a library scene (a live-rendered Wallpaper Engine wallpaper).
    public func isScene(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return videos.first { $0.id == id }?.isScene == true
    }

    /// The items `target` rotates through: the playlist (ids that no longer exist are skipped) or the library.
    /// A scene on the lock screen is rendered into a video loop by the service first.
    public func items(for target: WallpaperTarget) -> [VideoItem] {
        guard let ids = config(for: target).playlist else { return videos }
        return ids.compactMap { id in videos.first { $0.id == id } }
    }

    public func selectedItem(for target: WallpaperTarget) -> VideoItem? {
        let id = config(for: target).selectedID
        return items(for: target).first { $0.id == id }
    }

    public func isEnabled(_ target: WallpaperTarget) -> Bool { config(for: target).enabled }
    /// The target is enabled and has something to play.
    public func canPlay(_ target: WallpaperTarget) -> Bool { isEnabled(target) && !items(for: target).isEmpty }
    public func hasMultipleItems(_ target: WallpaperTarget) -> Bool { items(for: target).count > 1 }
    /// Rotation only ever cycles a playlist the user curated. Without one, the selected wallpaper stays.
    public func rotates(_ target: WallpaperTarget) -> Bool {
        let config = config(for: target)
        return config.playlist != nil && config.rotateEnabled && hasMultipleItems(target)
    }
    public func interval(for target: WallpaperTarget) -> TimeInterval { config(for: target).intervalSeconds }
    /// Shuffle applies to a curated playlist only.
    public func shuffles(_ target: WallpaperTarget) -> Bool {
        let config = config(for: target)
        return config.playlist != nil && config.shuffle
    }
    /// The target moves on when the Mac wakes or the service starts at login.
    public func advancesOnWake(_ target: WallpaperTarget) -> Bool {
        let config = config(for: target)
        return config.playlist != nil && config.changeOnWake && hasMultipleItems(target)
    }

    /// The targets for which `id` is the selected item and the target is enabled (drives the role badges).
    public func targets(of id: UUID) -> Set<WallpaperTarget> {
        Set(WallpaperTarget.allCases.filter {
            isEnabled($0) && config(for: $0).selectedID == id
        })
    }

    /// Something can be played: a non-empty library and at least one enabled target.
    public var canStart: Bool { !videos.isEmpty && (desktop.enabled || lock.enabled) }
    /// True when any startable target has a scene as its selected item (the scene host is needed).
    public var usesScenes: Bool {
        WallpaperTarget.allCases.contains { canPlay($0) && selectedItem(for: $0)?.isScene == true }
    }

    // MARK: Per-target writes

    /// Makes `lock` mirror `desktop` (keeping its own `enabled`) while sameForBoth. Idempotent.
    public mutating func normalize() {
        guard sameForBoth else { return }
        let enabled = lock.enabled
        lock = desktop
        lock.enabled = enabled
    }

    /// "Set as Desktop / Lock Screen / Both". Selecting the item for one target only turns "same for both" off
    /// (the other target keeps what it had); selecting it for both turns it on. The chosen
    /// targets are enabled. An id that is not in the library is ignored.
    public mutating func assign(_ id: UUID, to requested: Set<WallpaperTarget>) {
        let targets = requested
        guard !targets.isEmpty, videos.contains(where: { $0.id == id }) else { return }
        if targets.count == 1, sameForBoth {
            normalize()
            sameForBoth = false      // lock now keeps its own copy of the shared config
        }
        if targets.count == WallpaperTarget.allCases.count { sameForBoth = true }
        if targets.contains(.desktop) {
            desktop.selectedID = id
            desktop.enabled = true
        }
        if targets.contains(.lock) {
            lock.selectedID = id
            lock.enabled = true
        }
        normalize()
    }

    // MARK: Saved playlists

    /// Creates or updates `list` (unknown library ids dropped). Targets already running it pick up the change.
    public mutating func savePlaylist(_ list: SavedPlaylist) {
        var list = list
        let valid = Set(videos.map(\.id))
        list.itemIDs = list.itemIDs.filter { valid.contains($0) }
        if let index = playlists.firstIndex(where: { $0.id == list.id }) { playlists[index] = list } else { playlists.append(list) }
        for target in WallpaperTarget.allCases where config(for: target).playlistID == list.id { use(list, on: target) }
        normalize()
    }

    /// Deletes `id`; targets that ran it go back to the whole library.
    public mutating func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        for target in WallpaperTarget.allCases where config(for: target).playlistID == id { use(nil, on: target) }
        normalize()
    }

    /// Runs saved playlist `id` (nil = the whole library) on `requested`, enabling those targets. Like `assign`,
    /// choosing one target separates it from the other; choosing both turns "same for both" on.
    public mutating func applyPlaylist(_ id: UUID?, to requested: Set<WallpaperTarget>) {
        let list = id.flatMap { id in playlists.first { $0.id == id } }
        guard !requested.isEmpty, id == nil || list != nil else { return }
        if requested.count == 1, sameForBoth {
            normalize()
            sameForBoth = false
        }
        if requested.count == WallpaperTarget.allCases.count { sameForBoth = true }
        for target in requested {
            use(list, on: target)
            update(target) { $0.enabled = true }
        }
        normalize()
    }

    private mutating func update(_ target: WallpaperTarget, _ change: (inout TargetConfig) -> Void) {
        if target == .desktop { change(&desktop) } else { change(&lock) }
    }

    private mutating func use(_ list: SavedPlaylist?, on target: WallpaperTarget) {
        update(target) { config in
            config.playlistID = list?.id
            config.playlist = list?.itemIDs
            if let list { config.rules = list.rules }
            if let ids = list?.itemIDs, !ids.contains(where: { $0 == config.selectedID }) { config.selectedID = ids.first }
        }
    }

    // MARK: Phase-2 accessors (the desktop config, shared with the lock screen while sameForBoth)
    // Kept so the phase-2 call sites compile unchanged; new code uses config(for:) and assign(_:to:).

    public var selectedID: UUID? {
        get { desktop.selectedID }
        set { desktop.selectedID = newValue; if sameForBoth { lock.selectedID = newValue } }
    }
    public var rotateEnabled: Bool {
        get { desktop.rotateEnabled }
        set { desktop.rotateEnabled = newValue; if sameForBoth { lock.rotateEnabled = newValue } }
    }
    public var intervalValue: Int {
        get { desktop.intervalValue }
        set { desktop.intervalValue = newValue; if sameForBoth { lock.intervalValue = newValue } }
    }
    public var intervalUnit: IntervalUnit {
        get { desktop.intervalUnit }
        set { desktop.intervalUnit = newValue; if sameForBoth { lock.intervalUnit = newValue } }
    }
    public var applyToDesktop: Bool {
        get { desktop.enabled }
        set { desktop.enabled = newValue }
    }
    public var applyToLockScreen: Bool {
        get { lock.enabled }
        set { lock.enabled = newValue }
    }
    public var selectedItem: VideoItem? { selectedItem(for: .desktop) }
    public var canRotate: Bool { hasMultipleItems(.desktop) }
    public var rotationActive: Bool { rotates(.desktop) }
    public var intervalSeconds: TimeInterval { desktop.intervalSeconds }
    public var intervalIsClamped: Bool { desktop.intervalIsClamped }

    public static func clampedInterval(_ value: Int) -> Int {
        min(max(value, 1), 999)
    }
}

// MARK: - File locations

public enum AppPaths {
    private static let applicationSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// ~/Library/Application Support/LiveWallpaper
    public static let supportDirectory = applicationSupport
        .appendingPathComponent("LiveWallpaper", isDirectory: true)
    public static let stateFile = supportDirectory.appendingPathComponent("state.json")
    public static let agentFile = supportDirectory.appendingPathComponent("agent.json")
    /// Imported Workshop items: Library/<workshop id>/<video, preview, project.json>.
    public static let libraryDirectory = supportDirectory.appendingPathComponent("Library", isDirectory: true)
    /// Apple's original Aerial files while ours stand in for them.
    public static let backupsDirectory = supportDirectory.appendingPathComponent("Backups", isDirectory: true)
    public static let stillsDirectory = supportDirectory.appendingPathComponent("Stills", isDirectory: true)
    /// Where Apple keeps downloaded Aerial videos.
    public static let aerialVideosDirectory = applicationSupport
        .appendingPathComponent("com.apple.wallpaper/aerials/videos", isDirectory: true)
    /// Transient steamcmd download area. No spaces in the path on purpose (steamcmd argument parsing).
    public static let steamStagingDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveWallpaperSteam", isDirectory: true)

    /// Where the app installs Valve's SteamCMD itself (downloaded on first use, never bundled).
    public static let steamToolsDirectory = supportDirectory.appendingPathComponent("SteamCMD", isDirectory: true)
    /// HOME for the app's own SteamCMD runs, so its cached login lives here and nowhere else (UNVERIFIED that
    /// SteamCMD honours HOME on macOS, see SPEC3.md section 4).
    public static let steamHomeDirectory = supportDirectory.appendingPathComponent("SteamHome", isDirectory: true)
    /// Wallpaper Engine's shared assets, fetched with the user's own account (optional, SPEC3.md section 4.8).
    public static let sharedAssetsDirectory = supportDirectory
        .appendingPathComponent("WallpaperEngineAssets", isDirectory: true)

    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// True when `url` lies inside the imported-Workshop library folder (the only files the app may delete).
    public static func isInsideLibrary(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(libraryDirectory.standardizedFileURL.path + "/")
    }
}

// MARK: - State store

public enum StateStore {
    public static let phase1DefaultsKey = "LiveWallpaper.state.v1"
    private static let importedFlagKey = "LiveWallpaper.v2.importedPhase1"

    /// Reads state.json (schema 1 files are migrated in memory). Returns nil if it is missing; an unreadable file
    /// is moved aside (never overwritten).
    public static func load() -> LibraryState? {
        guard let data = try? Data(contentsOf: AppPaths.stateFile) else { return nil }
        if let state = try? JSONDecoder().decode(LibraryState.self, from: data) { return state }
        let aside = AppPaths.supportDirectory
            .appendingPathComponent("state.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: AppPaths.stateFile, to: aside)
        return nil
    }

    /// The `schema` number inside state.json as written (1 for a file without one); nil when there is no file.
    public static func diskSchema() -> Int? {
        guard let data = try? Data(contentsOf: AppPaths.stateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["schema"] as? Int ?? 1
    }

    /// Writes state.json atomically and bumps `state.revision` past anything already on disk.
    /// Settings app only. `muted` is not changed by a commit: the value on disk wins (it is changed only by
    /// `setMuted`, which the agent's menu also uses). Returns false if the file could not be written.
    @discardableResult
    public static func commit(_ state: inout LibraryState) -> Bool {
        let onDisk = load()
        if let onDisk { state.muted = onDisk.muted }
        state.revision = max(state.revision, onDisk?.revision ?? 0) + 1
        state.schema = LibraryState.currentSchema
        state.normalize()
        return write(state)
    }

    /// The only write besides `commit`: changes `muted` in state.json (read, change, write, revision + 1).
    /// May be called from the Settings app and from the agent. Returns the written state, nil on failure.
    @discardableResult
    public static func setMuted(_ muted: Bool) -> LibraryState? {
        var state = load() ?? LibraryState()
        guard state.muted != muted || diskSchema() == nil else { return state }
        state.muted = muted
        state.revision += 1
        return write(state) ? state : nil
    }

    private static func write(_ state: LibraryState) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return false }
        do {
            try AppPaths.ensureDirectory(AppPaths.supportDirectory)
            try data.write(to: AppPaths.stateFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Settings app only: loads state.json (rewriting a schema 1 file as schema 2 once, after keeping a copy as
    /// state.v1-backup.json), or imports the phase-1 library from its UserDefaults once
    /// (the Settings app has the phase-1 bundle id, so `.standard` is the phase-1 domain).
    public static func loadOrMigrate(defaults: UserDefaults = .standard) -> (state: LibraryState, importedCount: Int) {
        if var state = load() {
            if let schema = diskSchema(), schema < LibraryState.currentSchema {
                let backup = AppPaths.supportDirectory.appendingPathComponent("state.v1-backup.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.copyItem(at: AppPaths.stateFile, to: backup)
                }
                commit(&state)
            }
            return (state, 0)
        }
        var state = LibraryState()
        var imported = 0
        if !defaults.bool(forKey: importedFlagKey),
           let data = defaults.data(forKey: phase1DefaultsKey),
           let old = try? JSONDecoder().decode(Phase1State.self, from: data) {
            let value = LibraryState.clampedInterval(old.intervalValue)
            state = LibraryState(
                videos: old.videos,
                desktop: TargetConfig(enabled: old.applyToDesktop, selectedID: old.selectedID,
                                      rotateEnabled: old.rotateEnabled, intervalValue: value,
                                      intervalUnit: old.intervalUnit),
                lock: TargetConfig(enabled: old.applyToLockScreen, selectedID: old.selectedID,
                                   rotateEnabled: old.rotateEnabled, intervalValue: value,
                                   intervalUnit: old.intervalUnit))
            imported = old.videos.count
        }
        defaults.set(true, forKey: importedFlagKey)
        commit(&state)
        return (state, imported)
    }

    // Shape of the phase-1 UserDefaults blob (LiveWallpaper.state.v1).
    private struct Phase1State: Decodable {
        var videos: [VideoItem]
        var selectedID: UUID?
        var rotateEnabled: Bool
        var intervalValue: Int
        var intervalUnit: IntervalUnit
        var applyToDesktop: Bool
        var applyToLockScreen: Bool
    }
}

// MARK: - Agent record (agent.json, written only by the agent)

/// A desktop picture the agent replaced with a still (macOS 13 to 15 lock screen path).
public struct OriginalWallpaper: Codable, Equatable, Sendable {
    public var url: String
    public var scaling: UInt
    public var allowClipping: Bool

    public init(url: String, scaling: UInt, allowClipping: Bool) {
        self.url = url
        self.scaling = scaling
        self.allowClipping = allowClipping
    }
}

public struct AgentRecord: Codable, Equatable, Sendable {
    public var wantsRunning: Bool                      // resume playing when the agent launches
    public var aerialSlots: [String]                   // Aerial files our video stands in for
    public var originals: [String: OriginalWallpaper]  // display id -> desktop picture before a still
    public var legacyImported: Bool

    public init(wantsRunning: Bool = false, aerialSlots: [String] = [],
                originals: [String: OriginalWallpaper] = [:], legacyImported: Bool = false) {
        self.wantsRunning = wantsRunning
        self.aerialSlots = aerialSlots
        self.originals = originals
        self.legacyImported = legacyImported
    }
}

public enum AgentRecordStore {
    private static let legacyDomain = "com.noob3301.LiveWallpaper"

    /// Never fails. The first call without agent.json imports the phase-1 records (wasRunning, aerial backup,
    /// originals) from the old app's preferences domain, which the old app never clears on its own.
    public static func load() -> AgentRecord {
        if let data = try? Data(contentsOf: AppPaths.agentFile) {
            if let record = try? JSONDecoder().decode(AgentRecord.self, from: data) { return record }
            let aside = AppPaths.supportDirectory
                .appendingPathComponent("agent.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: AppPaths.agentFile, to: aside)
        }
        var record = AgentRecord()
        record.legacyImported = true
        if let data = legacyData("LiveWallpaper.aerialBackup.v1"),
           let backup = try? JSONDecoder().decode(LegacyBackup.self, from: data) {
            record.aerialSlots = backup.slots
        }
        if let data = legacyData("LiveWallpaper.originals.v1"),
           let originals = try? JSONDecoder().decode([String: OriginalWallpaper].self, from: data) {
            record.originals = originals
        }
        if let data = legacyData("LiveWallpaper.state.v1"),
           let running = try? JSONDecoder().decode(LegacyRunning.self, from: data) {
            record.wantsRunning = running.wasRunning ?? false
        }
        save(record)
        return record
    }

    public static func save(_ record: AgentRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? AppPaths.ensureDirectory(AppPaths.supportDirectory)
        try? data.write(to: AppPaths.agentFile, options: .atomic)
    }

    public static func update(_ body: (inout AgentRecord) -> Void) {
        var record = load()
        body(&record)
        save(record)
    }

    /// Originals waiting in Backups/. Restoring from this listing works even when no record survived,
    /// so Apple's files cannot be stranded by a lost or unreadable record.
    public static func backupSlotsOnDisk() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.backupsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "mov" }.map(\.lastPathComponent).sorted()
    }

    private static func legacyData(_ key: String) -> Data? {
        CFPreferencesCopyAppValue(key as CFString, legacyDomain as CFString) as? Data
    }

    // Phase 1 recorded a single `slot` before it recorded `slots`.
    private struct LegacyBackup: Decodable {
        var slots: [String]

        private enum CodingKeys: String, CodingKey { case slots, slot }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            slots = try container.decodeIfPresent([String].self, forKey: .slots)
                ?? [container.decode(String.self, forKey: .slot)]
        }
    }

    private struct LegacyRunning: Decodable { var wasRunning: Bool? }
}

// MARK: - Frame extraction

public enum VideoStills {
    /// A still from `url` (frame at min(1 s, duration / 2), transform applied); nil on failure.
    /// `maxPixelSize` nil = native size. Runs off the main actor.
    public static func cgImage(for url: URL, maxPixelSize: CGSize?) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize { generator.maximumSize = maxPixelSize }
        let seconds = duration.seconds
        let time = CMTime(seconds: seconds.isFinite ? min(1, seconds / 2) : 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
