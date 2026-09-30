import Foundation
import Combine
import Core
#if canImport(AVFoundation)
import AVFoundation
#endif

// Steam Workshop (owner: STEAM): value types and WorkshopModel (the surface WorkshopViews and SettingsModel use),
// then the file-private backend in `WorkshopKit` (link parsing, Steam Web API client, steamcmd runner, import).
// Design, endpoints, steamcmd invocation and the error taxonomy: SPEC2.md section 4.
//
// Legitimacy rules (non-negotiable): the only download path is Valve's steamcmd with the user's own Steam
// account, signed in once by the user in Terminal. The password and Steam Guard code are never read, stored or
// logged (steamcmd runs with stdin closed and +@NoPromptForPassword 1). The only network calls are the Steam Web
// API endpoints named in SPEC2.md 4.1 plus the item's own preview image; no HTML scraping; no third-party
// downloader sites. The Web API key is sent only to api.steampowered.com and is never logged or cached.

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
    static let appID = WorkshopKit.appID   // Wallpaper Engine

    // Setup. Persisted by this model in the Settings app's UserDefaults (username, path override, API key).
    // The password and Steam Guard codes are never stored anywhere.
    @Published var steamUsername: String = WorkshopKit.Prefs.username.value {
        didSet { WorkshopKit.Prefs.username.value = steamUsername; recheckSetup() }
    }
    @Published var steamcmdPathOverride: String = WorkshopKit.Prefs.steamcmd.value {   // "" = auto-detect
        didSet { WorkshopKit.Prefs.steamcmd.value = steamcmdPathOverride; recheckSetup() }
    }
    @Published var apiKey: String = WorkshopKit.Prefs.apiKey.value {                     // optional, enables browsing
        didSet {
            WorkshopKit.Prefs.apiKey.value = apiKey
            recheckSetup()
            if !canBrowse { search() }
        }
    }
    @Published private(set) var setup = SteamSetupStatus(
        steamcmdPath: nil, rosettaOK: true, usernameValid: false, login: .unknown, hasAPIKey: false)

    let brewInstallCommand = "brew install --cask steamcmd"
    let rosettaInstallCommand = "softwareupdate --install-rosetta --agree-to-license"
    var loginCommand: String {
        "steamcmd +login \(trimmedUsername.isEmpty ? "<your Steam username>" : trimmedUsername)"
    }
    var canBrowse: Bool { !trimmedKey.isEmpty }

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

    private var trimmedUsername: String { steamUsername.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var loginState: SteamLoginState = .unknown
    private var loginOwner = ""                      // the username `loginState` was learned for
    private var runner: WorkshopKit.Runner?          // the one steamcmd invocation in flight (download or sign-in check)
    private var runningID: String?                   // the download that invocation belongs to
    private var queue: [WorkshopItem] = []
    private var polledBytes: Int64 = 0
    private var lookupTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var nextCursor: String?

    init() { recheckSetup() }

    // MARK: Wiring (SETTINGS calls this once from applicationDidFinishLaunching)

    func connect(onImport: @escaping @MainActor (VideoItem) -> Void,
                 isInLibrary: @escaping @MainActor (String) -> Bool) {
        self.onImport = onImport
        self.libraryCheck = isInLibrary
        recheckSetup()
    }

    func isInLibrary(_ id: String) -> Bool {
        libraryCheck?(id) ?? false
    }

    // MARK: Setup

    /// Fast and side-effect free (no process): resolves the steamcmd path, Rosetta, username validity.
    func recheckSetup() {
        let name = trimmedUsername
        let next = SteamSetupStatus(
            steamcmdPath: WorkshopKit.Locate.steamcmd(override: steamcmdPathOverride, home: WorkshopKit.home),
            rosettaOK: WorkshopKit.Locate.rosettaReady(),
            usernameValid: WorkshopKit.Invocation.isValidUsername(name),
            login: loginOwner == name ? loginState : .unknown,
            hasAPIKey: canBrowse)
        if next != setup { setup = next }
    }

    /// Runs steamcmd once (`+@NoPromptForPassword 1 +login <user> +quit`, stdin closed) to see whether the
    /// cached session works. Sets setup.login. Never prompts, never reads a password.
    func checkLogin() {
        guard runner == nil else { return }
        let name = trimmedUsername
        switch prerequisites() {
        case .failure(let error):
            setLogin(.failed(error), for: name)
        case .success(let path):
            setLogin(.checking, for: name)
            let runner = WorkshopKit.Runner(executable: path)
            self.runner = runner
            Task { @MainActor [weak self] in
                let state: SteamLoginState
                do {
                    let run = try await runner.run(arguments: WorkshopKit.Invocation.loginCheck(user: name),
                                                   stopOn: { $0 == .signedIn }, onEvent: { _ in }, onTick: { false })
                    state = WorkshopKit.Output.loginResult(run)
                } catch {
                    state = .failed(WorkshopKit.launchError(error))
                }
                guard let self else { return }
                self.setLogin(state, for: name)
                self.finishRun()
            }
        }
    }

    private func setLogin(_ state: SteamLoginState, for name: String) {
        loginState = state
        loginOwner = name
        recheckSetup()
    }

    /// The steamcmd path when a download or sign-in check can run, else what is missing (in the order of SPEC2 4.2).
    private func prerequisites() -> Result<String, WorkshopError> {
        recheckSetup()
        guard let path = setup.steamcmdPath else { return .failure(.steamcmdMissing) }
        guard setup.rosettaOK else { return .failure(.rosettaMissing) }
        guard setup.usernameValid else { return .failure(.usernameMissing) }
        return .success(path)
    }

    // MARK: Lookup and browse

    /// Parses `pastedText` (link or digits) and fetches the item details. Result lands in `lookup`.
    func lookUp() {
        lookupTask?.cancel()
        guard let id = WorkshopKit.Link.itemID(from: pastedText) else {
            lookup = .failed(.invalidInput)
            return
        }
        lookup = .loading
        lookupTask = Task { @MainActor [weak self] in
            let state: WorkshopLookupState
            do {
                state = .found(try await WorkshopKit.API.details(id: id))
            } catch {
                state = .failed(error as? WorkshopError ?? .network("unexpected error"))
            }
            guard let self, !Task.isCancelled else { return }
            self.lookup = state
        }
    }

    /// Resets `results` and loads the first page for the current sort/searchText/includeMature.
    func search() {
        searchTask?.cancel()
        searchGeneration += 1
        nextCursor = "*"
        results = []
        canLoadMore = false
        if canBrowse { loadPage() } else { listState = .idle }
    }

    func loadMore() {
        guard canBrowse, canLoadMore, listState != .loading else { return }
        loadPage()
    }

    private func loadPage() {
        listState = .loading
        let generation = searchGeneration
        let request = WorkshopKit.API.Browse(key: trimmedKey, sort: sort, text: searchText,
                                             mature: includeMature, cursor: nextCursor ?? "*")
        searchTask = Task { @MainActor [weak self] in
            do {
                let page = try await WorkshopKit.API.browse(request)
                guard let self, generation == self.searchGeneration, !Task.isCancelled else { return }
                let known = Set(self.results.map(\.id))
                self.results += page.items.filter { !known.contains($0.id) }
                self.nextCursor = page.next
                self.canLoadMore = page.next != nil && page.next != request.cursor
                    && page.rawCount == WorkshopKit.API.pageSize
                self.listState = .loaded
            } catch {
                guard let self, generation == self.searchGeneration, !Task.isCancelled else { return }
                self.listState = .failed(error as? WorkshopError ?? .network("unexpected error"))
            }
        }
    }

    // MARK: Downloads

    /// Queues the item. Only video items; other kinds fail immediately with .unsupportedType. Downloads run
    /// one at a time (steamcmd cannot run twice against one data directory).
    func download(_ item: WorkshopItem) {
        switch downloads[item.id] {
        case .queued?, .signingIn?, .downloading?, .importing?: return
        case .done? where isInLibrary(item.id): return
        default: break
        }
        guard item.isVideo else {
            downloads[item.id] = .failed(.unsupportedType(item.kind))
            return
        }
        if case .failure(let error) = prerequisites() {
            downloads[item.id] = .failed(error)
            return
        }
        downloads[item.id] = .queued
        queue.append(item)
        pump()
    }

    func cancelDownload(_ id: String) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            downloads[id] = nil
        } else if runningID == id, case .importing? = downloads[id] {
            return   // steamcmd is done; the copy into the library is short and not interruptible
        } else if runningID == id {
            downloads[id] = nil
            runner?.cancel()
        }
    }

    /// Removes a finished or failed entry from `downloads`.
    func dismissDownload(_ id: String) {
        downloads[id] = nil
    }

    /// Terminates any running steamcmd (app quit).
    func cancelAll() {
        for item in queue { downloads[item.id] = nil }
        queue = []
        if let id = runningID { downloads[id] = nil }
        runner?.cancel()
        lookupTask?.cancel()
        searchTask?.cancel()
    }

    private func pump() {
        guard runner == nil, !queue.isEmpty else { return }
        switch prerequisites() {
        case .failure(let error):
            for item in queue { downloads[item.id] = .failed(error) }
            queue = []
        case .success(let path):
            let item = queue.removeFirst()
            let runner = WorkshopKit.Runner(executable: path)
            self.runner = runner
            runningID = item.id
            polledBytes = 0
            downloads[item.id] = .signingIn
            Task { @MainActor [weak self] in await self?.perform(item, runner) }
        }
    }

    private func perform(_ item: WorkshopItem, _ runner: WorkshopKit.Runner) async {
        switch await fetch(item, runner) {
        case .success(let video): downloads[item.id] = .done(videoID: video.id)
        case .failure(.cancelled): downloads[item.id] = nil
        case .failure(let error): downloads[item.id] = .failed(error)
        }
        WorkshopKit.Staging.wipe()
        finishRun()
    }

    private func finishRun() {
        runner = nil
        runningID = nil
        pump()
    }

    /// steamcmd download, then import into Library/<id>/.
    private func fetch(_ item: WorkshopItem, _ runner: WorkshopKit.Runner) async -> Result<VideoItem, WorkshopError> {
        WorkshopKit.Staging.wipe()
        let run: WorkshopKit.Run
        do {
            run = try await runner.run(
                arguments: WorkshopKit.Invocation.download(user: trimmedUsername, id: item.id),
                onEvent: { self.handle($0, for: item.id) },
                onTick: { self.pollProgress(item) })
        } catch {
            return .failure(WorkshopKit.launchError(error))
        }
        let successPath: String?
        switch WorkshopKit.Output.downloadResult(run) {
        case .failure(let error): return .failure(error)
        case .success(let path): successPath = path
        }
        downloads[item.id] = .importing
        let roots = WorkshopKit.Locate.roots(steamcmd: setup.steamcmdPath, home: WorkshopKit.home)
        guard let content = WorkshopKit.Locate.content(id: item.id, successPath: successPath, roots: roots) else {
            return .failure(.contentMissing)
        }
        do {
            let video = try await WorkshopKit.Import.run(item: item, content: content,
                                                         moveFiles: WorkshopKit.Staging.contains(content))
            onImport?(video)
            return .success(video)
        } catch {
            return .failure(error as? WorkshopError ?? .importFailed(error.localizedDescription))
        }
    }

    private func handle(_ event: WorkshopKit.Output.Event, for id: String) {
        guard downloads[id] != nil else { return }
        switch event {
        case .signedIn:
            setLogin(.loggedIn, for: trimmedUsername)
            advance(id, to: nil)
        case .downloading: advance(id, to: nil)
        case .progress(let value): advance(id, to: min(value, 0.99))
        case .failure(.needsLogin): setLogin(.needsLogin, for: trimmedUsername)
        case .selfUpdating, .success, .failure: break
        }
    }

    /// signingIn -> downloading, and forward-only progress updates (at least half a percent apart).
    private func advance(_ id: String, to progress: Double?) {
        switch downloads[id] {
        case .signingIn?:
            downloads[id] = .downloading(progress: progress)
        case .downloading(let current)?:
            if let progress, progress > (current ?? 0) + 0.005 { downloads[id] = .downloading(progress: progress) }
        default: break
        }
    }

    /// Activity and progress from the growth of the download folders; true when anything grew or moved. Progress
    /// needs the staging folder and the size Steam reported, otherwise it stays indeterminate.
    private func pollProgress(_ item: WorkshopItem) -> Bool {
        let roots = WorkshopKit.Locate.roots(steamcmd: setup.steamcmdPath, home: WorkshopKit.home)
        let sizes = roots.map { WorkshopKit.Locate.bytes(id: item.id, in: $0) }
        let total = sizes.reduce(0, +)
        guard total != polledBytes else { return false }
        polledBytes = total
        let staged = sizes.first ?? 0
        advance(item.id, to: staged > 0 && item.sizeBytes > 0 ? min(0.99, Double(staged) / Double(item.sizeBytes)) : nil)
        return true
    }
}

