import Foundation
import Combine
import UniformTypeIdentifiers

struct VideoItem: Identifiable, Codable, Hashable {
    let id: UUID
    let path: String

    init(url: URL) {
        self.id = UUID()
        self.path = url.standardizedFileURL.path
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
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

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let minimumInterval: TimeInterval = 5

    @Published var videos: [VideoItem] = []
    @Published var selectedID: VideoItem.ID? = nil
    @Published var rotateEnabled: Bool = true
    @Published var intervalValue: Int = 5
    @Published var intervalUnit: IntervalUnit = .minutes
    @Published var applyToDesktop: Bool = true
    @Published var applyToLockScreen: Bool = true

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var currentID: VideoItem.ID? = nil
    @Published private(set) var failedIDs: Set<VideoItem.ID> = []
    @Published private(set) var statusMessage: String? = nil

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

    func bootstrap() {}
    @discardableResult func addVideos(urls: [URL]) -> Int { 0 }
    func remove(ids: Set<VideoItem.ID>) {}
    func removeAll() {}
    func start() {}
    func stop() {}
    func toggleRunning() {}
    func play(_ id: VideoItem.ID) {}
    func next() {}
    func togglePause() {}
    func clearStatus() {}
    func shutdown() {}
}
