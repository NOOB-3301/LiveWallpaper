import SwiftUI
import AppKit
import Core

// Views for the Workshop and Steam Setup tabs, built on the WorkshopModel surface in Workshop.swift. The filter bar
// is pinned above the grid (WorkshopFilterViews.swift); search and the link lookup live in the window toolbar
// (App.swift). Result cards open the detail pane (WorkshopDetailView.swift); downloads live in their own page
// (DownloadsView.swift). Steam Setup is the in-app wizard (SteamWizardView.swift) plus an Advanced section.
//
// Layout stability rule: the browse task hangs off WorkshopView's root, whose identity never changes when the
// window is resized or the detail pane opens. Only a real change of the search inputs (sort, text, filters)
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
        RemoteStill(url: url, maxPixel: 480)
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

/// A wallpaper in the grid: a 16:9 poster with its title over a gradient, two badges (kind and a short resolution) and
/// one corner control that follows the download: arrow on hover, then progress, then a check. Size, date, rating and
/// subscribers are in the detail pane. Every card is the same height, which keeps the grid steady.
@MainActor
private struct WorkshopPosterCard: View {
    let item: WorkshopItem
    let action: WorkshopCardAction
    let ready: Bool                     // Steam setup is complete
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let showInLibrary: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    private var kind: String? { item.kind == .unknown ? nil : item.kind.rawValue }
    private var inLibrary: Bool { if case .inLibrary = action { return true } else { return false } }
    private var cantPlay: Bool { if case .cantPlay = action { return true } else { return false } }
    private var isDownloadable: Bool { if case .download = action { return true } else { return false } }
    private var corner: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    RemoteStill(url: item.previewURL, maxPixel: 768, symbol: item.kind == .scene ? "sparkles" : "film")
                        .scaleEffect(hovering ? 1.03 : 1)
                    LinearGradient(colors: [.clear, .black.opacity(0.74)],
                                   startPoint: UnitPoint(x: 0.5, y: 0.35), endPoint: .bottom)
                    if (inLibrary && !hovering) || cantPlay { Color.black.opacity(0.38) }
                    content
                }
            }
            .clipShape(corner)
            .overlay {
                corner.strokeBorder(focused ? Color.accentColor : Color.white.opacity(hovering ? 0.22 : 0.08),
                                    lineWidth: focused ? 2.5 : 1)
            }
            .contentShape(corner)
            .onTapGesture(perform: onOpen)
            .onHover { inside in withAnimation(LWMotion.hover) { hovering = inside } }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.return) { onOpen(); return .handled }
            .help(item.title)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(WorkshopCardCopy.accessibilityLabel(title: item.title, kind: kind,
                                                                    resolutionTag: item.resolutionTag))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Open details", onOpen)
            .accessibilityAction(named: "Download") { if isDownloadable, ready { onDownload() } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                badges
                Spacer(minLength: 6)
                control
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if hovering, isDownloadable, item.sizeBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .padding(10)
    }

    private var badges: some View {
        HStack(spacing: 5) {
            ForEach(WorkshopCardCopy.badges(kind: kind, resolutionTag: item.resolutionTag), id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(badge == "Web" || badge == "App" ? Color.orange : Color.white)
                    .padding(.horizontal, 8)
                    .frame(height: 19)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
    }

    // MARK: Corner control

    @ViewBuilder private var control: some View {
        switch action {
        case .download:
            if hovering || focused {
                Button(action: onDownload) { glyph("arrow.down", tint: Color.accentColor) }
                    .buttonStyle(.plain)
                    .disabled(!ready)
                    .opacity(ready ? 1 : 0.5)
                    .help(ready ? "Download" : WorkshopCardActions.setupFirst)
                    .accessibilityLabel("Download")
            }
        case .cantPlay:
            Text("Can’t play here")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.8))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Color.orange, in: Capsule())
                .help(WorkshopError.unsupportedType(item.kind).message)
        case .inLibrary:
            Button(action: showInLibrary) { glyph("checkmark", tint: .green) }
                .buttonStyle(.plain)
                .help("In your library. Show in Library")
                .accessibilityLabel("In your library. Show in Library")
        case .queued:
            cancellable { pill("Waiting…") }
        case .signingIn:
            cancellable { spinner }
        case .downloading(let value):
            cancellable {
                if let value {
                    ProgressRing(progress: min(max(value, 0), 1), size: 34, lineWidth: 3, tint: .white)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .accessibilityLabel("Downloading \(Int((min(max(value, 0), 1) * 100).rounded())) percent")
                } else {
                    spinner
                }
            }
        case .importing:
            spinner
        case .failed(let error):
            Button(action: onOpen) { glyph("exclamationmark", tint: .orange) }
                .buttonStyle(.plain)
                .help("\(error.title). \(error.message)")
                .accessibilityLabel("Download failed: \(error.title)")
        }
    }

    private func glyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(tint))
            .contentShape(Circle())
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .tint(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(.black.opacity(0.45)))
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(.black.opacity(0.5), in: Capsule())
    }

    /// Hovering turns a running download's indicator into a cancel button.
    @ViewBuilder private func cancellable<Content: View>(@ViewBuilder _ running: () -> Content) -> some View {
        if hovering {
            Button(action: onCancel) { glyph("xmark", tint: Color.black.opacity(0.55)) }
                .buttonStyle(.plain)
                .help("Cancel the download")
                .accessibilityLabel("Cancel download")
        } else {
            running()
        }
    }
}