// MARK: - Backend (file-private; one namespace, so nothing else in the Settings module can collide)

private enum WorkshopKit {
    static let appID = "431960"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// RFC 3986 unreserved characters. `CharacterSet.alphanumerics` is Unicode-wide and URLComponents leaves
    /// `+` and `/` alone, so every query and form value is encoded by hand with this set.
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// The values the user typed in Steam Setup (never a password).
    enum Prefs: String {
        case username = "LiveWallpaper.steam.username"
        case steamcmd = "LiveWallpaper.steam.steamcmdPath"
        case apiKey = "LiveWallpaper.steam.apiKey"

        var value: String {
            get { UserDefaults.standard.string(forKey: rawValue) ?? "" }
            nonmutating set { UserDefaults.standard.set(newValue, forKey: rawValue) }
        }
    }
}

// MARK: Links

extension WorkshopKit {
    enum Link {
        /// An item number ("3345509823"), a steamcommunity.com filedetails link or a steam://url/CommunityFilePage/<id>
        /// link -> the item number. Anything else -> nil.
        static func itemID(from text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isItemNumber(trimmed) { return trimmed }
            if let prefix = trimmed.range(of: "steam://url/CommunityFilePage/", options: [.caseInsensitive, .anchored]) {
                let digits = String(trimmed[prefix.upperBound...].prefix { isDigit($0) })
                return isItemNumber(digits) ? digits : nil
            }
            let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let parts = URLComponents(string: candidate),
                  let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = parts.host?.lowercased(), host == "steamcommunity.com" || host == "www.steamcommunity.com",
                  parts.path.lowercased().contains("filedetails"),
                  let id = parts.queryItems?.first(where: { $0.name == "id" })?.value,
                  isItemNumber(id) else { return nil }
            return id
        }

