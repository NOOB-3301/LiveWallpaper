import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoStills {
    static func cgImage(for url: URL, maxPixelSize: CGSize?) async -> CGImage? { nil }
}

enum LockScreenError: LocalizedError {
    case noFrame, writeFailed(String), setFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFrame:
            return "Couldn't read a frame from the video."
        case .writeFailed(let message):
            return "Couldn't save the lock screen image: \(message)"
        case .setFailed(let message):
            return "Couldn't set the lock screen image: \(message)"
        }
    }
}

@MainActor final class LockScreenWallpaper {
    private(set) var hasAppliedStill = false

    init() {}

    func apply(from videoURL: URL) async throws {}
    func restore() {}
}
