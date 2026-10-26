import SwiftUI
import AppKit
import Core

// Views for the Workshop and Steam Setup tabs, built on the WorkshopModel surface in Workshop.swift. Result cards
// open the detail pane (WorkshopDetailView.swift); downloads live in their own page (DownloadsView.swift). Steam
// Setup is the in-app wizard (SteamWizardView.swift) plus an Advanced section.
//
// Layout stability rule: the browse task hangs off WorkshopView's root, whose identity never changes when the
// window is resized or the detail pane opens. Only a real change of the search inputs (sort, text, mature, kind)
// restarts it, and a restart keeps the previous results on screen while the new page loads.

// MARK: - Shared pieces

private let apiKeyPage = URL(string: "https://steamcommunity.com/dev/apikey")!

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(text, forType: .string)
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
struct WorkshopFailureView: View {
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
        Rectangle().fill(Color.primary.opacity(0.05))
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

@MainActor
struct WorkshopChip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        LWChip(text: text, tint: tint)
    }
}

/// The tags of an item that are not meta chips (kind, resolution, rating), capped to keep cards tidy.
private func topicTags(of item: WorkshopItem, limit: Int) -> [String] {
    let shown = Set([item.resolutionTag, item.ratingTag, item.kind.rawValue].compactMap { $0?.lowercased() })
    return item.tags.filter { !shown.contains($0.lowercased()) }.prefix(limit).map { $0 }
}

@MainActor
private struct ChipRow: View {
    let item: WorkshopItem

    var body: some View {
        HStack(spacing: 6) {
            if item.kind != .unknown {
                WorkshopChip(text: item.kind.rawValue.capitalized,
                             tint: item.isImportable ? Color.accentColor : Color.orange)
            }
            if let resolution = item.resolutionTag { WorkshopChip(text: resolution) }
            if let rating = item.ratingTag { WorkshopChip(text: rating) }
            if isHighResolution(item) {
                WorkshopChip(text: "High resolution", tint: .orange).help("Large videos use more memory and battery")
            }
        }
    }
}

// MARK: - Item cards

/// What a card's action area shows, from the download state and the library.
enum WorkshopCardAction {
    case download, cantPlay, inLibrary(added: Bool)
    case queued, signingIn, downloading(Double?), importing
    case failed(WorkshopError)

    static func make(item: WorkshopItem, state: WorkshopDownloadState?, inLibrary: Bool) -> WorkshopCardAction {
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
        return item.isImportable ? .download : .cantPlay
    }
}

@MainActor
struct WorkshopCardActions: View {
    let item: WorkshopItem
    let action: WorkshopCardAction
    let ready: Bool          // Steam setup is complete
    let compact: Bool
    let workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let showInLibrary: () -> Void

    /// Why Download is disabled until Steam Setup is complete.
    static let setupFirst = "Finish Steam Setup first"

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
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.download(item) },
                        openSteamSetup: openSteamSetup, dismiss: { workshop.dismissDownload(item.id) })
        }
    }

    @ViewBuilder private var downloadButton: some View {
        let size = item.sizeBytes > 0
            ? " · " + ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
            : ""
        if compact {
            Button { workshop.download(item) } label: {
                Label("Download" + size, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!ready)
            .help(ready ? "" : WorkshopCardActions.setupFirst)
        } else {
            Button { workshop.download(item) } label: {
                Label("Download" + size, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ready)
            .help(ready ? "" : WorkshopCardActions.setupFirst)
        }
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
            if let fraction {
                LWProgressBar(progress: fraction, height: 4)
                    .frame(width: compact ? 90 : 150)
            }
            if spinner { ProgressView().controlSize(.small) }
            Text(label).font(.caption).foregroundStyle(.secondary)
            if cancellable {
                Button { workshop.cancelDownload(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Cancel").accessibilityLabel("Cancel download")
            }
        }
    }
}

// MARK: - Item cards: layouts

@MainActor
private struct ResultCard<Actions: View>: View {
    let item: WorkshopItem
    let actions: Actions

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            PreviewImage(url: item.previewURL).frame(width: 232, height: 131)
                .shadow(color: .black.opacity(hovering ? 0.22 : 0.08), radius: hovering ? 16 : 10, y: 7)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.title3.weight(.semibold)).lineLimit(2)
                ChipRow(item: item)
                Text(cardInfoLine(item)).font(.caption).foregroundStyle(.secondary)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 2)
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(18)
        .background { glassShape(radius: LWTheme.cardRadius) }
        .scaleEffect(hovering ? 1.005 : 1)
        .animation(LWMotion.hover, value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
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

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PreviewImage(url: item.previewURL)
                .scaleEffect(hovering ? 1.02 : 1, anchor: .center)
                .animation(LWMotion.hover, value: hovering)
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
            HStack(spacing: 5) {
                ForEach(topicTags(of: item, limit: 2), id: \.self) { tag in
                    LWChip(text: tag)
                }
            }
            .frame(height: 16, alignment: .top)
            Text(info).font(.caption).foregroundStyle(.secondary)
            actions
        }
        .padding(14)
        .background { glassShape(radius: LWTheme.cardRadius) }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}