        static func isItemNumber(_ text: String) -> Bool {
            (6...20).contains(text.count) && text.allSatisfy(isDigit)
        }

        private static func isDigit(_ character: Character) -> Bool {
            guard let value = character.asciiValue else { return false }
            return (48...57).contains(value)
        }
    }
}

// MARK: Steam Web API: JSON decoding (lenient: Steam mixes strings, numbers and booleans)

extension WorkshopKit {
    enum Wire {
        /// A JSON string, number or boolean, kept as text. `file_size` and ids arrive as strings, counts as numbers,
        /// and `banned` is 0/1 on one endpoint and true/false on the other.
        struct StringOrInt: Decodable {
            let text: String
            var number: Int64? { Int64(text) ?? Double(text).flatMap { Int64(exactly: $0) } }

            init(from decoder: Decoder) throws {
                let box = try decoder.singleValueContainer()
                if let string = try? box.decode(String.self) {
                    text = string
                } else if let integer = try? box.decode(Int64.self) {
                    text = String(integer)
                } else if let flag = try? box.decode(Bool.self) {
                    text = flag ? "1" : "0"
                } else {
                    text = String(try box.decode(Double.self))
                }
            }
        }

        /// One undecodable element does not sink the whole array.
        struct Lossy<Value: Decodable>: Decodable {
            let value: Value?
            init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
        }

        struct File: Decodable {
            let id: String
            let result: Int
            let consumerApp: Int64?
            let creator: String?
            let size: Int64
            let previewURL: String?
            let title: String?
            let summary: String
            let updated: Int64?
            let visibility: Int64
            let banned: Bool
            let banReason: String
            let subscriptions: Int64?
            let tags: [String]

            private enum Keys: String, CodingKey {
                case id = "publishedfileid", result, creator, title, visibility, banned, subscriptions, tags
                case consumerApp = "consumer_app_id", consumerAppAlt = "consumer_appid"
                case size = "file_size", previewURL = "preview_url", updated = "time_updated", banReason = "ban_reason"
                case shortDescription = "short_description", fileDescription = "file_description", description
            }
            private struct TagBox: Decodable { let tag: String? }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                func flexible(_ key: Keys) -> Int64? { (try? c.decodeIfPresent(StringOrInt.self, forKey: key))?.number }
                func string(_ key: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
                id = try c.decode(StringOrInt.self, forKey: .id).text
                guard Link.isItemNumber(id) else {   // the id becomes a folder name: digits only
                    throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "not an item number")
                }
                result = Int(flexible(.result) ?? 1)
                consumerApp = flexible(.consumerApp) ?? flexible(.consumerAppAlt)
                creator = (try? c.decodeIfPresent(StringOrInt.self, forKey: .creator))?.text
                size = flexible(.size) ?? 0
                previewURL = string(.previewURL)
                title = string(.title)
                summary = [Keys.shortDescription, .fileDescription, .description]
                    .compactMap { string($0).map(Wire.stripBBCode) }.first { !$0.isEmpty } ?? ""
                updated = flexible(.updated)
                visibility = flexible(.visibility) ?? 0
                banned = (flexible(.banned) ?? 0) != 0
                banReason = string(.banReason) ?? ""
                subscriptions = flexible(.subscriptions)
                let boxes = (try? c.decodeIfPresent([Lossy<TagBox>].self, forKey: .tags)) ?? []
                tags = boxes.compactMap { $0.value?.tag }
            }

