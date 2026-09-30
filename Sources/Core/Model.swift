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

    // Containers the system may not map to a movie type.
    private static let fallbackExtensions: Set<String> =
        ["mp4", "m4v", "mov", "mpg", "mpeg", "avi", "mkv", "webm"]

    // New fields are optional so phase-1 records ({"id","path"}) still decode.
    public init(id: UUID = UUID(), path: String, title: String? = nil, author: String? = nil,
                workshopID: String? = nil, previewPath: String? = nil, tags: [String]? = nil) {
        self.id = id
        self.path = path
        self.title = title
        self.author = author
        self.workshopID = workshopID
        self.previewPath = previewPath
        self.tags = tags
    }

    public init(url: URL) {
        self.init(path: url.standardizedFileURL.path)
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { title ?? url.deletingPathExtension().lastPathComponent }
    public var isWorkshop: Bool { workshopID != nil }

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

// MARK: - Library + settings (state.json, written only by the Settings app)

public struct LibraryState: Codable, Equatable, Sendable {
    public static let minimumInterval: TimeInterval = 5

    public var schema: Int
    public var revision: Int          // bumped by StateStore.commit on every write
    public var videos: [VideoItem]
    public var selectedID: UUID?
    public var rotateEnabled: Bool
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    public var applyToDesktop: Bool
    public var applyToLockScreen: Bool

    public init(schema: Int = 1, revision: Int = 0, videos: [VideoItem] = [], selectedID: UUID? = nil,
                rotateEnabled: Bool = true, intervalValue: Int = 5, intervalUnit: IntervalUnit = .minutes,
                applyToDesktop: Bool = true, applyToLockScreen: Bool = true) {
        self.schema = schema
        self.revision = revision
        self.videos = videos
        self.selectedID = selectedID
        self.rotateEnabled = rotateEnabled
        self.intervalValue = intervalValue
        self.intervalUnit = intervalUnit
        self.applyToDesktop = applyToDesktop
        self.applyToLockScreen = applyToLockScreen
    }

    public var selectedItem: VideoItem? { videos.first { $0.id == selectedID } }
    public var canStart: Bool { !videos.isEmpty && (applyToDesktop || applyToLockScreen) }
    public var canRotate: Bool { videos.count > 1 }
    public var rotationActive: Bool { rotateEnabled && canRotate }
    public var intervalSeconds: TimeInterval {
        max(Self.minimumInterval, Double(intervalValue) * intervalUnit.multiplier)
    }
    public var intervalIsClamped: Bool {
        Double(intervalValue) * intervalUnit.multiplier < Self.minimumInterval
    }

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

    /// Reads state.json. Returns nil if it is missing; an unreadable file is moved aside (never overwritten).
    public static func load() -> LibraryState? {
        guard let data = try? Data(contentsOf: AppPaths.stateFile) else { return nil }
        if let state = try? JSONDecoder().decode(LibraryState.self, from: data) { return state }
        let aside = AppPaths.supportDirectory
            .appendingPathComponent("state.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: AppPaths.stateFile, to: aside)
        return nil
    }

    /// Writes state.json atomically and bumps `state.revision` past anything already on disk.
    /// Settings app only. Returns false if the file could not be written.
    @discardableResult
    public static func commit(_ state: inout LibraryState) -> Bool {
        let onDisk = load()?.revision ?? 0
        state.revision = max(state.revision, onDisk) + 1
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

    /// Settings app only: loads state.json, or imports the phase-1 library from its UserDefaults once
    /// (the Settings app has the phase-1 bundle id, so `.standard` is the phase-1 domain).
    public static func loadOrMigrate(defaults: UserDefaults = .standard) -> (state: LibraryState, importedCount: Int) {
        if let state = load() { return (state, 0) }
        var state = LibraryState()
        var imported = 0
        if !defaults.bool(forKey: importedFlagKey),
           let data = defaults.data(forKey: phase1DefaultsKey),
           let old = try? JSONDecoder().decode(Phase1State.self, from: data) {
            state = LibraryState(videos: old.videos, selectedID: old.selectedID,
                                 rotateEnabled: old.rotateEnabled,
                                 intervalValue: LibraryState.clampedInterval(old.intervalValue),
                                 intervalUnit: old.intervalUnit,
                                 applyToDesktop: old.applyToDesktop, applyToLockScreen: old.applyToLockScreen)
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
