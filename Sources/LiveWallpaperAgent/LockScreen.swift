import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Core

enum LockScreenError: LocalizedError {
    case noFrame, writeFailed(String), setFailed(String)
    case noAerial, convertFailed(String), installFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFrame:
            return "Couldn't read a frame from the video."
        case .writeFailed(let message):
            return "Couldn't save the lock screen image: \(message)"
        case .setFailed(let message):
            return "Couldn't set the lock screen image: \(message)"
        case .noAerial:
            return "No Apple Aerial wallpaper is downloaded yet. Open System Settings → Wallpaper, pick an Aerial, wait for it to download and leave it selected, then try again."
        case .convertFailed(let message):
            return "Couldn't prepare the video for the lock screen: \(message)"
        case .installFailed(let message):
            return "Couldn't install the video on the lock screen: \(message)"
        }
    }
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

private enum AerialFiles {
    static let temporaryPrefix = "livewallpaper-lockscreen-"

    private static let applicationSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let videos = applicationSupport.appendingPathComponent("com.apple.wallpaper/aerials/videos", isDirectory: true)
    static let backups = applicationSupport.appendingPathComponent("LiveWallpaper/Backups", isDirectory: true)

    static func slot(_ name: String) -> URL { videos.appendingPathComponent(name) }
    static func backup(_ name: String) -> URL { backups.appendingPathComponent(name) }

    // Every downloaded aerial: there is no telling which one the lock screen, a display or a Space plays.
    static func downloadedSlots() throws -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: videos, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let slots = files.filter { $0.pathExtension.lowercased() == "mov" }.map(\.lastPathComponent).sorted()
        guard !slots.isEmpty else { throw LockScreenError.noAerial }
        return slots
    }

    // Moves `file` to `destination`, atomically replacing what is there.
    static func place(_ file: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: destination)
        }
    }

    static func newTemporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).mov")
    }

    static func removeTemporaryFiles() {
        let directory = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(temporaryPrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private enum AerialExport {
    static let targetSeconds = 180.0
    static let maxCopies = 600

    // Returns a temporary .mov that looks like an aerial: video only, tiled to about three minutes
    // because the renderer misbehaves once a video ends.
    static func makeFile(from source: URL) async throws -> URL {
        do {
            let composition = try await tiledComposition(from: source)
            do {
                return try await export(composition, preset: AVAssetExportPresetPassthrough)
            } catch {
                return try await export(composition, preset: AVAssetExportPresetHEVCHighestQuality)
            }
        } catch let error as LockScreenError {
            throw error
        } catch {
            throw LockScreenError.convertFailed(error.localizedDescription)
        }
    }

    private static func tiledComposition(from source: URL) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LockScreenError.convertFailed("the file has no video track.")
        }
        let range = try await sourceTrack.load(.timeRange)
        guard range.duration.seconds > 0.1 else { throw LockScreenError.convertFailed("the video is too short.") }
        let copies = min(maxCopies, Int((targetSeconds / range.duration.seconds).rounded(.up)))
        var cursor = CMTime.zero
        for _ in 0..<copies {
            try track.insertTimeRange(range, of: sourceTrack, at: cursor)
            cursor = cursor + range.duration
        }
        track.preferredTransform = try await sourceTrack.load(.preferredTransform)
        return composition
    }

    private static func export(_ composition: AVAsset, preset: String) async throws -> URL {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw LockScreenError.convertFailed("the export preset isn't available.")
        }
        let file = AerialFiles.newTemporaryFile()
        session.outputURL = file
        session.outputFileType = .mov
        // Puts the moov atom first, like Apple's own aerial files.
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: file)
            throw session.error ?? LockScreenError.convertFailed("the export didn't finish.")
        }
        return file
    }
}

// Distributed notifications are held back while the app is in the background unless delivery is
// immediate, and an unlock arrives exactly then.
private final class LockObserver: NSObject {
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"),
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"),
                           object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func locked() { Task { @MainActor [onChange] in onChange(true) } }
    @objc private func unlocked() { Task { @MainActor [onChange] in onChange(false) } }
}

@MainActor final class LockScreenWallpaper {
    // Apps built with an older SDK see macOS 26 as 16, so 16 or later means the aerial technique applies.
    private static let usesAerial = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16
    // Each install writes hundreds of MB, so fast rotation is throttled to one lock screen update per window.
    private static let installSpacing = Duration.seconds(30)

    private var currentStill: URL?
    // Bumped by every still apply and by restore(); a stale ticket means the work was superseded.
    private var ticket = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var wanted: URL?
    private var worker: Task<Void, Error>?
    private var nextInstall = ContinuousClock().now
    private var isLocked = false
    private var lockObserver: LockObserver?

    var hasAppliedStill: Bool { currentStill != nil || !aerialSlots.isEmpty }

    init() {}