            /// The item, or why Steam will not serve it (E1 `result` codes: 9 not found, 15 access denied).
            func workshopItem() throws -> WorkshopItem {
                switch result {
                case 1: break
                case 9: throw WorkshopError.itemNotFound
                case 15: throw WorkshopError.itemUnavailable(banReason)
                default: throw WorkshopError.network("Steam answered with code \(result)")
                }
                if banned { throw WorkshopError.itemUnavailable(banReason) }
                if visibility == 1 || visibility == 2 { throw WorkshopError.itemUnavailable("") }
                if let app = consumerApp, String(app) != appID { throw WorkshopError.notWallpaperEngineItem }
                return WorkshopItem(
                    id: id, title: (title ?? "").isEmpty ? "Workshop item \(id)" : title ?? "", summary: summary,
                    previewURL: previewURL.flatMap(URL.init(string:)), sizeBytes: size, tags: tags,
                    kind: Wire.kind(of: tags), creatorSteamID: creator,
                    updated: updated.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    subscriptions: subscriptions.map { Int($0) })
            }
        }

        /// `response` of GetPublishedFileDetails and QueryFiles.
        struct Response: Decodable {
            let files: [File]
            let nextCursor: String?

            private enum Keys: String, CodingKey { case files = "publishedfiledetails", nextCursor = "next_cursor" }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                files = ((try? c.decodeIfPresent([Lossy<File>].self, forKey: .files)) ?? []).compactMap { $0.value }
                nextCursor = try? c.decodeIfPresent(String.self, forKey: .nextCursor)
            }
        }

        struct Envelope: Decodable { let response: Response }

        /// First of Video, Scene, Web, Application among the tags; none -> unknown.
        static func kind(of tags: [String]) -> WorkshopItem.Kind {
            for tag in tags {
                if let kind = WorkshopItem.Kind(rawValue: tag.lowercased()), kind != .unknown { return kind }
            }
            return .unknown
        }

        /// Steam descriptions are BBCode: drop the markup, keep the words, collapse the whitespace.
        static func stripBBCode(_ text: String) -> String {
            let inline = "b|i|u|s|strike|url|code|spoiler|noparse"
            let block = "h[1-6]|list|olist|quote|table|tr|td|th|p|hr|center"
            return text
                .replacingOccurrences(of: "(?is)\\[(img|previewyoutube|previewimage)[^\\]]*\\].*?\\[/\\1\\]", with: " ",
                                      options: .regularExpression)
                .replacingOccurrences(of: "\\[\\*\\]", with: " • ", options: .regularExpression)
                .replacingOccurrences(of: "(?i)\\[/?(?:\(block))(?:=[^\\]]*)?\\]", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "(?i)\\[/?(?:\(inline))(?:=[^\\]]*)?\\]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: Steam Web API: requests

extension WorkshopKit {
    enum API {
        static let base = "https://api.steampowered.com"
        static let pageSize = 24

        /// Ephemeral: no URL cache, no cookies (QueryFiles URLs carry the user's key).
        static let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = ["User-Agent": "LiveWallpaper/2.0"]
            return URLSession(configuration: configuration)
        }()

        struct Browse {
            let key: String
            let sort: WorkshopSort
            let text: String
            let mature: Bool
            let cursor: String
        }

        struct Page {
            let items: [WorkshopItem]
            let next: String?
            let rawCount: Int
        }

        /// E1: public, no key. POST form body built by hand.
        static func details(id: String) async throws -> WorkshopItem {
            guard let file = try await send(detailsRequest(id: id), keyed: false).files.first else {
                throw WorkshopError.itemNotFound
            }
            return try file.workshopItem()
        }

        static func detailsRequest(id: String) -> URLRequest {
            var request = URLRequest(url: URL(string: base + "/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(query([("itemcount", "1"), ("publishedfileids[0]", id)]).utf8)
            return request
        }

        /// E2: needs the user's own Web API key.
        static func browse(_ browse: Browse) async throws -> Page {
            let response = try await send(URLRequest(url: queryURL(browse)), keyed: true)
            return Page(items: response.files.compactMap { try? $0.workshopItem() },
                        next: response.nextCursor, rawCount: response.files.count)
        }

        static func queryURL(_ browse: Browse) -> URL {
            let text = browse.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var pairs: [(String, String)] = [("key", browse.key), ("appid", appID), ("creator_appid", appID)]
            if !text.isEmpty {
                pairs += [("query_type", "12"), ("search_text", text)]   // RankedByTextSearch
            } else {
                switch browse.sort {
                case .trending: pairs += [("query_type", "3"), ("days", "7")]   // RankedByTrend
                case .newest: pairs.append(("query_type", "1"))                 // RankedByPublicationDate
                case .popular: pairs.append(("query_type", "9"))                // RankedByTotalUniqueSubscriptions
                }
            }
            pairs += [("cursor", browse.cursor), ("numperpage", String(pageSize)), ("requiredtags[0]", "Video")]
            if !browse.mature { pairs += [("excludedtags[0]", "Questionable"), ("excludedtags[1]", "Mature")] }
            pairs += [("return_tags", "true"), ("return_short_description", "true"), ("return_previews", "false"),
                      ("return_vote_data", "false"), ("return_metadata", "false")]
            return URL(string: base + "/IPublishedFileService/QueryFiles/v1/?" + query(pairs))!
        }

        /// `URLSession.data(for:)`. The Linux test toolchain (swift-corelibs-foundation 5.10) has no async URLSession API.
        static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            #if canImport(FoundationNetworking)
            return try await withCheckedThrowingContinuation { continuation in
                session.dataTask(with: request) { data, response, error in
                    if let data, let response { continuation.resume(returning: (data, response)) }
                    else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
                }.resume()
            }
            #else
            return try await session.data(for: request)
            #endif
        }

        /// Sends the request and maps every failure to a WorkshopError (cancellation passes through).
        private static func send(_ request: URLRequest, keyed: Bool) async throws -> Wire.Response {
            var request = request
            request.timeoutInterval = 20
            do {
                let (data, response) = try await fetch(request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let status = http.statusCode
                    if keyed && (status == 401 || status == 403) { throw WorkshopError.apiKeyRejected }
                    throw status == 429 ? WorkshopError.rateLimited : WorkshopError.network("Steam answered HTTP \(status)")
                }
                guard let envelope = try? JSONDecoder().decode(Wire.Envelope.self, from: data) else {
                    throw WorkshopError.network("unexpected answer from Steam")
                }
                return envelope.response
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw WorkshopError.network(describe(error.code))
            }
        }

        /// Fixed wording instead of `localizedDescription`, so a request URL (and with it the key) can never leak.
        private static func describe(_ code: URLError.Code) -> String {
            switch code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "no internet connection"
            case .timedOut: return "the request timed out"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Steam couldn’t be reached"
            default: return "network error \(code.rawValue)"
            }
        }
    }
}

// MARK: steamcmd: invocation and output

extension WorkshopKit {
    enum Invocation {
        private static let usernameCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

        /// Steam account names. steamcmd reads `+`-prefixed argv as commands and `-` as options, so neither may lead.
        static func isValidUsername(_ name: String) -> Bool {
            (2...64).contains(name.count) && !name.hasPrefix("-")
                && name.unicodeScalars.allSatisfy { usernameCharacters.contains($0) }
        }

        /// Stdin is closed and `@NoPromptForPassword 1` makes steamcmd fail instead of asking, so no password or
        /// Steam Guard code can ever pass through this app. force_install_dir has to come before login.
        static func download(user: String, id: String) -> [String] {
            ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1",
             "+force_install_dir", AppPaths.steamStagingDirectory.path,
             "+login", user, "+workshop_download_item", appID, id, "+quit"]
        }

        static func loginCheck(user: String) -> [String] {
            ["+@NoPromptForPassword", "1", "+login", user, "+quit"]
        }
    }

    /// What one steamcmd invocation did.
    struct Run {
        var decisive: Output.Event?       // the first success/failure line (or the event a sign-in check stops on)
        var exitCode: Int32?
        var lastLine = ""
        var errorLine = ""
        var timedOut = false
        var cancelled = false

        /// The most telling line for an error message.
        var detail: String { errorLine.isEmpty ? lastLine : errorLine }
    }

    enum Output {
        enum Event: Equatable {
            case signedIn, downloading, selfUpdating
            case progress(Double)             // 0...1
            case success(String?)             // the content folder steamcmd reported, if it did
            case failure(WorkshopError)
        }

        /// One output line -> what it means. Case-insensitive substrings; wording that is not verified against a
        /// real macOS steamcmd is marked in SPEC2.md 4.7.
        static func classify(_ line: String) -> Event? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let text = trimmed.lowercased()
            func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
            if has("bad cpu type") { return .failure(.rosettaMissing) }
            if has("downloaded item") { return .success(quotedPath(in: trimmed)) }
            if has("rate limit exceeded") { return .failure(.rateLimited) }
            let loggingIn = text.contains("logging in user")
            if has("no cached credentials", "password:", "invalid password", "login failure", "two-factor",
                   "steam guard", "steam mobile app", "not logged on") || (loggingIn && text.contains("failed")) {
                return .failure(.needsLogin)
            }
            if has("logged in ok", "waiting for user info...ok") || (loggingIn && text.hasSuffix("ok")) { return .signedIn }
            if text.hasPrefix("error!") { return .failure(errorReason(trimmed)) }
            if has("downloading item") { return .downloading }
            if has("checking for available updates", "downloading update", "verifying installation", "extracting package") {
                return .selfUpdating
            }
            if let percent = number(after: "progress:", in: text) { return .progress(min(max(percent / 100, 0), 1)) }
            return nil
        }

        /// `ERROR! Download item <id> failed (<reason>).` and other `ERROR!` lines.
        static func errorReason(_ line: String) -> WorkshopError {
            let text = line.lowercased()
            if text.contains("download item"), text.contains(" failed"),
               let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close {
                let reason = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                switch reason.lowercased() {
                case "failure", "access denied", "no subscription": return .notOwned
                case "no connection": return .network("SteamCMD lost its connection to Steam")
                case "timeout": return .timedOut
                case "file not found": return .itemNotFound
                default: return .steamcmdFailed(reason)
                }
            }
            if text.contains("timeout downloading item") { return .timedOut }
            return .steamcmdFailed(clean(line))
        }

        /// An unfinished line that asks for a secret (`password:`, `Steam Guard code:`). Only prompts count here:
        /// a half-printed status line must wait for its newline.
        static func isPrompt(_ partial: String) -> Bool {
            let text = partial.trimmingCharacters(in: .whitespaces).lowercased()
            return text.hasSuffix(":") && ["password", "code", "guard"].contains { text.contains($0) }
        }

        static func isDecisive(_ event: Event) -> Bool {
            switch event {
            case .success, .failure: return true
            case .signedIn, .downloading, .selfUpdating, .progress: return false
            }
        }

        /// Failures where waiting for steamcmd to exit on its own would only hang on a prompt or a retry loop.
        static func endsAtOnce(_ event: Event) -> Bool {
            switch event {
            case .failure(.needsLogin), .failure(.rosettaMissing), .failure(.rateLimited): return true
            default: return false
            }
        }

        static func downloadResult(_ run: Run) -> Result<String?, WorkshopError> {
            if run.cancelled { return .failure(.cancelled) }
            switch run.decisive {
            case .failure(let error)?: return .failure(error)
            case .success(let path)?: return .success(path)
            default: break
            }
            if run.timedOut { return .failure(.timedOut) }
            return run.exitCode == 0 ? .success(nil) : .failure(.steamcmdFailed(run.detail))
        }

        static func loginResult(_ run: Run) -> SteamLoginState {
            if run.cancelled { return .unknown }
            switch run.decisive {
            case .signedIn?: return .loggedIn
            case .failure(.needsLogin)?: return .needsLogin
            case .failure(let error)?: return .failed(error)
            default: return .failed(run.timedOut ? .timedOut : .steamcmdFailed(run.detail))
            }
        }

        /// The folder in `Success. Downloaded item <id> to "<path>" (<n> bytes)`.
        static func quotedPath(in line: String) -> String? {
            guard let open = line.firstIndex(of: "\"") else { return nil }
            let rest = line[line.index(after: open)...]
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            let path = String(rest[..<close])
            return path.hasPrefix("/") ? path : nil
        }

        private static func number(after marker: String, in text: String) -> Double? {
            guard let range = text.range(of: marker) else { return nil }
            return Double(text[range.upperBound...].drop { $0 == " " }.prefix { $0.isASCII && ($0.isNumber || $0 == ".") })
        }

        /// A line for a message: control characters and escape sequences removed, at most 200 characters.
        static func clean(_ line: String) -> String {
            let plain = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            let printable = String(String.UnicodeScalarView(plain.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            return String(printable.trimmingCharacters(in: .whitespaces).prefix(200))
        }

        /// Splits the raw byte stream into lines. steamcmd redraws progress with `\r` and its prompts have no
        /// newline, so both `\r` and `\n` end a line, and the unfinished tail stays readable. Bytes, not text:
        /// a multi-byte character may be cut by a read boundary.
        struct LineBuffer {
            private var pending = Data()
            var partialText: String { String(decoding: pending, as: UTF8.self) }

            mutating func append(_ data: Data) -> [String] {
                pending.append(data)
                var lines: [String] = []
                while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...end)
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
                }
                if pending.count > 16_384 { pending = Data(pending.suffix(16_384)) }
                return lines
            }
        }
    }
}

