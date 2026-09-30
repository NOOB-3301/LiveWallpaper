import Foundation

// Settings app <-> wallpaper agent, over DistributedNotificationCenter.
//   Settings -> agent: one notification name (`commandName`), payload = AgentCommand.
//   agent -> Settings: one notification name (`statusName`),  payload = AgentStatus.
// Payloads are property lists of small scalars. Delivery is best effort (nothing is queued for a process that
// is not listening yet), so every command is idempotent and answered by a status whose `reply` is the command id.
// `.deliverImmediately` is required: without it a background process is sent these notifications late
// (phase 1 learned this with the lock/unlock notifications).

public enum IPC {
    public static let version = 1
    public static let settingsBundleID = "com.noob3301.LiveWallpaper"
    public static let agentBundleID = "com.noob3301.LiveWallpaper.agent"
    /// Info.plist key that tells the two apps (and the phase-1 app, which lacks it) apart: "settings" or "agent".
    public static let roleKey = "LWRole"
    // The major protocol version is part of the name; an incompatible future protocol simply uses ".v2".
    public static let commandName = Notification.Name("com.noob3301.LiveWallpaper.ipc.command.v1")
    public static let statusName = Notification.Name("com.noob3301.LiveWallpaper.ipc.status.v1")
}

// MARK: - Commands (Settings -> agent)

public struct AgentCommand: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case ping      // answer with a status
        case start     // begin at `videoID`, else state.selectedID, else the first video
        case stop      // stop and restore Apple's wallpapers; the agent stays alive
        case pause
        case resume
        case next
        case play      // `videoID`: jump to it, starting playback if needed
        case reload    // state.json changed; `revision` is what Settings just wrote
        case quit      // stop, restore, terminate the agent
    }

    public var id: String             // correlation id, echoed in AgentStatus.reply; also de-duplicates retransmits
    public var kind: Kind
    public var videoID: UUID?
    public var revision: Int?

    public init(kind: Kind, videoID: UUID? = nil, revision: Int? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
        self.videoID = videoID
        self.revision = revision
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = ["v": IPC.version, "id": id, "cmd": kind.rawValue]
        if let videoID { info["video"] = videoID.uuidString }
        if let revision { info["rev"] = revision }
        return info
    }

    /// nil for anything that is not a well-formed command of a known kind.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo,
              let id = info["id"] as? String,
              let raw = info["cmd"] as? String,
              let kind = Kind(rawValue: raw) else { return nil }
        self.id = id
        self.kind = kind
        self.videoID = (info["video"] as? String).flatMap { UUID(uuidString: $0) }
        self.revision = info["rev"] as? Int
    }
}

// MARK: - Status (agent -> Settings)

public struct AgentStatus: Equatable, Sendable {
    public var seq: Int                 // increases with every post within one agent process
    public var reply: String?           // id of the command this answers; nil for spontaneous posts
    public var pid: Int32               // agent process id; a new pid means a new agent run (seq restarts)
    public var agentVersion: String
    public var isRunning: Bool
    public var isPaused: Bool
    public var currentID: UUID?
    public var failedIDs: [UUID]
    public var message: String?         // user-facing problem, nil when fine
    public var lockBusy: Bool           // the lock screen video is being prepared
    public var stateRevision: Int       // state.json revision the agent has applied
    public var quitting: Bool           // last post before the agent terminates

    public init(seq: Int = 0, reply: String? = nil, pid: Int32 = 0, agentVersion: String = "",
                isRunning: Bool = false, isPaused: Bool = false, currentID: UUID? = nil,
                failedIDs: [UUID] = [], message: String? = nil, lockBusy: Bool = false,
                stateRevision: Int = 0, quitting: Bool = false) {
        self.seq = seq
        self.reply = reply
        self.pid = pid
        self.agentVersion = agentVersion
        self.isRunning = isRunning
        self.isPaused = isPaused
        self.currentID = currentID
        self.failedIDs = failedIDs
        self.message = message
        self.lockBusy = lockBusy
        self.stateRevision = stateRevision
        self.quitting = quitting
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = [
            "v": IPC.version, "seq": seq, "pid": Int(pid), "version": agentVersion,
            "running": isRunning, "paused": isPaused, "failed": failedIDs.map(\.uuidString),
            "lockBusy": lockBusy, "rev": stateRevision, "quitting": quitting,
        ]
        if let reply { info["reply"] = reply }
        if let currentID { info["current"] = currentID.uuidString }
        if let message { info["message"] = message }
        return info
    }

    /// nil for anything that is not a well-formed status.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo,
              let seq = info["seq"] as? Int,
              let pid = info["pid"] as? Int else { return nil }
        self.seq = seq
        self.reply = info["reply"] as? String
        self.pid = Int32(truncatingIfNeeded: pid)
        self.agentVersion = info["version"] as? String ?? ""
        self.isRunning = info["running"] as? Bool ?? false
        self.isPaused = info["paused"] as? Bool ?? false
        self.currentID = (info["current"] as? String).flatMap { UUID(uuidString: $0) }
        self.failedIDs = (info["failed"] as? [String] ?? []).compactMap { UUID(uuidString: $0) }
        self.message = info["message"] as? String
        self.lockBusy = info["lockBusy"] as? Bool ?? false
        self.stateRevision = info["rev"] as? Int ?? 0
        self.quitting = info["quitting"] as? Bool ?? false
    }
}

// MARK: - Endpoints

/// Agent side: listens for commands, posts statuses. Handlers run on the main actor.
public final class AgentEndpoint: NSObject {
    public var onCommand: (@MainActor (AgentCommand) -> Void)?
    private var listening = false

    public override init() {
        super.init()
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    /// Registers for commands; safe to call more than once.
    public func startListening() {
        guard !listening else { return }
        listening = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: IPC.commandName,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    public func post(_ status: AgentStatus) {
        DistributedNotificationCenter.default().postNotificationName(
            IPC.statusName, object: nil, userInfo: status.userInfo, deliverImmediately: true)
    }

    @objc private func received(_ note: Notification) {
        guard let command = AgentCommand(userInfo: note.userInfo) else { return }
        let handler = onCommand
        Task { @MainActor in handler?(command) }
    }
}

/// Settings side: listens for statuses, posts commands. Handlers run on the main actor.
public final class SettingsEndpoint: NSObject {
    public var onStatus: (@MainActor (AgentStatus) -> Void)?
    private var listening = false

    public override init() {
        super.init()
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    /// Registers for statuses; safe to call more than once.
    public func startListening() {
        guard !listening else { return }
        listening = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: IPC.statusName,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    public func send(_ command: AgentCommand) {
        DistributedNotificationCenter.default().postNotificationName(
            IPC.commandName, object: nil, userInfo: command.userInfo, deliverImmediately: true)
    }

    @objc private func received(_ note: Notification) {
        guard let status = AgentStatus(userInfo: note.userInfo) else { return }
        let handler = onStatus
        Task { @MainActor in handler?(status) }
    }
}
