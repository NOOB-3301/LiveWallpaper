import SwiftUI
import AppKit
import Core

// Views for the Workshop and Steam Setup tabs, built strictly on the WorkshopModel surface in Workshop.swift.
// Layout, states and microcopy: SPEC2.md sections 5.4 to 5.6. No password or Steam Guard field exists here;
// signing in happens once in Terminal.

// MARK: - Shared pieces

private let apiKeyPage = URL(string: "https://steamcommunity.com/dev/apikey")!

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(text, forType: .string)
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
    }
}

private func cardInfoLine(_ item: WorkshopItem) -> String {
    var parts: [String] = []
    if item.sizeBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) }
    if let updated = item.updated { parts.append("updated " + updated.formatted(date: .abbreviated, time: .omitted)) }
    if let author = item.author { parts.append("by " + author) }
    return parts.joined(separator: " · ")
}

/// Videos 3840 pixels wide or more need a lot of memory and battery.
private func isHighResolution(_ item: WorkshopItem) -> Bool {
    guard let width = item.resolutionTag?.split(separator: " ").first.flatMap({ Int($0) }) else { return false }
    return width >= 3840
}

/// A pasted link or item number worth looking up without waiting for the button.
private func looksLikeWorkshopItem(_ text: String) -> Bool {
    if (6...20).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
    let lowered = text.lowercased()
    return lowered.contains("filedetails") || lowered.contains("communityfilepage")
}

@MainActor
private struct FixButton: View {
    let fix: WorkshopFix
    let workshop: WorkshopModel
    let retry: () -> Void
    let openSteamSetup: () -> Void

    var body: some View { Button(title, action: run) }

    private var title: String {
        switch fix {
        case .openSteamSetup: return "Open Steam Setup"
        case .copyLoginCommand: return "Copy login command"
        case .copyBrewCommand: return "Copy brew command"
        case .copyRosettaCommand: return "Copy Rosetta command"
        case .openAPIKeyPage: return "Open the API key page"
        case .retry: return "Retry"
        }
    }

    private func run() {
        switch fix {
        case .openSteamSetup: openSteamSetup()
        case .copyLoginCommand: copyToPasteboard(workshop.loginCommand)
        case .copyBrewCommand: copyToPasteboard(workshop.brewInstallCommand)
        case .copyRosettaCommand: copyToPasteboard(workshop.rosettaInstallCommand)
        case .openAPIKeyPage: NSWorkspace.shared.open(apiKeyPage)
        case .retry: retry()
        }
    }
}

/// An error in the words of `WorkshopError`: bold orange title, secondary message, the fix button if any.
@MainActor
private struct FailureView: View {
    let error: WorkshopError
    let workshop: WorkshopModel
    let retry: () -> Void
    let openSteamSetup: () -> Void
    var dismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.title).font(.subheadline.weight(.bold)).foregroundStyle(.orange)
            Text(error.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let fix = error.fix {
                    FixButton(fix: fix, workshop: workshop, retry: retry, openSteamSetup: openSteamSetup)
                }
                if let dismiss { Button("Dismiss", action: dismiss).buttonStyle(.link) }
            }
            .controlSize(.small)
        }
    }
}

@MainActor
private struct PreviewImage: View {
    let url: URL?

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
private struct Chip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text).font(.caption)
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill((tint ?? Color.secondary).opacity(0.18)))
    }
}

@MainActor
private struct ChipRow: View {
    let item: WorkshopItem

    var body: some View {
        HStack(spacing: 6) {
            if item.kind != .unknown {
                Chip(text: item.kind.rawValue.capitalized, tint: item.isVideo ? Color.accentColor : Color.orange)
            }
            if let resolution = item.resolutionTag { Chip(text: resolution) }
            if let rating = item.ratingTag { Chip(text: rating) }
            if isHighResolution(item) {
                Chip(text: "High resolution", tint: .orange).help("Large videos use more memory and battery")
            }
        }
    }
}

// MARK: - Item cards

/// What a card's action area shows, from the download state and the library.
private enum CardAction {
    case download, cantPlay, inLibrary(added: Bool)
    case queued, signingIn, downloading(Double?), importing
    case failed(WorkshopError)

    static func make(item: WorkshopItem, state: WorkshopDownloadState?, inLibrary: Bool) -> CardAction {
        switch state {
        case .queued?: return .queued
        case .signingIn?: return .signingIn
        case .downloading(let progress)?: return .downloading(progress)
        case .importing?: return .importing
        case .failed(let error)?: return .failed(error)
        case .done?: return inLibrary ? .inLibrary(added: true) : .download
        case nil: break
        }
        if inLibrary { return .inLibrary(added: false) }
        return item.isVideo ? .download : .cantPlay
    }
}