// MARK: steamcmd: process

extension WorkshopKit {
    /// One running steamcmd. Output, exit and a 500 ms tick arrive on one stream, so the consumer is a single
    /// sequential loop. Everything here is safe to call from any thread.
    final class Child: @unchecked Sendable {
        enum Event: Sendable { case output(Data), eof, exited(Int32), tick }

        let events: AsyncStream<Event>
        private let continuation: AsyncStream<Event>.Continuation
        private let process = Process()
        private let pipe = Pipe()
        private var ticker: Task<Void, Never>?

        init(executable: String, arguments: [String], directory: URL) {
            var made: AsyncStream<Event>.Continuation!
            events = AsyncStream { made = $0 }
            continuation = made
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "dumb"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
        }

        /// Throws when the executable cannot be started (missing, wrong architecture).
        func start() throws {
            let continuation = self.continuation
            pipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil      // EOF: an uncleared handler on a closed pipe spins a core
                    continuation.yield(.eof)
                } else {
                    continuation.yield(.output(data))
                }
            }
            process.terminationHandler = { finished in continuation.yield(.exited(finished.terminationStatus)) }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                throw error
            }
            try? pipe.fileHandleForWriting.close()       // only the child keeps the write end, so EOF can arrive
            ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continuation.yield(.tick)
                }
            }
        }

        /// SIGTERM to steamcmd and everything it started (steamcmd.sh does not exec the binary, so ending only the
        /// script would orphan it), SIGKILL for whatever is left two seconds later.
        func terminate() {
            guard process.isRunning else { return }
            let targets = Self.descendants(of: process.processIdentifier) + [process.processIdentifier]
            for target in targets { kill(target, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                for target in targets where kill(target, 0) == 0 { kill(target, SIGKILL) }
            }
        }

        func finish() {
            ticker?.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.finish()
        }

        /// Children and grandchildren of `root`, deepest first.
        static func descendants(of root: Int32) -> [Int32] {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "pid=,ppid="]
            let output = Pipe()
            ps.standardInput = FileHandle.nullDevice
            ps.standardOutput = output
            ps.standardError = FileHandle.nullDevice
            guard (try? ps.run()) != nil else { return [] }
            try? output.fileHandleForWriting.close()
            var children: [Int32: [Int32]] = [:]
            let table = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            for line in table.split(separator: "\n") {
                let numbers = line.split(separator: " ").compactMap { Int32($0) }
                if numbers.count == 2 { children[numbers[1], default: []].append(numbers[0]) }
            }
            var found: [Int32] = []
            var frontier = [root]
            while let parent = frontier.popLast() {
                for child in children[parent] ?? [] { found.append(child); frontier.append(child) }
            }
            return found.reversed()
        }
    }

    /// Drives one steamcmd invocation to its end: classifies output as it arrives, reports progress, enforces the
    /// idle timeout, ends the process after a decisive line (steamcmd can fail to exit on macOS) and on cancel.
    @MainActor final class Runner {
        struct Limits {
            var idle: TimeInterval = 120         // no output and no growth of the download folder
            var selfUpdate: TimeInterval = 600   // the same while steamcmd updates itself (first run)
            var grace: TimeInterval = 5          // from a decisive line to ending the process
        }

        private let executable: String
        private let limits: Limits
        private var child: Child?
        private var cancelled = false

        init(executable: String, limits: Limits = Limits()) {
            self.executable = executable
            self.limits = limits
        }

        func cancel() {
            cancelled = true
            child?.terminate()
        }

        /// `onEvent` sees every classified line; `onTick` runs every 500 ms and returns true when the download
        /// folder grew. `stopOn` marks extra events decisive (a sign-in check stops at `.signedIn`).
        func run(arguments: [String], stopOn: (Output.Event) -> Bool = { _ in false },
                 onEvent: (Output.Event) -> Void, onTick: () -> Bool) async throws -> Run {
            var run = Run()
            if cancelled { run.cancelled = true; return run }
            try? AppPaths.ensureDirectory(AppPaths.steamStagingDirectory)
            let child = Child(executable: executable, arguments: arguments, directory: AppPaths.steamStagingDirectory)
            try child.start()
            self.child = child
            defer { child.finish(); self.child = nil }

            var buffer = Output.LineBuffer()
            var idleSince = Date()
            var decidedAt: Date?
            var selfUpdating = false, ending = false, exited = false, eof = false
            var ticksSinceExit = 0

            func end() {
                if !ending { ending = true; child.terminate() }
            }
            func see(_ event: Output.Event) {
                if event == .selfUpdating { selfUpdating = true } else if event == .signedIn { selfUpdating = false }
                onEvent(event)
                guard run.decisive == nil, Output.isDecisive(event) || stopOn(event) else { return }
                run.decisive = event
                decidedAt = Date()
                if Output.endsAtOnce(event) { end() }
            }
            func consume(_ line: String) {
                run.lastLine = Output.clean(line)
                let text = line.lowercased()
                if text.contains("error") || text.contains("fail") { run.errorLine = run.lastLine }
                if let event = Output.classify(line) { see(event) }
            }

            for await event in child.events {
                switch event {
                case .output(let data):
                    idleSince = Date()
                    for line in buffer.append(data) { consume(line) }
                    // A password prompt has no newline; do not wait for one.
                    if run.decisive == nil, Output.isPrompt(buffer.partialText) { see(.failure(.needsLogin)) }
                case .tick:
                    let now = Date()
                    if onTick() { idleSince = now }
                    if let decidedAt {
                        if now.timeIntervalSince(decidedAt) >= limits.grace { end() }
                    } else if now.timeIntervalSince(idleSince) >= (selfUpdating ? limits.selfUpdate : limits.idle) {
                        run.timedOut = true
                        end()
                    }
                    if exited { ticksSinceExit += 1 }
                case .eof:
                    eof = true
                case .exited(let code):
                    run.exitCode = code
                    exited = true
                }
                if exited && (eof || ticksSinceExit >= 1) { break }
            }
            if !buffer.partialText.isEmpty { consume(buffer.partialText) }   // a last line without a newline
            run.cancelled = cancelled
            return run
        }
    }

    /// `Process.run()` failures: POSIX 86 (bad CPU type) means an Intel steamcmd without Rosetta.
    static func launchError(_ error: Error) -> WorkshopError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 86 { return .rosettaMissing }
        return .steamcmdFailed("SteamCMD could not be started")
    }
}