// MARK: - Workshop tab

/// Workshop tab: the pinned filter bar over a grid of results (needs an API key), the setup banner, and the detail
/// pane. The link lookup is a popover from the toolbar (WorkshopLinkPopover).
@MainActor
struct WorkshopView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void
    @State private var browsed = false
    @State private var detail: WorkshopItem?   // the result whose detail pane is open

    // RootView (another file) builds this view; spelling the init out keeps the private @State from affecting it.
    init(model: SettingsModel, workshop: WorkshopModel,
         openSteamSetup: @escaping () -> Void, openLibrary: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._workshop = ObservedObject(wrappedValue: workshop)
        self.openSteamSetup = openSteamSetup
        self.openLibrary = openLibrary
    }

    /// The detail pane has the Library inspector's width, so the two pages feel alike.
    private static let detailWidth: CGFloat = 330

    // Wide windows show the detail pane next to the results; narrow ones cover the results with it.
    // The browse task is attached here — the root — so no amount of resizing or detail opening restarts it.
    var body: some View {
        GeometryReader { proxy in
            content(wide: proxy.size.width >= 760)
        }
        .animation(LWMotion.content, value: detail?.id)
        .onAppear { workshop.recheckSetup() }
        .task(id: workshop.searchKey) { await refreshBrowse() }
        .onChange(of: workshop.detailRequest) { _, item in
            guard let item else { return }
            detail = item
            workshop.detailRequest = nil
        }
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
                detailPane(item, wide: true).frame(width: Self.detailWidth).zIndex(1)
            }
        }
        .overlay {
            if !wide, let item = detail { detailPane(item, wide: false) }
        }
    }

    private func detailPane(_ item: WorkshopItem, wide: Bool) -> some View {
        WorkshopDetailView(model: model, workshop: workshop, item: item, close: { detail = nil },
                           openSteamSetup: openSteamSetup, openLibrary: openLibrary,
                           narrowTo: { tag in
                               workshop.narrow(toTag: tag)
                               if !wide { detail = nil }    // a narrow window shows the results again
                           },
                           open: { detail = $0 })
            .id(item.id)
    }

    /// The bar stays put; only the grid scrolls. Anchored, so the grid keeps showing the same wallpapers, and the one
    /// whose details are open, when the detail pane narrows or widens it.
    private var resultsColumn: some View {
        VStack(spacing: 0) {
            if workshop.canBrowse {
                WorkshopFilterBar(workshop: workshop)
                Divider()
            }
            AnchoredScrollView(order: workshop.results.map(\.id), keepingVisible: detail?.id) {
                VStack(alignment: .leading, spacing: 14) {
                    if !workshop.setup.canDownload { setupBanner }
                    if workshop.canBrowse { browseResults } else { noKeyState }
                }
                .padding(.horizontal, LWTheme.contentPadding)
                .padding(.top, 16)
                .padding(.bottom, LWTheme.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
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

    /// Without an API key there is nothing to browse; the link lookup in the toolbar still works.
    private var noKeyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Download wallpapers from Steam").font(.title3.weight(.semibold))
            Text("Browsing needs a free Steam Web API key. Add one in Steam Setup, or look up a Workshop link with the link button in the toolbar (⌘L). Video and scene wallpapers can play.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Open Steam Setup", action: openSteamSetup).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .background { glassShape(radius: LWTheme.cardRadius) }
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

    @ViewBuilder private var browseResults: some View {
        // A following page loading leaves the grid alone; only a new search replaces (and dims) it.
        let refreshing = workshop.listState == .loading && !workshop.loadingMore
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
            VStack(spacing: 8) {
                Text("No wallpapers match.").font(.callout).foregroundStyle(.secondary)
                if workshop.isSearching || !workshop.filters.isDefault {
                    Button("Clear search and filters") { workshop.resetSearch() }.buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        if !workshop.results.isEmpty {
            resultGrid
                .opacity(refreshing ? 0.55 : 1)
                .animation(LWMotion.content, value: refreshing)
        }
        if workshop.listState == .loading {
            if workshop.results.isEmpty {
                skeletonGrid
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(workshop.loadingMore ? "Loading more…" : "Refreshing…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        } else if let error = workshop.loadMoreError {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text("Couldn’t load more — \(error.title).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry") { workshop.loadMore(retry: true) }
                    .buttonStyle(.link).font(.caption)
            }
            .frame(maxWidth: .infinity)
        } else if workshop.canLoadMore {
            // Scrolling near the end loads the next page by itself; the button is the fallback.
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
                WorkshopPosterCard(
                    item: item,
                    action: WorkshopCardAction.make(item: item, state: workshop.downloads[item.id],
                                                    inLibrary: workshop.isInLibrary(item.id)),
                    ready: workshop.setup.canDownload,
                    onOpen: { detail = item },
                    onDownload: { workshop.download(item) },
                    onCancel: { workshop.cancelDownload(item.id) },
                    showInLibrary: { showInLibrary(item) })
                    .scrollAnchorItem(item.id)
                    .lwScrollEntry()
                    .onAppear { workshop.loadMoreIfNeeded(after: item.id) }
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: LWTheme.gridSpacing)],
                  alignment: .leading, spacing: LWTheme.gridSpacing) {
            ForEach(0..<8, id: \.self) { _ in
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { SkeletonFill(radius: 14) }
            }
        }
    }
}

/// A shimmering placeholder that fills its frame (SkeletonBlock has a fixed height).
private struct SkeletonFill: View {
    var radius: CGFloat = 14
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.secondary.opacity(dim ? 0.09 : 0.16))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

// MARK: - Link lookup

/// Paste a Workshop link or item number and get the item back: the toolbar's link button (⌘L) opens this. It looks
/// up by itself once pasting has paused, and offers the same download actions as a grid card.
@MainActor
struct WorkshopLinkPopover: View {
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject var model: SettingsModel
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void
    let openDetail: (WorkshopItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Look up a Workshop item").font(.headline)
            field
            result
        }
        .padding(16)
        .frame(width: 430)
        .task(id: workshop.pastedText) { await lookUpPastedText() }
        .onAppear(perform: prefillFromClipboard)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField("Paste a Workshop link or item number", text: $workshop.pastedText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .onSubmit { workshop.lookUp() }
            if !workshop.pastedText.isEmpty {
                Button { workshop.pastedText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear")
            }
            Button { paste() } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.borderless)
                .help("Paste from the clipboard")
                .accessibilityLabel("Paste from the clipboard")
            Button("Look Up") { workshop.lookUp() }
                .keyboardShortcut(.defaultAction)
                .disabled(workshop.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .background { glassShape(radius: 11) }
    }

    @ViewBuilder private var result: some View {
        switch workshop.lookup {
        case .idle:
            Text("Paste a link from the Steam Workshop and it looks up automatically.")
                .font(.caption).foregroundStyle(.tertiary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up…").foregroundStyle(.secondary)
            }
        case .found(let item):
            foundRow(item)
        case .failed(let error):
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.lookUp() },
                                openSteamSetup: openSteamSetup)
        }
    }

    private func foundRow(_ item: WorkshopItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PreviewImage(url: item.previewURL).frame(width: 128)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                ChipRow(item: item)
                Text(cardInfoLine(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                WorkshopCardActions(
                    item: item,
                    action: WorkshopCardAction.make(item: item, state: workshop.downloads[item.id],
                                                    inLibrary: workshop.isInLibrary(item.id)),
                    ready: workshop.setup.canDownload, compact: true, workshop: workshop,
                    openSteamSetup: openSteamSetup, showInLibrary: { showInLibrary(item) })
                Button("Details…") { openDetail(item) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(10)
        .background { glassShape(radius: 12) }
    }

    private func showInLibrary(_ item: WorkshopItem) {
        if let video = model.videos.first(where: { $0.workshopID == item.id }) { model.focusedID = video.id }
        openLibrary()
    }

    private func paste() {
        if let text = NSPasteboard.general.string(forType: .string) { workshop.pastedText = text }
    }

    /// A Workshop link already on the clipboard is the usual reason to open this, so it is filled in.
    private func prefillFromClipboard() {
        guard workshop.pastedText.isEmpty,
              let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              looksLikeWorkshopItem(text) else { return }
        workshop.pastedText = text
    }

    /// Looks a plausible link or number up once typing or pasting has paused.
    private func lookUpPastedText() async {
        let text = workshop.pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeWorkshopItem(text) else { return }
        if case .found(let item) = workshop.lookup, text.contains(item.id) { return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if !Task.isCancelled { workshop.lookUp() }
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