// MARK: - Workshop tab

/// Workshop tab: paste field + result card, topic/tag browse grid (needs an API key), setup banner,
/// and a live strip for running downloads.
@MainActor
struct WorkshopView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void
    let openDownloads: () -> Void
    @State private var browsed = false
    @State private var detail: WorkshopItem?   // the result whose detail pane is open

    // RootView (another file) builds this view; spelling the init out keeps the private @State from affecting it.
    init(model: SettingsModel, workshop: WorkshopModel,
         openSteamSetup: @escaping () -> Void, openLibrary: @escaping () -> Void,
         openDownloads: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._workshop = ObservedObject(wrappedValue: workshop)
        self.openSteamSetup = openSteamSetup
        self.openLibrary = openLibrary
        self.openDownloads = openDownloads
    }

    // Wide windows show the detail pane next to the results; narrow ones cover the results with it.
    // The browse task is attached here — the root — so no amount of resizing or detail opening restarts it.
    var body: some View {
        GeometryReader { proxy in
            content(wide: proxy.size.width >= 760)
        }
        .animation(LWMotion.content, value: detail?.id)
        .onAppear { workshop.recheckSetup() }
        .task(id: workshop.searchKey) { await refreshBrowse() }
    }

    /// The results column keeps one place in the view tree whether or not the detail pane is open: moving it
    /// between branches would rebuild its scroll view and jump back to the top of the list. A narrow window hides it
    /// under the detail pane instead of removing it, and disables it so its controls ignore the keyboard.
    /// Its width changes without animation, which AnchoredScrollView needs to keep the same wallpapers in view.
    @ViewBuilder private func content(wide: Bool) -> some View {
        let covered = detail != nil && !wide
        HStack(spacing: 0) {
            resultsColumn
                .animation(nil, value: detail?.id)
                .opacity(covered ? 0 : 1)
                .disabled(covered)
                .accessibilityHidden(covered)
            if wide, let item = detail {
                Divider()
                detailPane(item).frame(width: 380).zIndex(1)
            }
        }
        .overlay {
            if !wide, let item = detail { detailPane(item) }
        }
    }

    private func detailPane(_ item: WorkshopItem) -> some View {
        WorkshopDetailView(model: model, workshop: workshop, item: item, close: { detail = nil },
                           openSteamSetup: openSteamSetup, openLibrary: openLibrary)
            .id(item.id)
    }

    /// Anchored, so the grid keeps showing the same wallpapers, and the one whose details are open, when the detail
    /// pane narrows or widens it.
    private var resultsColumn: some View {
        AnchoredScrollView(order: workshop.results.map(\.id), keepingVisible: detail?.id) {
            VStack(alignment: .leading, spacing: LWTheme.sectionSpacing) {
                LWPageHeader(
                    title: "Workshop",
                    subtitle: "Video and scene wallpapers from Steam, downloaded with your own account.",
                    trailing: { downloadsStrip })

                if !workshop.setup.canDownload { setupBanner }
                pasteRow
                lookupSection
                if workshop.canBrowse { browseSection } else { keyHint }
            }
            .padding(LWTheme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
    }

    /// Live "N downloads in progress" strip in the header; jumps to the Downloads page.
    @ViewBuilder private var downloadsStrip: some View {
        if workshop.hasActiveDownloads {
            Button(action: openDownloads) {
                HStack(spacing: 8) {
                    ProgressRing(progress: workshop.overallDownloadProgress ?? 0,
                                 size: 22, lineWidth: 2.5)
                        .opacity(workshop.overallDownloadProgress == nil ? 0.35 : 1)
                    Text("\(workshop.activeDownloadCount) downloading")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
            .help("Open Downloads")
            .accessibilityLabel("Open Downloads")
        }
    }

    private var setupBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Finish the Steam setup to download wallpapers.")
            Spacer()
            Button("Open Steam Setup", action: openSteamSetup)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lwGlassCard(radius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    private var pasteRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a Workshop link or item number", text: $workshop.pastedText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .onSubmit { workshop.lookUp() }
                if !workshop.pastedText.isEmpty {
                    Button { workshop.pastedText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear")
                }
                Button { paste() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Paste from the clipboard")
                .accessibilityLabel("Paste from the clipboard")
                Button("Look Up") { workshop.lookUp() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(workshop.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
            .background { glassShape(radius: 15) }
            Text("Paste a link from the Steam Workshop and it looks up automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
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
                .contentShape(Rectangle())
                .onTapGesture { detail = item }
        case .failed(let error):
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.lookUp() }, openSteamSetup: openSteamSetup)
                .lwGlassCard()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Download wallpapers from Steam").font(.title3.weight(.semibold))
            Text("Paste a Workshop link or item number above. Video and scene wallpapers can play.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }

    private func actions(for item: WorkshopItem, compact: Bool) -> some View {
        WorkshopCardActions(item: item,
                    action: WorkshopCardAction.make(item: item, state: workshop.downloads[item.id], inLibrary: workshop.isInLibrary(item.id)),
                    ready: workshop.setup.canDownload, compact: compact, workshop: workshop,
                    openSteamSetup: openSteamSetup, showInLibrary: { showInLibrary(item) })
    }

    private func showInLibrary(_ item: WorkshopItem) {
        if let video = model.videos.first(where: { $0.workshopID == item.id }) { model.focusedID = video.id }
        openLibrary()
    }

    // MARK Browse

    /// The first run loads (or keeps) the list at once; later changes of sort, search text, rating or kind wait
    /// 400 ms and keep the previous results on screen while the new page loads (WorkshopModel.search).
    private func refreshBrowse() async {
        if !browsed {
            browsed = true
            if workshop.listState == .idle { workshop.search() }
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if !Task.isCancelled { workshop.search(keepingResults: true) }
    }

    private var keyHint: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle")
            Text("Browsing needs a free Steam Web API key. Add one in Steam Setup, or paste a link above.")
            Spacer(minLength: 6)
            Button("Steam Setup", action: openSteamSetup).buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(14)
        .background { glassShape(radius: 12) }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Browse").font(.title3.weight(.semibold))
                Text("\(workshop.results.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            topicRow
            browseControls
            browseResults
        }
    }

    /// Curated topics. A topic is the ranked text search on its name; "All" clears the text search.
    private var topicRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LWTopicChip(title: "All",
                            selected: workshop.searchText.isEmpty) {
                    workshop.searchText = ""
                }
                ForEach(WorkshopTopic.allCases) { topic in
                    LWTopicChip(title: topic.rawValue,
                                selected: workshop.searchText.caseInsensitiveCompare(topic.rawValue) == .orderedSame) {
                        toggleTopic(topic)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func toggleTopic(_ topic: WorkshopTopic) {
        if workshop.searchText.caseInsensitiveCompare(topic.rawValue) == .orderedSame {
            workshop.searchText = ""
        } else {
            workshop.searchText = topic.rawValue
        }
    }

    private var browseControls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(WorkshopSort.allCases) { sort in
                    Button(sort.label) { workshop.sort = sort }
                }
            } label: {
                Label(workshop.sort.label, systemImage: "arrow.up.arrow.down")
                    .font(.callout.weight(.medium))
            }
            .fixedSize()
            .disabled(!workshop.searchText.isEmpty)
            .help(workshop.searchText.isEmpty
                  ? "Order of the browse grid"
                  : "Steam decides the order while a search is active")

            LWSearchField(prompt: "Search wallpapers", text: $workshop.searchText)

            HStack(spacing: 2) {
                ForEach(WorkshopKindFilter.allCases) { kind in
                    LWTopicChip(title: kind.label,
                                selected: workshop.kindFilter == kind) {
                        withAnimation(LWMotion.hover) { workshop.kindFilter = kind }
                    }
                }
            }

            Toggle("Mature", isOn: $workshop.includeMature)
                .toggleStyle(.checkbox)
                .help("Include questionable and mature items")
        }
    }

    @ViewBuilder private var browseResults: some View {
        if case .failed(let error) = workshop.listState, workshop.results.isEmpty {
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.search() }, openSteamSetup: openSteamSetup)
        }
        if case .failed = workshop.listState, !workshop.results.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text("Couldn’t refresh — showing the previous results.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry") { workshop.search(keepingResults: true) }
                    .buttonStyle(.link).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        if workshop.listState == .loaded, workshop.results.isEmpty {
            Text("No wallpapers match. Try another topic or search.").font(.callout).foregroundStyle(.secondary)
        }
        if !workshop.results.isEmpty {
            resultGrid
                .opacity(workshop.listState == .loading ? 0.55 : 1)
                .animation(LWMotion.content, value: workshop.listState == .loading)
        }
        if workshop.listState == .loading {
            if workshop.results.isEmpty {
                skeletonGrid
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        } else if workshop.canLoadMore {
            Button {
                workshop.loadMore()
            } label: {
                Label("Load More", systemImage: "chevron.down")
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
    }

    private var resultGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: LWTheme.gridSpacing)],
                  alignment: .leading, spacing: LWTheme.gridSpacing) {
            ForEach(workshop.results) { item in
                CompactCard(item: item, actions: actions(for: item, compact: true))
                    .contentShape(Rectangle())
                    .onTapGesture { detail = item }
                    .scrollAnchorItem(item.id)
                    .lwScrollEntry()
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: LWTheme.gridSpacing)],
                  alignment: .leading, spacing: LWTheme.gridSpacing) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(height: 132, radius: 12)
                    SkeletonBlock(height: 12, width: 180)
                    SkeletonBlock(height: 10, width: 110)
                }
                .padding(14)
                .background { glassShape(radius: LWTheme.cardRadius) }
            }
        }
    }
}