// MARK: Where things are

extension WorkshopKit {
    enum Locate {
        /// `override` if it is runnable, else the first runnable of Homebrew's wrapper (Apple silicon, then Intel),
        /// the newest Homebrew cask copy and two manual install spots. GUI apps have a minimal PATH, so no `which`.
        static func steamcmd(override: String, home: URL, prefixes: [String] = ["/opt/homebrew", "/usr/local"]) -> String? {
            let custom = NSString(string: override.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
            let casks = prefixes.flatMap { prefix -> [String] in
                let root = prefix + "/Caskroom/steamcmd"
                let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
                    .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                return versions.map { "\(root)/\($0)/MacOS/steamcmd.sh" }
            }
            let candidates = [custom] + prefixes.map { $0 + "/bin/steamcmd" } + casks
                + [home.path + "/steamcmd/steamcmd.sh", home.path + "/Steam/steamcmd.sh"]
            // steamcmd.sh finds its binary next to itself, so a symlink to it must be followed.
            return candidates.first(where: runnable).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }

        static func runnable(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }

        /// steamcmd is an Intel binary: Apple silicon needs Rosetta (presence heuristic; "Bad CPU type" is the proof).
        static func rosettaReady() -> Bool {
            #if arch(arm64)
            return ["/Library/Apple/usr/libexec/oah/libRosettaRuntime", "/Library/Apple/usr/share/rosetta/rosetta"]
                .contains { FileManager.default.fileExists(atPath: $0) }
            #else
            return true
            #endif
        }

        /// Where steamcmd may keep `steamapps/workshop` (unverified on macOS, so all of them are checked): the staging
        /// folder, Steam's macOS data folder, next to steamcmd, ~/Steam.
        static func roots(steamcmd: String?, home: URL, staging: URL = AppPaths.steamStagingDirectory) -> [URL] {
            var roots = [staging, home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)]
            if let steamcmd {
                roots.append(URL(fileURLWithPath: steamcmd).resolvingSymlinksInPath().deletingLastPathComponent())
            }
            return roots + [home.appendingPathComponent("Steam", isDirectory: true)]
        }