@MainActor
private struct CardActions: View {
    let item: WorkshopItem
    let action: CardAction
    let ready: Bool          // Steam setup is complete
    let compact: Bool
    let workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let showInLibrary: () -> Void

    var body: some View {
        switch action {
        case .download: downloadButton
        case .cantPlay: cantPlay
        case .inLibrary(let added): inLibrary(added: added)
        case .queued: progress("Waiting…")
        case .signingIn: progress("Signing in to Steam…", spinner: true)
        case .downloading(let value): downloading(value)
        case .importing: progress("Adding to your library…", spinner: true, cancellable: false)
        case .failed(let error):
            FailureView(error: error, workshop: workshop, retry: { workshop.download(item) },
                        openSteamSetup: openSteamSetup, dismiss: { workshop.dismissDownload(item.id) })
        }
    }

    private var downloadButton: some View {
        let size = item.sizeBytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file) : ""
        return Button { workshop.download(item) } label: { Label("Download" + size, systemImage: "arrow.down.circle") }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
            .disabled(!ready)
            .help(ready ? "" : "Finish Steam Setup first")
    }

    private var cantPlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Can’t be played") {}.disabled(true).controlSize(compact ? .small : .regular)
            Text(WorkshopError.unsupportedType(item.kind).message).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inLibrary(added: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(added ? "Added to Library" : "In Library").font(compact ? .caption : .subheadline)
            Button("Show in Library", action: showInLibrary).buttonStyle(.link).font(compact ? .caption : .subheadline)
        }
    }

    private func downloading(_ value: Double?) -> some View {
        guard let value else { return progress("Downloading…", spinner: true) }
        let clamped = min(max(value, 0), 1)
        return progress("Downloading… \(Int((clamped * 100).rounded()))%", fraction: clamped)
    }

    /// `fraction` shows a bar, `spinner` an indeterminate spinner; cancelling is offered unless `cancellable` is off.
    private func progress(_ label: String, fraction: Double? = nil, spinner: Bool = false, cancellable: Bool = true) -> some View {
        HStack(spacing: 8) {
            if let fraction { ProgressView(value: fraction).frame(width: compact ? 80 : 140) }
            if spinner { ProgressView().controlSize(.small) }
            Text(label).font(.caption).foregroundStyle(.secondary)
            if cancellable {
                Button { workshop.cancelDownload(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Cancel").accessibilityLabel("Cancel download")
            }
        }
    }
}

@MainActor
private struct ResultCard<Actions: View>: View {
    let item: WorkshopItem
    let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PreviewImage(url: item.previewURL).frame(width: 192, height: 108)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.headline).lineLimit(2)
                ChipRow(item: item)
                Text(cardInfoLine(item)).font(.caption).foregroundStyle(.secondary)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .cardStyle()
    }
}

@MainActor
private struct CompactCard<Actions: View>: View {
    let item: WorkshopItem
    let actions: Actions

    private var info: String {
        var parts: [String] = []
        if item.sizeBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) }
        if let resolution = item.resolutionTag { parts.append(resolution) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PreviewImage(url: item.previewURL)
            Text(item.title).font(.subheadline).lineLimit(2, reservesSpace: true)
            Text(info).font(.caption).foregroundStyle(.secondary)
            actions
        }
        .cardStyle()
    }
}

// MARK: - Workshop tab

