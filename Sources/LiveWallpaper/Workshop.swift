import Foundation
import Combine
import Core

// SCAFFOLD STUB (owner: STEAM). The value types and the WorkshopModel surface below are the contract with
// WorkshopViews.swift and SettingsModel.swift; bodies are placeholders. Design, endpoints, steamcmd invocation,
// output parsing and the error taxonomy: SPEC2.md section 4. Keep the pure parts (link parsing, JSON decoding,
// steamcmd output classification, project.json parsing) in small static functions; they can be typechecked
// with the Linux toolchain noted in SPEC2.md section 9.
//
// Legitimacy rules (non-negotiable): the only download path is Valve's steamcmd with the user's own Steam
// account; the password and Steam Guard code are never read, stored or logged; the only network calls are the
// Steam Web API endpoints named in SPEC2.md 4.1; no HTML scraping; no third-party downloader sites.

// MARK: - Value types

struct WorkshopItem: Identifiable, Hashable {
    enum Kind: String {
        case video, scene, web, application, unknown
    }

    let id: String                 // publishedfileid, digits only
    var title: String
    var summary: String            // description with BBCode stripped; may be empty
    var previewURL: URL?
    var sizeBytes: Int64           // 0 when unknown
    var tags: [String]             // tag names as returned, e.g. "Video", "1920 x 1080", "Everyone"
    var kind: Kind
    var creatorSteamID: String?
    var author: String?            // persona name; only known when an API key resolved it
    var updated: Date?
    var subscriptions: Int?

    var isVideo: Bool { kind == .video }
    /// "1920 x 1080", "Other resolution", ... whichever resolution tag the item carries.
    var resolutionTag: String? { tags.first { $0.contains(" x ") || $0.hasSuffix("resolution") } }
    /// "Everyone", "Questionable" or "Mature".
    var ratingTag: String? { tags.first { ["Everyone", "Questionable", "Mature"].contains($0) } }
}

enum WorkshopFix: Equatable {
    case openSteamSetup, copyLoginCommand, copyBrewCommand, copyRosettaCommand, openAPIKeyPage, retry
}

/// Everything that can go wrong, with the exact user-facing words. The UI shows `title` (bold) and `message`
/// (secondary), plus a button for `fix` when there is one.
enum WorkshopError: Error, Equatable {
    case invalidInput
    case network(String)
    case rateLimited
    case itemNotFound
    case itemUnavailable(String)
    case notWallpaperEngineItem
    case unsupportedType(WorkshopItem.Kind)
    case unsupportedFormat(String)       // file extension, e.g. "webm"
    case unsupportedCodec
    case steamcmdMissing
    case rosettaMissing
    case usernameMissing
    case needsLogin
    case notOwned
    case steamcmdFailed(String)          // last useful output line
    case timedOut
    case contentMissing
    case importFailed(String)
    case apiKeyRejected
    case cancelled

    var title: String {
        switch self {
        case .invalidInput: return "That isn’t a Workshop link"
        case .network: return "Couldn’t reach Steam"
        case .rateLimited: return "Steam asked us to slow down"
        case .itemNotFound: return "Item not found"
        case .itemUnavailable: return "This item isn’t available"
        case .notWallpaperEngineItem: return "Not a Wallpaper Engine item"
        case .unsupportedType: return "Not a video wallpaper"
        case .unsupportedFormat: return "Video format not supported"
        case .unsupportedCodec: return "This video can’t be played"
        case .steamcmdMissing: return "SteamCMD isn’t installed"
        case .rosettaMissing: return "Rosetta is needed"
        case .usernameMissing: return "Enter your Steam username"
        case .needsLogin: return "Steam login needed"
        case .notOwned: return "Steam refused the download"
        case .steamcmdFailed: return "Download failed"
        case .timedOut: return "Steam took too long"
        case .contentMissing: return "The download finished without a video"
        case .importFailed: return "Couldn’t add the video"
        case .apiKeyRejected: return "Steam rejected the API key"
        case .cancelled: return "Cancelled"
        }
    }