// MARK: - Steam Setup tab

/// Steam Setup tab: the wizard, then an Advanced section with the optional Web API key, a manual SteamCMD path
/// and the sign-in check of the download path.
@MainActor
struct SteamSetupView: View {
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject var setup: SteamSetupModel
    @State private var advancedOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LWTheme.sectionSpacing) {
                LWPageHeader(
                    title: "Steam Setup",
                    subtitle: "Download wallpapers from the Steam Workshop with your own account.")
                SteamWizardView(setup: setup)
                DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
                    advanced.padding(.top, 10)
                }
                .font(.callout)
                .lwGlassCard()
            }
            .padding(LWTheme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .onAppear { workshop.recheckSetup() }
        .onChange(of: setup.account) { _, account in
            // The download path reads the username from the Workshop model; keep both on the signed-in name.
            if case .signedIn(let name) = account, workshop.steamUsername != name { workshop.steamUsername = name }
        }
        .task(id: [workshop.steamUsername, workshop.steamcmdPathOverride, workshop.apiKey]) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { workshop.recheckSetup() }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            apiKeyBlock
            toolPathBlock
            signInCheckBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apiKeyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steam Web API key (optional)").font(.subheadline.weight(.semibold))
            HStack {
                SecureField("Web API key", text: $workshop.apiKey).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Link("Get a free key", destination: apiKeyPage)
                Button("Remove") { workshop.apiKey = "" }.disabled(workshop.apiKey.isEmpty)
            }
            Text("Only needed to browse and search. Stored on this Mac, in this app’s preferences.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var toolPathBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SteamCMD location").font(.subheadline.weight(.semibold))
            Text(workshop.setup.steamcmdPath ?? "Not found")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Choose…") { chooseSteamcmd() }
                Button("Use automatic") { useAutomaticPath() }.disabled(workshop.steamcmdPathOverride.isEmpty)
            }
            Text("Only needed if you already have SteamCMD somewhere else. PaperFlow installs its own copy otherwise.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var signInCheckBlock: some View {
        HStack(spacing: 12) {
            Button("Check sign-in") { workshop.checkLogin() }.disabled(!canCheckLogin)
            Text(loginText).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Everything the sign-in check needs is in place.
    private var canCheckLogin: Bool {
        workshop.setup.steamcmdPath != nil && workshop.setup.rosettaOK && workshop.setup.usernameValid
    }

    private var loginText: String {
        switch workshop.setup.login {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .loggedIn: return "Signed in as \(workshop.steamUsername)"
        case .needsLogin: return "Sign in with the steps above."
        case .failed(let error): return error.title
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
            refreshTools()
        }
    }

    private func useAutomaticPath() {
        workshop.steamcmdPathOverride = ""
        refreshTools()
    }

    private func refreshTools() {
        workshop.recheckSetup()
        setup.refresh()
    }
}