/// Workshop tab: paste field + result card, optional browse grid (needs an API key), setup banner.
@MainActor
struct WorkshopView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void
    @State private var browsed = false

    // RootView (another file) builds this view; spelling the init out keeps the private @State from affecting it.
    init(model: SettingsModel, workshop: WorkshopModel,
         openSteamSetup: @escaping () -> Void, openLibrary: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._workshop = ObservedObject(wrappedValue: workshop)
        self.openSteamSetup = openSteamSetup
        self.openLibrary = openLibrary
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !workshop.setup.canDownload { setupBanner }
                pasteRow
                lookupSection
                if workshop.canBrowse { browseSection } else { keyHint }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { workshop.recheckSetup() }
    }

    private var setupBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Finish the Steam setup to download wallpapers.")
            Spacer()
            Button("Open Steam Setup", action: openSteamSetup)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.15)))
    }

    private var pasteRow: some View {
        HStack(spacing: 8) {
            TextField("Paste a Workshop link or item number", text: $workshop.pastedText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { workshop.lookUp() }
            Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            Button("Look Up") { workshop.lookUp() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(workshop.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .task(id: workshop.pastedText) { await lookUpPastedText() }
    }

    private func paste() {
        if let text = NSPasteboard.general.string(forType: .string) { workshop.pastedText = text }
    }

    /// Looks a plausible link or number up once typing or pasting has paused.
    private func lookUpPastedText() async {
        let text = workshop.pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeWorkshopItem(text) else { return }
        if case .found(let item) = workshop.lookup, text.contains(item.id) { return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if !Task.isCancelled { workshop.lookUp() }
    }

    @ViewBuilder private var lookupSection: some View {
        switch workshop.lookup {
        case .idle:
            if !workshop.canBrowse { emptyState }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up…").foregroundStyle(.secondary)
            }
        case .found(let item):
            ResultCard(item: item, actions: actions(for: item, compact: false))
        case .failed(let error):
            FailureView(error: error, workshop: workshop, retry: { workshop.lookUp() }, openSteamSetup: openSteamSetup)
                .cardStyle()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Download video wallpapers from Steam").font(.title3)
            Text("Paste a Workshop link or item number above. Only video wallpapers can play.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func actions(for item: WorkshopItem, compact: Bool) -> some View {
        CardActions(item: item,
                    action: CardAction.make(item: item, state: workshop.downloads[item.id], inLibrary: workshop.isInLibrary(item.id)),
                    ready: workshop.setup.canDownload, compact: compact, workshop: workshop,
                    openSteamSetup: openSteamSetup, showInLibrary: { showInLibrary(item) })
    }

    private func showInLibrary(_ item: WorkshopItem) {
        if let video = model.videos.first(where: { $0.workshopID == item.id }) { model.selectedID = video.id }
        openLibrary()
    }

    // MARK: Browse

    private var keyHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("Browsing needs a free Steam Web API key. Add one in Steam Setup, or paste a link above.")
            Button("Steam Setup", action: openSteamSetup).buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse").font(.title3)
            browseControls
            browseResults
        }
        .task(id: "\(workshop.sort.rawValue)|\(workshop.searchText)|\(workshop.includeMature)") { await refreshBrowse() }
    }

    /// The first run loads (or keeps) the list at once; later changes of sort, search text or rating wait 400 ms.
    private func refreshBrowse() async {
        if !browsed {
            browsed = true
            if workshop.listState == .idle { workshop.search() }
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if !Task.isCancelled { workshop.search() }
    }

    private var browseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sort", selection: $workshop.sort) {
                ForEach(WorkshopSort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search video wallpapers", text: $workshop.searchText).textFieldStyle(.roundedBorder)
            }
            Toggle("Include questionable and mature", isOn: $workshop.includeMature).toggleStyle(.checkbox)
        }
    }

    @ViewBuilder private var browseResults: some View {
        if case .failed(let error) = workshop.listState {
            FailureView(error: error, workshop: workshop, retry: { workshop.search() }, openSteamSetup: openSteamSetup)
        }
        if workshop.listState == .loaded, workshop.results.isEmpty {
            Text("No video wallpapers found.").font(.callout).foregroundStyle(.secondary)
        }
        if !workshop.results.isEmpty { resultGrid }
        if workshop.listState == .loading {
            ProgressView().controlSize(.small)
        } else if workshop.canLoadMore {
            Button("Load More") { workshop.loadMore() }
        }
    }

    private var resultGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)], alignment: .leading, spacing: 16) {
            ForEach(workshop.results) { item in
                CompactCard(item: item, actions: actions(for: item, compact: true))
            }
        }
    }
}

// MARK: - Steam Setup tab

private enum SetupGlyph {
    case ok, warning, neutral, busy

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral, .busy: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .neutral, .busy: return .secondary
        }
    }
}

/// One checklist card: status glyph, title, optional detail, extra content below and actions on the right.
@MainActor
private struct SetupRow<Extra: View, Actions: View>: View {
    let glyph: SetupGlyph
    let title: String
    let detail: String?
    let extra: Extra
    let actions: Actions

    init(glyph: SetupGlyph, title: String, detail: String? = nil,
         @ViewBuilder extra: () -> Extra, @ViewBuilder actions: () -> Actions) {
        self.glyph = glyph
        self.title = title
        self.detail = detail
        self.extra = extra()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if glyph == .busy {
                ProgressView().controlSize(.small).frame(width: 20)
            } else {
                Image(systemName: glyph.symbol).foregroundStyle(glyph.color).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                extra
            }
            Spacer(minLength: 8)
            actions
        }
        .cardStyle()
    }
}

@MainActor
private struct CommandChip: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
    }
}

/// Steam Setup tab: the checklist (steamcmd, Rosetta, username, login, optional API key) and the licensing note.
@MainActor
struct SteamSetupView: View {
    @ObservedObject var workshop: WorkshopModel