    var message: String {
        switch self {
        case .invalidInput:
            return "Paste a link from steamcommunity.com (…/filedetails/?id=1234567890) or just the item number."
        case .network(let detail):
            return "Check your internet connection and try again. (\(detail))"
        case .rateLimited:
            return "Wait a minute and try again."
        case .itemNotFound:
            return "Steam has no public item with that number. It may have been removed or be private."
        case .itemUnavailable(let reason):
            return reason.isEmpty ? "The creator or Steam has hidden or removed it." : "It was removed: \(reason)"
        case .notWallpaperEngineItem:
            return "This item belongs to a different game’s Workshop. Only Wallpaper Engine wallpapers work here."
        case .unsupportedType(let kind):
            switch kind {
            case .scene: return "Scene wallpapers need Wallpaper Engine’s own renderer. Only video wallpapers can play here."
            case .web: return "Web wallpapers need a browser-based renderer. Only video wallpapers can play here."
            case .application: return "Application wallpapers are programs, not videos. Only video wallpapers can play here."
            default: return "Only video wallpapers can play here."
            }
        case .unsupportedFormat(let ext):
            return "This wallpaper’s video is a .\(ext) file. Live Wallpaper plays MP4, MOV and M4V and doesn’t convert other formats."
        case .unsupportedCodec:
            return "macOS can’t decode this video (probably VP9 or AV1). Choose a wallpaper with an H.264 or HEVC video."
        case .steamcmdMissing:
            return "Install it with Homebrew (brew install --cask steamcmd), or choose an existing copy in Steam Setup."
        case .rosettaMissing:
            return "SteamCMD is an Intel program. On Apple silicon install Rosetta once: softwareupdate --install-rosetta --agree-to-license"
        case .usernameMissing:
            return "Open Steam Setup and enter the name of the Steam account that owns Wallpaper Engine."
        case .needsLogin:
            return "Sign in once in Terminal so SteamCMD remembers the account. Live Wallpaper never sees your password."
        case .notOwned:
            return "The most common reason is that this Steam account doesn’t own Wallpaper Engine, which is a paid app. Sign in with the account that does."
        case .steamcmdFailed(let detail):
            return detail.isEmpty ? "SteamCMD reported an error. Try again in a moment." : "SteamCMD said: \(detail)"
        case .timedOut:
            return "SteamCMD stopped responding. Try again; the first run after installing can take a few minutes."
        case .contentMissing:
            return "SteamCMD reported success but no video file was found. Try downloading again."
        case .importFailed(let detail):
            return "The file was downloaded but couldn’t be saved to your library. (\(detail))"
        case .apiKeyRejected:
            return "Check the key in Steam Setup, or remove it and paste a Workshop link instead."
        case .cancelled:
            return "The download was cancelled."
        }
    }

    var fix: WorkshopFix? {
        switch self {
        case .steamcmdMissing: return .copyBrewCommand
        case .rosettaMissing: return .copyRosettaCommand
        case .usernameMissing: return .openSteamSetup
        case .needsLogin: return .copyLoginCommand
        case .apiKeyRejected: return .openAPIKeyPage
        case .network, .rateLimited, .timedOut, .steamcmdFailed, .contentMissing: return .retry
        default: return nil
        }
    }
}

enum WorkshopDownloadState: Equatable {
    case queued
    case signingIn
    case downloading(progress: Double?)   // nil = indeterminate
    case importing
    case done(videoID: UUID)              // the VideoItem added to the library
    case failed(WorkshopError)
}

enum SteamLoginState: Equatable {
    case unknown
    case checking
    case loggedIn
    case needsLogin
    case failed(WorkshopError)
}

struct SteamSetupStatus: Equatable {
    var steamcmdPath: String?             // resolved, executable; nil = not found
    var rosettaOK: Bool                   // true on Intel, or when Rosetta is installed
    var usernameValid: Bool
    var login: SteamLoginState
    var hasAPIKey: Bool

    /// Downloads are offered unless something is known to be wrong. A login that is merely unchecked is fine.
    var canDownload: Bool {
        steamcmdPath != nil && rosettaOK && usernameValid && login != .needsLogin
    }
}

enum WorkshopSort: String, CaseIterable, Identifiable {
    case trending, newest, popular

    var id: String { rawValue }
    var label: String {
        switch self {
        case .trending: return "Trending"
        case .newest: return "Newest"
        case .popular: return "Most Subscribed"
        }
    }
}

enum WorkshopLookupState: Equatable {
    case idle
    case loading
    case found(WorkshopItem)
    case failed(WorkshopError)
}