        /// The downloaded item's folder: the path steamcmd itself reported, else the first root that holds a
        /// project.json for it.
        static func content(id: String, successPath: String?, roots: [URL]) -> URL? {
            let reported = successPath.map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? []
            let candidates = reported
                + roots.map { $0.appendingPathComponent("steamapps/workshop/content/\(appID)/\(id)", isDirectory: true) }
            return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
        }

        /// Bytes on disk for the item under `root` so far (steamcmd writes downloads/ first, then moves to content/).
        static func bytes(id: String, in root: URL) -> Int64 {
            ["downloads", "content"].map {
                folderSize(root.appendingPathComponent("steamapps/workshop/\($0)/\(appID)/\(id)"))
            }.max() ?? 0
        }

        private static func folderSize(_ url: URL) -> Int64 {
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
            var total: Int64 = 0
            while let file = files.nextObject() as? URL {
                let values = try? file.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }   // folders report their own size
            }
            return total
        }
    }

    /// The transient download area (AppPaths.steamStagingDirectory). Only this app writes to it, one download at a time.
    enum Staging {
        static var workshop: URL {
            AppPaths.steamStagingDirectory.appendingPathComponent("steamapps/workshop", isDirectory: true)
        }

        static func wipe() {
            try? FileManager.default.removeItem(at: workshop)
        }

        static func contains(_ url: URL) -> Bool {
            url.standardizedFileURL.path.hasPrefix(AppPaths.steamStagingDirectory.standardizedFileURL.path + "/")
        }
    }
}

// MARK: Import into Library/<id>/

extension WorkshopKit {
    enum Import {
        /// The fields of Wallpaper Engine's project.json that matter here (all optional; unverified, SPEC2.md 4.4).
        struct Project: Equatable {
            var title: String?
            var type: String?      // lower-cased
            var file: String?
            var preview: String?
        }

