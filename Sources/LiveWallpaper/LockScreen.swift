import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoStills {
    static func cgImage(for url: URL, maxPixelSize: CGSize?) async -> CGImage? {
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

private struct Original: Codable {
    let url: String
    let scaling: UInt
    let allowClipping: Bool
}

private enum StillFiles {
    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveWallpaper/Stills", isDirectory: true)

    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    static func write(_ image: CGImage) async throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LockScreenError.writeFailed(error.localizedDescription)
        }
        // A fresh name per apply: macOS caches wallpapers by path.
        let url = directory.appendingPathComponent("still-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LockScreenError.writeFailed("the file couldn't be created.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LockScreenError.writeFailed("the image couldn't be encoded.")
        }
        return url
    }

    static func removeAll(except keep: URL?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent != keep?.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

@MainActor final class LockScreenWallpaper {
    private static let originalsKey = "LiveWallpaper.originals.v1"

    private var currentStill: URL?
    private var ticket = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    var hasAppliedStill: Bool { currentStill != nil }

    init() {}

    func apply(from videoURL: URL) async throws {
        ticket += 1
        let mine = ticket
        let image = await VideoStills.cgImage(for: videoURL, maxPixelSize: Self.largestScreenPixelSize())
        guard mine == ticket else { return }
        guard let image else { throw LockScreenError.noFrame }
        let still: URL
        do {
            still = try await StillFiles.write(image)
        } catch {
            if mine == ticket { throw error }
            return
        }
        guard mine == ticket else {
            try? FileManager.default.removeItem(at: still)
            return
        }
        snapshotOriginals()
        currentStill = still
        try Self.show(still)
        StillFiles.removeAll(except: still)
        startObserving()
    }

    func restore() {
        ticket += 1
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        let saved = originals
        for screen in NSScreen.screens {
            guard let id = Self.displayID(screen), let original = saved[String(id)],
                  let url = URL(string: original.url) else { continue }
            try? Self.setDesktop(url, on: screen, scaling: original.scaling, clipping: original.allowClipping)
        }
        StillFiles.removeAll(except: nil)
        originals = [:]
        currentStill = nil
    }

    private var originals: [String: Original] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.originalsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Original].self, from: data)) ?? [:]
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.originalsKey)
            } else {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.originalsKey)
            }
        }
    }

    // Skipped while a previous run's still is showing, so a crash can't make a still the "original".
    private func snapshotOriginals() {
        guard originals.isEmpty else { return }
        var saved: [String: Original] = [:]
        for screen in NSScreen.screens {
            guard let id = Self.displayID(screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !StillFiles.contains(url) else { continue }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            saved[String(id)] = Original(
                url: url.absoluteString,
                scaling: (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? true)
        }
        originals = saved
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let sources: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
        ]
        for (center, name) in sources {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reapplyCurrentStill() }
            }
            observers.append((center, token))
        }
    }

    private func reapplyCurrentStill() {
        guard let still = currentStill else { return }
        try? Self.show(still)
    }

    // Skips screens already showing the still so our own change can never retrigger the observers.
    private static func show(_ still: URL) throws {
        for screen in NSScreen.screens
        where NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL != still.standardizedFileURL {
            do {
                try setDesktop(still, on: screen, scaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, clipping: true)
            } catch {
                throw LockScreenError.setFailed(error.localizedDescription)
            }
        }
    }

    private static func setDesktop(_ url: URL, on screen: NSScreen, scaling: UInt, clipping: Bool) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [.imageScaling: scaling, .allowClipping: clipping]
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    private static func largestScreenPixelSize() -> CGSize? {
        NSScreen.screens
            .map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