enum WorkshopListState: Equatable {
    case idle
    case loading
    case loaded
    case failed(WorkshopError)
}

// MARK: - Model

@MainActor final class WorkshopModel: ObservableObject {
    static let shared = WorkshopModel()
    static let appID = "431960"   // Wallpaper Engine

    // Setup. Persisted by this model in the Settings app's UserDefaults (username, path override, API key).
    // The password and Steam Guard codes are never stored anywhere.
    @Published var steamUsername: String = ""
    @Published var steamcmdPathOverride: String = ""      // "" = auto-detect
    @Published var apiKey: String = ""                    // optional free Steam Web API key, enables browsing
    @Published private(set) var setup = SteamSetupStatus(
        steamcmdPath: nil, rosettaOK: true, usernameValid: false, login: .unknown, hasAPIKey: false)

    let brewInstallCommand = "brew install --cask steamcmd"
    let rosettaInstallCommand = "softwareupdate --install-rosetta --agree-to-license"
    var loginCommand: String {
        "steamcmd +login \(steamUsername.isEmpty ? "<your Steam username>" : steamUsername)"
    }
    var canBrowse: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    // Lookup of one pasted link or item number (public endpoint, no key).
    @Published var pastedText: String = ""
    @Published private(set) var lookup: WorkshopLookupState = .idle

    // Browse and search (needs apiKey).
    @Published var searchText: String = ""
    @Published var sort: WorkshopSort = .trending
    @Published var includeMature: Bool = false            // false = hide Questionable and Mature
    @Published private(set) var results: [WorkshopItem] = []
    @Published private(set) var listState: WorkshopListState = .idle
    @Published private(set) var canLoadMore: Bool = false

    // Downloads, keyed by WorkshopItem.id. Entries stay until dismissed, so finished and failed cards keep their state.
    @Published private(set) var downloads: [String: WorkshopDownloadState] = [:]

    /// True while any download is queued, signing in, downloading or importing. The Settings app stays alive
    /// with its window closed until this is false again.
    var hasActiveDownloads: Bool {
        downloads.values.contains { state in
            switch state {
            case .queued, .signingIn, .downloading, .importing: return true
            case .done, .failed: return false
            }
        }
    }

    private var onImport: (@MainActor (VideoItem) -> Void)?
    private var libraryCheck: (@MainActor (String) -> Bool)?

    init() {}

    // MARK: Wiring (SETTINGS calls this once from applicationDidFinishLaunching)

    func connect(onImport: @escaping @MainActor (VideoItem) -> Void,
                 isInLibrary: @escaping @MainActor (String) -> Bool) {
        self.onImport = onImport
        self.libraryCheck = isInLibrary
        // TODO(STEAM): load persisted setup values, then recheckSetup().
    }

    func isInLibrary(_ id: String) -> Bool {
        libraryCheck?(id) ?? false
    }

    // MARK: Setup

    /// Fast and side-effect free (no process): resolves the steamcmd path, Rosetta, username validity.
    func recheckSetup() {
        // TODO(STEAM)
    }

    /// Runs steamcmd once (`+@NoPromptForPassword 1 +login <user> +quit`, stdin closed) to see whether the
    /// cached session works. Sets setup.login. Never prompts, never reads a password.
    func checkLogin() {
        // TODO(STEAM)
    }

    // MARK: Lookup and browse

    /// Parses `pastedText` (link or digits) and fetches the item details. Result lands in `lookup`.
    func lookUp() {
        // TODO(STEAM)
    }

    /// Resets `results` and loads the first page for the current sort/searchText/includeMature.
    func search() {
        // TODO(STEAM)
    }

    func loadMore() {
        // TODO(STEAM)
    }

    // MARK: Downloads

    /// Queues the item. Only video items; other kinds fail immediately with .unsupportedType. Downloads run
    /// one at a time (steamcmd cannot run twice against one data directory).
    func download(_ item: WorkshopItem) {
        // TODO(STEAM)
    }

    func cancelDownload(_ id: String) {
        // TODO(STEAM)
    }

    /// Removes a finished or failed entry from `downloads`.
    func dismissDownload(_ id: String) {
        downloads[id] = nil
    }

    /// Terminates any running steamcmd (app quit).
    func cancelAll() {
        // TODO(STEAM)
    }
}