    private static let loginSteps = [
        "1. Open Terminal.",
        "2. Run the command below.",
        "3. Enter your password and Steam Guard code when asked.",
        "4. Type quit, then come back and press Check Again.",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                steamcmdRow
                if !workshop.setup.rosettaOK { rosettaRow }
                accountRow
                signInRow
                apiKeyRow
                Text("Downloads use your own Steam account and Valve’s official SteamCMD. Workshop items belong to their creators; keep them for personal use and don’t redistribute. Live Wallpaper isn’t affiliated with Valve or Wallpaper Engine.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
        .onAppear { workshop.recheckSetup() }
        .task(id: [workshop.steamUsername, workshop.steamcmdPathOverride, workshop.apiKey]) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { workshop.recheckSetup() }
        }
    }

    /// Everything the sign-in check needs is in place.
    private var canCheckLogin: Bool {
        workshop.setup.steamcmdPath != nil && workshop.setup.rosettaOK && workshop.setup.usernameValid
    }

    private var steamcmdRow: some View {
        let path = workshop.setup.steamcmdPath
        return SetupRow(glyph: path == nil ? .warning : .ok, title: path == nil ? "SteamCMD isn’t installed" : "SteamCMD found") {
            if let path {
                Text(path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                HStack {
                    CommandChip(command: workshop.brewInstallCommand)
                    Button("Copy") { copyToPasteboard(workshop.brewInstallCommand) }
                }
                Link("No Homebrew? See brew.sh", destination: URL(string: "https://brew.sh")!).font(.caption)
            }
        } actions: {
            Button("Choose…") { chooseSteamcmd() }
            Button("Re-check") { workshop.recheckSetup() }
        }
    }

    private func chooseSteamcmd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the steamcmd program."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            workshop.steamcmdPathOverride = url.path
            workshop.recheckSetup()
        }
    }

    private var rosettaRow: some View {
        SetupRow(glyph: .warning, title: "Rosetta is needed",
                 detail: "SteamCMD is an Intel program. Apple silicon Macs need Rosetta installed once.") {
            CommandChip(command: workshop.rosettaInstallCommand)
        } actions: {
            Button("Copy") { copyToPasteboard(workshop.rosettaInstallCommand) }
        }
    }

    private var accountRow: some View {
        let name = workshop.steamUsername.trimmingCharacters(in: .whitespaces)
        let glyph: SetupGlyph = name.isEmpty ? .neutral : (workshop.setup.usernameValid ? .ok : .warning)
        return SetupRow(glyph: glyph, title: "Steam account") {
            TextField("Steam username", text: $workshop.steamUsername).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            Text("The account that owns Wallpaper Engine. Only the username is saved, never your password.")
                .font(.caption).foregroundStyle(.secondary)
            if glyph == .warning {
                Text("Use letters, numbers, dots, dashes or underscores.").font(.caption).foregroundStyle(.orange)
            }
        } actions: {}
    }

    @ViewBuilder private var signInRow: some View {
        switch workshop.setup.login {
        case .unknown:
            SetupRow(glyph: .neutral, title: "Not checked yet") {} actions: {
                Button("Check Sign-in") { workshop.checkLogin() }.disabled(!canCheckLogin)
            }
        case .checking:
            SetupRow(glyph: .busy, title: "Checking…") {} actions: {}
        case .loggedIn:
            SetupRow(glyph: .ok, title: "Signed in as \(workshop.steamUsername)") {} actions: {
                Button("Check Again") { workshop.checkLogin() }
            }
        case .needsLogin:
            SetupRow(glyph: .warning, title: "Sign in once in Terminal") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.loginSteps, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }
                CommandChip(command: workshop.loginCommand)
            } actions: {
                VStack(alignment: .trailing) {
                    Button("Copy Command") { copyToPasteboard(workshop.loginCommand) }
                    Button("Open Terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
                    Button("Check Again") { workshop.checkLogin() }.disabled(!canCheckLogin)
                }
            }
        case .failed(let error):
            SetupRow(glyph: .warning, title: error.title, detail: error.message) {} actions: {
                VStack(alignment: .trailing) {
                    if let fix = error.fix {
                        FixButton(fix: fix, workshop: workshop, retry: { workshop.checkLogin() }, openSteamSetup: {})
                    }
                    Button("Check Again") { workshop.checkLogin() }.disabled(!canCheckLogin)
                }
            }
        }
    }

    private var apiKeyRow: some View {
        SetupRow(glyph: workshop.canBrowse ? .ok : .neutral, title: "Steam Web API key (optional)") {
            SecureField("Web API key", text: $workshop.apiKey).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            Text("Only needed to browse and search. Stored on this Mac, in this app’s preferences.")
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            VStack(alignment: .trailing) {
                Link("Get a free key", destination: apiKeyPage)
                Button("Remove") { workshop.apiKey = "" }.disabled(workshop.apiKey.isEmpty)
            }
        }
    }
}