        static let playableExtensions: Set<String> = ["mp4", "m4v", "mov"]
        private static let otherVideoExtensions: Set<String> = ["webm", "avi", "wmv", "mkv", "flv", "mpg", "mpeg", "ogv"]
        private static let imageExtensions = ["jpg": "jpg", "jpeg": "jpg", "png": "png", "gif": "gif"]

        /// Tolerates a UTF-8 BOM and unknown fields; unreadable JSON gives an empty project (the item's tags
        /// already said it is a video, and the file is still checked).
        static func parseProject(_ data: Data) -> Project {
            let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return Project() }
            var fields: [String: String] = [:]
            for (key, value) in object {
                if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    fields[key.lowercased()] = text
                }
            }
            return Project(title: fields["title"], type: fields["type"]?.lowercased(), file: fields["file"],
                           preview: fields["preview"])
        }

        /// `relative` inside `directory`, or nil when it is absolute, climbs out with `..` or leaves through a symlink.
        static func safeChild(of directory: URL, _ relative: String) -> URL? {
            guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
                  !relative.split(separator: "/").contains("..") else { return nil }
            let base = directory.standardizedFileURL.resolvingSymlinksInPath()
            let url = directory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            return url.path.hasPrefix(base.path + "/") ? url : nil
        }

        /// project.json's `file`, else the first playable file, else the first file of a format we cannot play
        /// (so the error can name it).
        static func chooseVideo(_ project: Project, in content: URL) -> URL? {
            let fileManager = FileManager.default
            if let name = project.file, let url = safeChild(of: content, name), fileManager.fileExists(atPath: url.path) {
                return url
            }
            let files = ((try? fileManager.contentsOfDirectory(atPath: content.path)) ?? []).sorted()
                .map { content.appendingPathComponent($0) }
            return files.first { playableExtensions.contains($0.pathExtension.lowercased()) }
                ?? files.first { otherVideoExtensions.contains($0.pathExtension.lowercased()) }
        }

        /// File type from the first bytes (never from a URL or a server's say-so).
        static func imageExtension(of data: Data) -> String? {
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            if data.starts(with: Array("GIF8".utf8)) { return "gif" }
            return nil
        }

        /// Validates the downloaded content and moves (inside staging) or copies it into Library/<id>/, replacing an
        /// older copy. Nothing half-written is left behind on failure.
        static func run(item: WorkshopItem, content: URL, moveFiles: Bool) async throws -> VideoItem {
            let fileManager = FileManager.default
            let projectFile = content.appendingPathComponent("project.json")
            let project = parseProject((try? Data(contentsOf: projectFile)) ?? Data())
            if let type = project.type, type != "video" {
                throw WorkshopError.unsupportedType(WorkshopItem.Kind(rawValue: type) ?? .unknown)
            }
            guard let source = chooseVideo(project, in: content) else { throw WorkshopError.contentMissing }
            let ext = source.pathExtension.lowercased()
            guard playableExtensions.contains(ext) else { throw WorkshopError.unsupportedFormat(ext.isEmpty ? "unknown" : ext) }
            try await requirePlayable(source)

            let partial = AppPaths.libraryDirectory.appendingPathComponent(item.id + ".partial", isDirectory: true)
            let folder = AppPaths.libraryDirectory.appendingPathComponent(item.id, isDirectory: true)
            var previewName: String?
            do {
                try? fileManager.removeItem(at: partial)
                try AppPaths.ensureDirectory(partial)
                try place(source, at: partial.appendingPathComponent("video." + ext), move: moveFiles)
                previewName = await placePreview(in: partial, project: project, content: content,
                                                 remote: item.previewURL, move: moveFiles)
                try? fileManager.copyItem(at: projectFile, to: partial.appendingPathComponent("project.json"))
                try? fileManager.removeItem(at: folder)
                try fileManager.moveItem(at: partial, to: folder)
            } catch {
                try? fileManager.removeItem(at: partial)
                throw WorkshopError.importFailed(error.localizedDescription)
            }
            return VideoItem(
                path: folder.appendingPathComponent("video." + ext).standardizedFileURL.path,
                title: project.title ?? item.title, author: item.author, workshopID: item.id,
                previewPath: previewName.map { folder.appendingPathComponent($0).standardizedFileURL.path },
                tags: item.tags.isEmpty ? nil : item.tags)
        }

        /// AVFoundation must be able to play it (no VP9/AV1 surprises); nothing is ever converted.
        private static func requirePlayable(_ url: URL) async throws {
            #if canImport(AVFoundation)
            let asset = AVURLAsset(url: url)
            var playable = false
            if (try? await asset.load(.isPlayable)) == true, let tracks = try? await asset.loadTracks(withMediaType: .video) {
                playable = !tracks.isEmpty
            }
            if !playable { throw WorkshopError.unsupportedCodec }
            #endif
        }

        /// The preview image: project.json's own file when it has one, else the item's preview_url (https only,
        /// at most 8 MB, type from the bytes). No preview is not an error.
        private static func placePreview(in directory: URL, project: Project, content: URL, remote: URL?,
                                         move: Bool) async -> String? {
            if let name = project.preview, let source = safeChild(of: content, name),
               let ext = imageExtensions[source.pathExtension.lowercased()],
               (try? place(source, at: directory.appendingPathComponent("preview." + ext), move: move)) != nil {
                return "preview." + ext
            }
            let request = remote.map { URLRequest(url: $0, timeoutInterval: 20) }
            if let request, request.url?.scheme == "https", let (data, response) = try? await API.fetch(request),
               (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_000_000, let ext = imageExtension(of: data),
               (try? data.write(to: directory.appendingPathComponent("preview." + ext))) != nil {
                return "preview." + ext
            }
            return nil
        }

        private static func place(_ source: URL, at target: URL, move: Bool) throws {
            if move { try FileManager.default.moveItem(at: source, to: target) }
            else { try FileManager.default.copyItem(at: source, to: target) }
        }
    }
}