    func apply(from videoURL: URL) async throws {
        guard Self.usesAerial else {
            try await applyStill(from: videoURL)
            return
        }
        startObservingLock()
        // Last call wins: one worker exports whichever video was requested most recently.
        wanted = videoURL
        guard worker == nil else { return }
        let task = Task { try await self.drain() }
        worker = task
        try await task.value
    }

    private func applyStill(from videoURL: URL) async throws {
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
        wanted = nil
        isLocked = false
        lockObserver = nil
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
        restoreAerial()
        AerialFiles.removeTemporaryFiles()
    }

    // Keeps the newest request moving: waits out the spacing window, then converts and installs it.
    // A request that arrives meanwhile replaces `wanted` and is handled by the next pass.
    private func drain() async throws {
        defer { worker = nil }
        let clock = ContinuousClock()
        while wanted != nil {
            let wait = clock.now.duration(to: nextInstall)
            if wait > .zero { try? await clock.sleep(for: wait) }
            guard let video = wanted else { return }
            wanted = nil
            defer { nextInstall = clock.now.advanced(by: Self.installSpacing) }
            let mine = ticket
            let file: URL
            do {
                file = try await AerialExport.makeFile(from: video)
            } catch {
                if mine == ticket { throw error }
                continue
            }
            guard mine == ticket else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            try install(file)
        }
    }

    private func install(_ file: URL) throws {
        // The file is moved into place on success, so this only cleans up after a failure.
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let fileManager = FileManager.default
            let slots = try AerialFiles.downloadedSlots()
            // Persisted before anything moves, so a crash can never strand Apple's originals.
            aerialSlots = Array(Set(slots).union(aerialSlots)).sorted()
            try fileManager.createDirectory(at: AerialFiles.backups, withIntermediateDirectories: true)
            for slot in slots where !fileManager.fileExists(atPath: AerialFiles.backup(slot).path) {
                try fileManager.moveItem(at: AerialFiles.slot(slot), to: AerialFiles.backup(slot))
            }
            let first = AerialFiles.slot(slots[0])
            try AerialFiles.place(file, at: first)
            // The other slots are hard links to the first, so they take no extra disk space.
            for slot in slots.dropFirst() {
                let copy = AerialFiles.newTemporaryFile()
                do { try fileManager.linkItem(at: first, to: copy) } catch { try fileManager.copyItem(at: first, to: copy) }
                try AerialFiles.place(copy, at: AerialFiles.slot(slot))
            }
        } catch let error as LockScreenError {
            throw error
        } catch {
            throw LockScreenError.installFailed(error.localizedDescription)
        }
        // While locked, the unlock handler restarts the renderer instead; killing it now would blank the screen.
        if !isLocked { Self.killall("WallpaperAerialsExtension", "WallpaperAgent") }
    }

    private func restoreAerial() {
        // Originals waiting in Backups/ count even when no record survived, so nothing can be stranded.
        let pending = Set(aerialSlots).union(AgentRecordStore.backupSlotsOnDisk()).sorted()
        guard !pending.isEmpty else { return }
        let failed = pending.filter { slot in
            FileManager.default.fileExists(atPath: AerialFiles.backup(slot).path)
                && (try? AerialFiles.place(AerialFiles.backup(slot), at: AerialFiles.slot(slot))) == nil
        }
        // The record keeps whatever failed so the next restore retries.
        guard failed.isEmpty else { aerialSlots = failed; return }
        aerialSlots = []
        Self.killall("WallpaperAerialsExtension", "WallpaperAgent")
    }

    // Both records live in agent.json (Core), not in UserDefaults: the agent has its own bundle id,
    // and the records must outlive any one build.
    private var aerialSlots: [String] {
        get { AgentRecordStore.load().aerialSlots }
        set { AgentRecordStore.update { $0.aerialSlots = newValue } }
    }

    private var originals: [String: OriginalWallpaper] {
        get { AgentRecordStore.load().originals }
        set { AgentRecordStore.update { $0.originals = newValue } }
    }

    // Skipped while a previous run's still is showing, so a crash can't make a still the "original".
    private func snapshotOriginals() {
        guard originals.isEmpty else { return }
        var saved: [String: OriginalWallpaper] = [:]
        for screen in NSScreen.screens {
            guard let id = Self.displayID(screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !StillFiles.contains(url) else { continue }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            saved[String(id)] = OriginalWallpaper(
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
                Task { @MainActor [weak self] in self?.reapplyCurrentStill() }
            }
            observers.append((center, token))
        }
    }

    private func startObservingLock() {
        guard lockObserver == nil else { return }
        lockObserver = LockObserver { [weak self] locked in self?.screenLockChanged(locked) }
    }

    // The renderer wedges into a black screen on later locks unless restarted at unlock.
    // That restart also picks up a file swapped while the screen was locked.
    private func screenLockChanged(_ locked: Bool) {
        isLocked = locked
        if !locked, !aerialSlots.isEmpty { Self.killall("WallpaperAerialsExtension") }
    }

    private static func killall(_ names: String...) {
        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [name]
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
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
