import Foundation

// Messages between the UI (PaperFlow.app) and the background service (PaperFlowService), carried as JSON
// over the Unix socket in ServiceSocket.swift. The service is the only writer of state.json and does all rendering;
// the UI sends commands and shows status.

/// What the UI asks the service to do. One command per call; the reply carries the resulting status.
public enum ServiceCommand: Codable, Equatable, Sendable {
    /// The UI's edited library and settings. The service merges `muted` from its own copy, writes state.json
    /// (bumping the revision) and reconciles playback. Replaces today's "Settings writes state.json + .reload".
    case commit(LibraryState)
    case start(itemID: UUID?, target: WallpaperTarget?)   // begin playback (item, else the selection)
    case stop                                             // stop and restore the system wallpapers
    case pause
    case resume
    case next(target: WallpaperTarget?)
    case setMuted(Bool)
    case quit                                             // stop, restore, terminate the service
    case status                                           // no-op: just reply with the current status
}

/// What the service reports back after every command and whenever playback changes.
public struct ServiceStatus: Codable, Equatable, Sendable {
    public enum Playback: String, Codable, Sendable { case stopped, playing, paused }

    public struct Slot: Codable, Equatable, Sendable {
        public var target: WallpaperTarget
        public var itemID: UUID?          // what is on screen for this target, nil when nothing is
        public var error: String?         // user-facing reason the item could not play
        public init(target: WallpaperTarget, itemID: UUID? = nil, error: String? = nil) {
            self.target = target
            self.itemID = itemID
            self.error = error
        }
    }

    public var playback: Playback
    public var slots: [Slot]
    public var stateRevision: Int         // revision of state.json the service last wrote or loaded
    public var muted: Bool
    public var message: String?           // latest user-facing message (e.g. "Couldn't play …")
    public var lockBusy: Bool?            // a lock screen video is being rendered or installed (nil from older services)

    public init(playback: Playback = .stopped, slots: [Slot] = [], stateRevision: Int = 0, muted: Bool = true,
                message: String? = nil, lockBusy: Bool? = nil) {
        self.playback = playback
        self.slots = slots
        self.stateRevision = stateRevision
        self.muted = muted
        self.message = message
        self.lockBusy = lockBusy
    }

    public func slot(_ target: WallpaperTarget) -> Slot? { slots.first { $0.target == target } }
}

public enum ServiceCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
}

/// The pre-rendered lock screen video of a scene (SPEC3.md section 1.5). At most one is reported at a time.
public struct LockRenderStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case queued, rendering, finished, failed
    }

    public var itemID: UUID
    public var state: State
    public var progress: Double          // 0...1, meaningful while rendering
    public var message: String?          // user-facing reason when failed

    public init(itemID: UUID, state: State, progress: Double = 0, message: String? = nil) {
        self.itemID = itemID
        self.state = state
        self.progress = progress
        self.message = message
    }
}
