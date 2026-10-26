import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers
import Core

// The Library: a gallery-first wall of wallpapers, with a large live preview and a context inspector.

enum LibraryFilter: String, CaseIterable, Identifiable, Equatable {
    case all, desktop, lock, scenes

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Wallpapers"
        case .desktop: return "Desktop"
        case .lock: return "Lock Screen"
        case .scenes: return "Scenes"
        }
    }

    func includes(_ item: VideoItem, targets: Set<WallpaperTarget>) -> Bool {
        switch self {
        case .all: return true
        case .desktop: return targets.contains(.desktop)
        case .lock: return targets.contains(.lock)
        case .scenes: return item.isScene
        }
    }
}

enum LibraryLayout: String, CaseIterable {
    case grid, list
}

@MainActor
struct LibraryView: View {
    @ObservedObject var model: SettingsModel
    let filter: LibraryFilter
    @Binding var showInspector: Bool
    let openWorkshop: () -> Void
    let openSteamSetup: () -> Void

    @State private var searchText = ""
    @State private var layout: LibraryLayout = .grid
    @State private var isTargeted = false
    @State private var skippedCount = 0
    @State private var showSkipped = false
    @State private var importFailures: [String] = []
    @State private var showFailures = false
    @State private var pendingRemoval: Set<VideoItem.ID> = []
    @State private var selectedIDs: Set<VideoItem.ID> = []
    @State private var anchorID: VideoItem.ID?
    @State private var selectionMode = false

    init(model: SettingsModel, filter: LibraryFilter, showInspector: Binding<Bool>,
         openWorkshop: @escaping () -> Void, openSteamSetup: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self.filter = filter
        self._showInspector = showInspector
        self.openWorkshop = openWorkshop
        self.openSteamSetup = openSteamSetup
    }

    var body: some View {
        let plan = Plan(model: model, filter: filter, searchText: searchText)
        return Group {
            if model.videos.isEmpty {
                emptyState
            } else if plan.items.isEmpty {
                noResults
            } else {
                gallery(plan)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { isTargeted = $0 }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search wallpapers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(LWMotion.panel) {
                        selectionMode.toggle()
                        if !selectionMode, let focused = plan.focused { selectedIDs = [focused.id] }
                    }
                } label: {
                    Image(systemName: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(selectionMode ? "Stop selecting multiple" : "Select multiple wallpapers")
                .accessibilityLabel(selectionMode ? "Stop selecting multiple" : "Select multiple wallpapers")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: removeSelection) {
                    Image(systemName: "trash")
                }
                .disabled(selectedIDs.isEmpty)
                .help(removalHelp)
                .accessibilityLabel(removalHelp)
                .keyboardShortcut(.delete, modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { layout = .grid } label: { Label("Grid", systemImage: "square.grid.2x2") }
                    Button { layout = .list } label: { Label("List", systemImage: "list.bullet") }
                } label: {
                    Image(systemName: layout == .grid ? "square.grid.2x2" : "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Change layout")
                .accessibilityLabel("Change layout")
            }
        }
        .alert(skippedTitle, isPresented: $showSkipped) { Button("OK", role: .cancel) {} }
        .alert("Some wallpapers couldn’t be imported", isPresented: $showFailures) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importFailures.joined(separator: "\n"))
        }
        .alert(removalTitle, isPresented: confirmingRemoval) {
            Button("Remove", role: .destructive) { finishRemoval() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingRemoval.count > 1
                 ? "Downloaded Workshop files are deleted and can be downloaded again."
                 : "You can download it again from the Workshop.")
        }
        .onAppear { reconcileSelection() }
        .onChange(of: filter) { reconcileSelection() }
        .onChange(of: searchText) { reconcileSelection() }
        .onChange(of: model.videos.map(\.id)) { reconcileSelection() }
    }

    // MARK: Data

    /// The library as this page shows it. Single pass, no file stats — the scroll handlers call it too,
    /// so it has to stay cheaper than the plan around it.
    private static func visible(_ model: SettingsModel, _ filter: LibraryFilter, _ searchText: String) -> [VideoItem] {
        model.videos.filter { item in
            filter.includes(item, targets: model.targets(of: item.id)) &&
            (searchText.isEmpty ||
             item.name.localizedCaseInsensitiveContains(searchText) ||
             (item.author ?? "").localizedCaseInsensitiveContains(searchText))
        }
    }

    /// Everything the grid renders, resolved once per body evaluation instead of once per card. Resolving it
    /// per card copied the whole library and re-statted every path, which is what stalled the scroll.
    @MainActor
    private struct Plan {
        let items: [VideoItem]
        let focusedID: VideoItem.ID?
        let roles: [VideoItem.ID: Set<WallpaperTarget>]
        let playing: [VideoItem.ID: Set<WallpaperTarget>]
        let broken: Set<VideoItem.ID>

        var focused: VideoItem? { items.first { $0.id == focusedID } }
        func roles(of id: VideoItem.ID) -> Set<WallpaperTarget> { roles[id] ?? [] }
        func playing(of id: VideoItem.ID) -> Set<WallpaperTarget> { playing[id] ?? [] }
        func isBroken(_ id: VideoItem.ID) -> Bool { broken.contains(id) }

        init(model: SettingsModel, filter: LibraryFilter, searchText: String) {
            let visible = LibraryView.visible(model, filter, searchText)
            var assigned: [VideoItem.ID: Set<WallpaperTarget>] = [:]
            var onAir: [VideoItem.ID: Set<WallpaperTarget>] = [:]
            assigned.reserveCapacity(visible.count)
            if model.isRunning {
                for target in WallpaperTarget.allCases {
                    if let id = model.currentID(for: target) { onAir[id, default: []].insert(target) }
                }
            }
            for item in visible {
                let targets = model.targets(of: item.id)
                if !targets.isEmpty { assigned[item.id] = targets }
            }
            items = visible
            roles = assigned
            playing = onAir
            broken = model.brokenIDs
            focusedID = visible.first { $0.id == model.focusedID }?.id ?? visible.first?.id
        }
    }

    private var selectionCount: Int { selectedIDs.count }

    private var removalHelp: String {
        selectionCount > 1 ? "Remove \(selectionCount) wallpapers (⌘⌫)" : "Remove selected wallpaper (⌘⌫)"
    }

    /// Keeps the multi-selection inside what is visible after a filter, search or library change.
    private func reconcileSelection() {
        let items = Self.visible(model, filter, searchText)
        let visible = Set(items.map(\.id))
        selectedIDs.formIntersection(visible)

        if let focused = model.focusedID, visible.contains(focused) {
            if selectedIDs.isEmpty { selectedIDs.insert(focused) }
        } else if let firstSelected = items.first(where: { selectedIDs.contains($0.id) }) {
            model.focusedID = firstSelected.id
        } else {
            model.focusedID = items.first?.id
            if let first = items.first { selectedIDs.insert(first.id) }
        }

        if let anchorID, visible.contains(anchorID) {
            // Keep the range anchor while it is still on screen.
        } else {
            anchorID = model.focusedID
        }
    }

    private func select(_ item: VideoItem) {
        let items = Self.visible(model, filter, searchText)
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchorID,
           let from = items.firstIndex(where: { $0.id == anchorID }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            let range = min(from, to)...max(from, to)
            selectedIDs = Set(items[range].map(\.id))
            model.focusedID = item.id
        } else if selectionMode || flags.contains(.command) {
            toggleSelection(item.id)
        } else {
            selectedIDs = [item.id]
            model.focusedID = item.id
            anchorID = item.id
        }
    }

    private func toggleSelection(_ id: VideoItem.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if model.focusedID == id {
                model.focusedID = Self.visible(model, filter, searchText)
                    .first(where: { selectedIDs.contains($0.id) })?.id ?? id
            }
        } else {
            selectedIDs.insert(id)
            model.focusedID = id
            anchorID = id
        }
    }

    private func removeSelection() {
        guard !selectedIDs.isEmpty else { return }
        remove(selectedIDs)
    }

    private func renderStatus(of item: VideoItem) -> LockRenderStatus? {
        guard let render = model.lockRender, render.itemID == item.id, render.state != .finished else { return nil }
        return render
    }

    // MARK: Content

    /// The hero lives outside the scroller. It carries a layer-backed `AVPlayerView`, and taking it out of the
    /// lazy grid's layout pass is most of why the page felt heavy — only the cards scroll now.
    private func gallery(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = plan.focused {
                LibraryHero(model: model, item: item, broken: plan.isBroken(item.id),
                            playing: plan.playing(of: item.id), render: renderStatus(of: item),
                            openSteamSetup: openSteamSetup,
                            remove: { remove([item.id]) })
                    .id(item.id)
                    .transition(.opacity)
                    .padding(LWTheme.contentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    heading(plan)
                    librarySection(plan)
                }
                .padding(.horizontal, LWTheme.contentPadding)
                .padding(.bottom, LWTheme.contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .defaultScrollAnchor(.top)
            .overlay(alignment: .top) {
                if isTargeted {
                    Text("Drop wallpapers to add them")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isTargeted)
        }
    }

    private func heading(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(filter.title)
                .font(.system(size: 30, weight: .bold))
                .kerning(-0.4)
            Text(subtitle(plan))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ plan: Plan) -> String {
        if selectionCount > 1 {
            return "\(selectionCount) selected · click checkmarks to adjust"
        }
        if selectionMode {
            return selectionCount == 0
                ? "Select wallpapers to remove."
                : "1 selected · click to add or remove"
        }
        if !searchText.isEmpty {
            return "\(plan.items.count) \(plan.items.count == 1 ? "result" : "results") for “\(searchText)”"
        }
        switch filter {
        case .all: return "\(plan.items.count) \(plan.items.count == 1 ? "wallpaper" : "wallpapers")"
        case .desktop: return "\(plan.items.count) set for your desktop"
        case .lock: return "\(plan.items.count) set for the lock screen"
        case .scenes: return "\(plan.items.count) Wallpaper Engine \(plan.items.count == 1 ? "scene" : "scenes")"
        }
    }

    @ViewBuilder private func librarySection(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(filter == .all ? "Your library" : "Wallpapers")
                    .font(.title3.weight(.semibold))
                Text("\(plan.items.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button { importWallpapers() } label: {
                        Label("Import Wallpapers…", systemImage: "square.and.arrow.down.on.square")
                    }
                    Button { chooseVideos() } label: {
                        Label("Add Videos…", systemImage: "film")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import videos, Wallpaper Engine scene packages or scene folders (⌘O)")
                .accessibilityLabel("Add wallpapers")
            }

            switch layout {
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: LWTheme.cardMinWidth, maximum: 340),
                                             spacing: LWTheme.gridSpacing)],
                          alignment: .leading, spacing: LWTheme.gridSpacing) {
                    ForEach(plan.items) { item in
                        LibraryCard(item: item,
                                    broken: plan.isBroken(item.id),
                                    roles: plan.roles(of: item.id),
                                    playing: plan.playing(of: item.id),
                                    paused: model.isPaused,
                                    focused: item.id == plan.focusedID,
                                    selected: selectedIDs.contains(item.id),
                                    selectionMode: selectionMode,
                                    render: renderStatus(of: item),
                                    onSelect: { select(item) },
                                    onToggleSelect: { toggleSelection(item.id) },
                                    onActivate: { model.play(item.id) },
                                    assign: { model.assign(item.id, to: $0) },
                                    remove: { remove([item.id]) })
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            .lwScrollEntry()
                    }
                }
            case .list:
                LazyVStack(spacing: 4) {
                    ForEach(plan.items) { item in
                        LibraryListRow(item: item,
                                       broken: plan.isBroken(item.id),
                                       roles: plan.roles(of: item.id),
                                       playing: plan.playing(of: item.id),
                                       paused: model.isPaused,
                                       focused: item.id == plan.focusedID,
                                       selected: selectedIDs.contains(item.id),
                                       selectionMode: selectionMode,
                                       onSelect: { select(item) },
                                       onToggleSelect: { toggleSelection(item.id) },
                                       onActivate: { model.play(item.id) },
                                       assign: { model.assign(item.id, to: $0) },
                                       remove: { remove([item.id]) })
                            .lwScrollEntry()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        LWEmptyState(icon: "play.rectangle.on.rectangle",
                     title: "Your wallpaper library is empty",
                     message: "Drop videos, Wallpaper Engine scene packages (.pkg) or scene folders here — or choose files from your Mac.",
                     actionTitle: "Import Wallpapers…", action: importWallpapers,
                     secondaryTitle: "Browse the Workshop", secondaryAction: openWorkshop,
                     targeted: isTargeted)
        .contentShape(Rectangle())
        .onTapGesture(perform: importWallpapers)
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text("No wallpapers match").font(.title3.weight(.semibold))
            Text(searchText.isEmpty ? "There is nothing in this collection yet." : "Try another search.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Removing and adding

    private var skippedTitle: String {
        skippedCount == 1 ? "Skipped 1 file that isn’t a wallpaper." : "Skipped \(skippedCount) files that aren’t wallpapers."
    }

    /// Brings dropped or chosen files in: videos by reference, scene packages and folders through the
    /// shared scene importer. Everything lands in the library and is committed to the service (state.json).
    private func add(_ urls: [URL]) {
        Task { @MainActor in
            let outcome = await WallpaperImporter.importURLs(urls, into: model)
            skippedCount = outcome.skipped
            importFailures = outcome.failed
            showSkipped = outcome.skipped > 0
            showFailures = !outcome.failed.isEmpty
            withAnimation(LWMotion.panel) { reconcileSelection() }
        }
    }

    private func chooseVideos() {
        let urls = VideoPicker.choose()
        if !urls.isEmpty { add(urls) }
    }

    private func importWallpapers() {
        let urls = WallpaperPicker.choose()
        if !urls.isEmpty { add(urls) }
    }

    private func remove(_ ids: Set<VideoItem.ID>) {
        guard !ids.isEmpty else { return }
        if model.videos.contains(where: { ids.contains($0.id) && $0.isWorkshop }) {
            pendingRemoval = ids
        } else {
            withAnimation(LWMotion.panel) {
                model.remove(ids: ids)
                reconcileSelection()
            }
        }
    }

    private func finishRemoval() {
        withAnimation(LWMotion.panel) {
            model.remove(ids: pendingRemoval)
            pendingRemoval = []
            reconcileSelection()
        }
    }

    private var confirmingRemoval: Binding<Bool> {
        Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
    }

    private var removalTitle: String {
        let names = model.videos.filter { pendingRemoval.contains($0.id) }.map(\.name)
        return names.count == 1 ? "Remove “\(names[0])” and delete its downloaded files?"
                                : "Remove \(names.count) wallpapers and delete the downloaded files of Workshop items?"
    }
}

// MARK: - Hero

@MainActor
private struct LibraryHero: View {
    @ObservedObject var model: SettingsModel
    let item: VideoItem
    let broken: Bool
    let playing: Set<WallpaperTarget>
    let render: LockRenderStatus?
    let openSteamSetup: () -> Void
    let remove: () -> Void

    private var isPlaying: Bool { model.isPlaying(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottom) {
                ItemPreviewPane(item: item, broken: broken, openSteamSetup: openSteamSetup, showsNotes: false)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: LWTheme.panelRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LWTheme.panelRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }

                LinearGradient(colors: [.clear, .black.opacity(0.42)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: LWTheme.panelRadius, style: .continuous))

                HStack(alignment: .bottom, spacing: 10) {
                    if !playing.isEmpty {
                        HStack(spacing: 6) {
                            ActivityBars(playing: true, paused: model.isPaused, tint: .white)
                            Text(model.isPaused ? "Paused" : "Playing")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    transport
                }
                .padding(12)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        ForEach(WallpaperTarget.allCases) { target in
                            if playing.contains(target) {
                                LWChip(text: target.label, tint: .accentColor, filled: true, icon: "checkmark")
                            }
                        }
                        if item.isScene, let info = item.scene { SceneSupportBadge(info: info) }
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let render { LockRenderLine(status: render) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Menu {
                        SetAsItems(roles: model.roles(of: item.id), isScene: item.isScene,
                                   assign: { model.assign(item.id, to: $0) })
                    } label: {
                        Label("Set as", systemImage: "rectangle.on.rectangle.angled")
                    }
                    .fixedSize()

                    Button {
                        model.clearStatus()
                        if isPlaying { model.stop() } else { model.startOnly(item.id) }
                    } label: {
                        Label(isPlaying ? "Stop" : "Play",
                              systemImage: isPlaying ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isPlaying ? .red : nil)
                }
                .controlSize(.large)
            }
        }
    }

    private var transport: some View {
        GlassPanel(radius: 13) {
            HStack(spacing: 2) {
                iconButton(isPlaying ? "stop.fill" : "play.fill",
                           help: isPlaying ? "Stop wallpaper" : "Play wallpaper") {
                    model.clearStatus()
                    if isPlaying { model.stop() } else { model.startOnly(item.id) }
                }
                iconButton(model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           help: model.muted ? "Unmute" : "Mute") {
                    model.muted.toggle()
                }
                iconButton("arrow.up.left.and.arrow.down.right", help: "Enter full screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                iconButton("folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                iconButton("trash", help: "Remove from library") { remove() }
            }
            .padding(4)
        }
        .fixedSize()
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var meta: String {
        if item.isWorkshop { return "Workshop" }
        return item.isScene ? "Scene" : "Video"
    }
}

// MARK: - Cards

@MainActor
private struct LibraryCard: View {
    let item: VideoItem
    let broken: Bool
    let roles: Set<WallpaperTarget>
    let playing: Set<WallpaperTarget>
    let paused: Bool
    let focused: Bool
    let selected: Bool
    let selectionMode: Bool
    let render: LockRenderStatus?
    let onSelect: () -> Void
    let onToggleSelect: () -> Void
    let onActivate: () -> Void
    let assign: (Set<WallpaperTarget>) -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    ItemThumbnail(item: item, broken: broken, cornerRadius: 12)
                        .aspectRatio(16 / 9, contentMode: .fit)

                    LinearGradient(colors: [.clear, .black.opacity(0.34)],
                                   startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if hovering {
                        LinearGradient(colors: [.white.opacity(0.12), .clear],
                                       startPoint: .top, endPoint: .center)
                            .allowsHitTesting(false)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .transition(.opacity)
                    }

                    HStack(spacing: 4) {
                        ForEach(WallpaperTarget.allCases) { target in
                            if roles.contains(target) {
                                LWChip(text: target == .desktop ? "Desktop" : "Lock",
                                       tint: .accentColor,
                                       filled: playing.contains(target),
                                       icon: playing.contains(target) ? "waveform" : nil)
                            }
                        }
                        if let info = item.scene { SceneSupportBadge(info: info) }
                    }
                    .padding(7)

                    if let render, render.state == .rendering || render.state == .queued {
                        ProgressRing(progress: render.state == .rendering ? render.progress : 0,
                                     size: 30, lineWidth: 2.5, tint: .white)
                            .padding(9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }

                    if hovering && !broken && !selectionMode {
                        HStack(spacing: 5) {
                            Button {
                                onActivate()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .help("Play wallpaper")

                            Menu {
                                SetAsItems(roles: roles, isScene: item.isScene, assign: assign)
                                Divider()
                                Button("Remove…", role: .destructive, action: remove)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 26, height: 26)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                        .padding(4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(focused ? 1 : 0.72)
                                               : Color.primary.opacity(0.07),
                                      lineWidth: selected ? (focused ? 2.5 : 2) : 1)
                }
                // A shadow modifier is an offscreen pass whether or not its colour is clear, so the resting
                // cards get none at all. The fill is hidden by the opaque thumbnail.
                .background {
                    if hovering || selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.20), radius: 16, y: 8)
                            .transition(.opacity)
                    }
                }
                .animation(LWMotion.hover, value: selected)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(broken ? 0.6 : 1)
                    Spacer(minLength: 0)
                    if !playing.isEmpty {
                        ActivityBars(playing: true, paused: paused)
                    }
                }
                Text(cardMeta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onTapGesture(count: 2, perform: onActivate)

            if selected || hovering || selectionMode {
                selectionBadge
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .onHover { inside in
            withAnimation(LWMotion.hover) { hovering = inside }
        }
        .contextMenu {
            SetAsItems(roles: roles, isScene: item.isScene, assign: assign)
            Divider()
            Button("Remove…", role: .destructive, action: remove)
        }
        .help(broken ? "This file was moved, deleted, or can’t be played." : item.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(cardMeta)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectionBadge: some View {
        Button(action: onToggleSelect) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.95),
                                 selected ? Color.accentColor : Color.white.opacity(0.55))
                .font(.system(size: 16, weight: .semibold))
                .padding(3)
                .background(Circle().fill(Color.black.opacity(0.36)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Deselect" : "Add to selection")
        .accessibilityLabel(selected ? "Deselect wallpaper" : "Select wallpaper")
    }

    private var cardMeta: String {
        if broken { return "Missing or unreadable" }
        if let render {
            if render.state == .rendering { return "Rendering for lock screen…" }
            if render.state == .queued { return "Waiting to render…" }
        }
        if item.isWorkshop { return "Workshop" }
        return item.isScene ? "Scene" : "Video"
    }
}

@MainActor
private struct LibraryListRow: View {
    let item: VideoItem
    let broken: Bool
    let roles: Set<WallpaperTarget>
    let playing: Set<WallpaperTarget>
    let paused: Bool
    let focused: Bool
    let selected: Bool
    let selectionMode: Bool
    let onSelect: () -> Void
    let onToggleSelect: () -> Void
    let onActivate: () -> Void
    let assign: (Set<WallpaperTarget>) -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if selectionMode || selected || hovering {
                    Button(action: onToggleSelect) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(selected ? "Deselect" : "Add to selection")
                    .accessibilityLabel(selected ? "Deselect wallpaper" : "Select wallpaper")
                } else {
                    Color.clear.frame(width: 15, height: 15)
                }
            }
            .frame(width: 16, height: 16)

            HStack(spacing: 12) {
                ItemThumbnail(item: item, broken: broken, cornerRadius: 8, size: .row)
                    .frame(width: 96, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 5) {
                        ForEach(WallpaperTarget.allCases) { target in
                            if roles.contains(target) {
                                LWChip(text: target.label, tint: .accentColor, filled: playing.contains(target))
                            }
                        }
                        if item.isScene, let info = item.scene { SceneSupportBadge(info: info) }
                    }
                }
                Spacer(minLength: 8)
                if !playing.isEmpty { ActivityBars(playing: true, paused: paused) }
                Menu {
                    SetAsItems(roles: roles, isScene: item.isScene, assign: assign)
                    Divider()
                    Button("Remove…", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onTapGesture(count: 2, perform: onActivate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.045) : .clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(focused ? 0.45 : 0.25) : .clear,
                              lineWidth: 1)
        }
        .onHover { inside in withAnimation(LWMotion.hover) { hovering = inside } }
        .contextMenu {
            SetAsItems(roles: roles, isScene: item.isScene, assign: assign)
            Divider()
            Button("Remove…", role: .destructive, action: remove)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Inspector

@MainActor
struct LibraryInspectorView: View {
    @ObservedObject var model: SettingsModel
    let item: VideoItem?
    let openSteamSetup: () -> Void
    let remove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let item {
                    header(item)
                    setAsSection(item)
                    if item.isScene { SceneSettingsCard(model: model, item: item) }
                    LibrarySettingsCard(model: model)
                    removeSection(item)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "sidebar.right").font(.system(size: 22, weight: .light))
                        Text("Select a wallpaper").font(.callout.weight(.medium))
                        Text("Its settings and rotation options appear here.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.visible)
        .alert("Remove this wallpaper?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the downloaded files. You can download it again from the Workshop.")
        }
    }

    private func header(_ item: VideoItem) -> some View {
        HStack(spacing: 11) {
            ItemThumbnail(item: item, broken: model.brokenIDs.contains(item.id),
                          showsHoverPreview: false, cornerRadius: 8, size: .row)
                .frame(width: 76, height: 43)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Text(item.isScene ? "Scene" : "Video")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setAsSection(_ item: VideoItem) -> some View {
        let roles = model.roles(of: item.id)
        return InspectorSection(title: "Set as") {
            VStack(spacing: 6) {
                assignButton("Desktop", icon: "display", item: item, targets: [.desktop], roles: roles)
                assignButton("Lock Screen", icon: "lock.display", item: item, targets: [.lock], roles: roles)
                assignButton("Both", icon: "rectangle.on.rectangle", item: item, targets: [.desktop, .lock], roles: roles)
            }
        }
    }

    private func assignButton(_ title: String, icon: String, item: VideoItem,
                              targets: Set<WallpaperTarget>, roles: Set<WallpaperTarget>) -> some View {
        let selected = roles == targets
        return Button {
            model.assign(item.id, to: targets)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func removeSection(_ item: VideoItem) -> some View {
        InspectorSection(title: "Danger zone") {
            Button(role: .destructive) {
                if item.isWorkshop { confirmingRemoval = true } else { remove() }
            } label: {
                Label("Remove from library", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }
    }
}

// MARK: - Set as

@MainActor
fileprivate struct SetAsItems: View {
    let roles: Set<WallpaperTarget>
    var isScene = false
    let assign: (Set<WallpaperTarget>) -> Void

    var body: some View {
        entry("Set as Desktop", [.desktop], checked: roles.contains(.desktop))
        entry("Set as Lock Screen", [.lock], checked: roles.contains(.lock))
        entry("Set as Both", [.desktop, .lock], checked: roles.count == WallpaperTarget.allCases.count)
        if isScene {
            Divider()
            Text("On the lock screen a scene plays as a\n10-second loop, made once per screen size.")
        }
    }

    @ViewBuilder private func entry(_ title: String, _ targets: Set<WallpaperTarget>, checked: Bool) -> some View {
        Button { assign(targets) } label: {
            if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

// MARK: - Badges

@MainActor
struct SceneSupportBadge: View {
    let info: SceneInfo

    private var title: String {
        switch info.support {
        case .full: return "Scene"
        case .partial: return "Partial"
        case .previewOnly: return "Preview"
        }
    }

    private var tint: Color { info.support == .previewOnly ? .orange : .secondary }

    var body: some View {
        LWChip(text: title, tint: tint, icon: "sparkles")
            .help(info.notes.joined(separator: "\n"))
    }
}

@MainActor
fileprivate struct LockRenderLine: View {
    let status: LockRenderStatus

    var body: some View {
        switch status.state {
        case .rendering:
            VStack(alignment: .leading, spacing: 3) {
                Text("Rendering for lock screen… \(Int((min(max(status.progress, 0), 1) * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(max(status.progress, 0), 1))
                    .controlSize(.small)
            }
        case .queued:
            Text("Waiting to render for lock screen…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("Couldn’t render this for the lock screen.").font(.caption).foregroundStyle(.orange)
                .help(status.message ?? "")
        case .finished:
            EmptyView()
        }
    }
}

// MARK: - Settings card

/// Same-for-both switch, the rotation settings per target, and mute.
@MainActor
struct LibrarySettingsCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection(title: "Playback") {
                Toggle("Mute sound", isOn: $model.muted)
                    .help("Videos play silently. The lock screen never has sound.")
            }

            Divider()

            InspectorSection(title: "Rotation", subtitle: "Runs on a playlist you curate in Playlists.") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Same wallpaper for both", isOn: Binding(
                        get: { model.sameForBoth },
                        set: { model.setSameForBoth($0) }))

                    if model.sameForBoth {
                        RotationBlock(model: model, target: .desktop, title: nil)
                    } else {
                        if model.applyToDesktop { RotationBlock(model: model, target: .desktop, title: "Desktop") }
                        if model.applyToDesktop && model.applyToLockScreen { Divider() }
                        if model.applyToLockScreen { RotationBlock(model: model, target: .lock, title: "Lock Screen") }
                    }
                }
                .animation(LWMotion.panel, value: model.sameForBoth)
            }

            Divider()

            InspectorSection(title: "Scenes") {
                VStack(alignment: .leading, spacing: 14) {
                    LWSettingRow(title: "Frame rate",
                                 help: "Smoothness of scene wallpapers. Higher looks smoother but keeps the GPU busier.") {
                        Picker("Scene frame rate", selection: $model.sceneFPS) {
                            ForEach([20, 24, 30, 45, 60], id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    ScenePowerRows(model: model)
                }
            }

            Divider()

            lockNote
        }
    }

    private var lockNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("The lock screen uses an Apple Aerial wallpaper on macOS 26. Download and select any Aerial in Wallpaper settings once, and turn on “Show as screen saver” there.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Open Wallpaper Settings", destination: URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                .font(.caption)
        }
    }
}

@MainActor
struct RotationBlock: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget
    let title: String?
    @State private var intervalText: String
    @FocusState private var intervalFocused: Bool

    init(model: SettingsModel, target: WallpaperTarget, title: String?) {
        self._model = ObservedObject(wrappedValue: model)
        self.target = target
        self.title = title
        self._intervalText = State(initialValue: String(model.snapshot.config(for: target).intervalValue))
    }

    private var config: TargetConfig { model.snapshot.config(for: target) }
    private var hasPlaylist: Bool { config.playlist != nil }
    private var canRotate: Bool { hasPlaylist && model.snapshot.hasMultipleItems(target) }
    private var itemCount: Int { model.snapshot.items(for: target).count }
    private var enteredValue: Int? { Int(intervalText).flatMap { $0 > 0 ? min($0, 999) : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Rotate wallpaper")
                Spacer()
                Toggle("Rotate wallpaper", isOn: rotateBinding).labelsHidden().toggleStyle(.switch)
            }
            .disabled(!canRotate)
            .help("Automatically switch between your wallpapers, in list order.")
            if config.rotateEnabled && canRotate { intervalRow }
            if let helper {
                Text(helper.text)
                    .font(.caption)
                    .foregroundStyle(helper.warning ? Color.orange : Color.secondary)
            }
            if title != nil, let name = playingName {
                Text("Playing now: “\(name)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .animation(LWMotion.panel, value: config.rotateEnabled && canRotate)
        .onChange(of: config.intervalValue) { _, value in intervalText = String(value) }
    }

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("Every").font(.callout)
            TextField("", text: $intervalText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($intervalFocused)
                .onSubmit(commitInterval)
                .onChange(of: intervalFocused) { _, focused in if !focused { commitInterval() } }
                .accessibilityLabel("Interval value")
            Picker("Interval unit", selection: unitBinding) {
                ForEach(IntervalUnit.allCases) { Text($0.label.lowercased()).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 104)
        }
    }

    private var helper: (text: String, warning: Bool)? {
        guard canRotate else {
            if !hasPlaylist {
                return ("Rotation cycles a playlist you choose. Set one up in Playlists.", false)
            }
            return ("Add at least two wallpapers to the playlist to rotate.", false)
        }
        guard config.rotateEnabled else { return nil }
        if enteredValue == nil { return ("Enter a number from 1 to 999.", true) }
        if config.intervalIsClamped { return ("Minimum is 5 seconds.", true) }
        return ("Cycles through \(itemCount) wallpapers in playlist order.", false)
    }

    private var playingName: String? {
        guard model.isRunning, let id = model.currentID(for: target) else { return nil }
        return model.videos.first { $0.id == id }?.name
    }

    private var rotateBinding: Binding<Bool> {
        Binding(get: { config.rotateEnabled && canRotate },
                set: { if target == .desktop { model.rotateEnabled = $0 } else { model.lockConfig.rotateEnabled = $0 } })
    }

    private var unitBinding: Binding<IntervalUnit> {
        Binding(get: { config.intervalUnit },
                set: { if target == .desktop { model.intervalUnit = $0 } else { model.lockConfig.intervalUnit = $0 } })
    }

    private func commitInterval() {
        if let value = enteredValue {
            if target == .desktop { model.intervalValue = value } else { model.lockConfig.intervalValue = value }
        }
        intervalText = String(config.intervalValue)
    }
}

// MARK: - Preview player

@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var url: URL?
    private var isActive = true

    func load(_ url: URL?) {
        guard url != self.url else {
            setActive(isActive)
            return
        }
        self.url = url
        player?.pause()
        looper = nil
        player = nil
        guard let url else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        setActive(isActive)
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { player?.play() } else { player?.pause() }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct ItemPreviewPane: View {
    let item: VideoItem?
    let broken: Bool
    let openSteamSetup: () -> Void
    var showsNotes = true
    @StateObject private var preview = PreviewPlayer()
    @State private var sceneImage: NSImage?

    init(item: VideoItem?, broken: Bool, openSteamSetup: @escaping () -> Void, showsNotes: Bool = true) {
        self.item = item
        self.broken = broken
        self.openSteamSetup = openSteamSetup
        self.showsNotes = showsNotes
    }

    private var playbackURL: URL? { broken || item?.isScene == true ? nil : item?.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            stage
            if showsNotes, let info = item?.scene { SceneNotes(info: info, openSteamSetup: openSteamSetup) }
        }
    }

    private var stage: some View {
        MediaStage(item: item, broken: broken, preview: preview, sceneImage: sceneImage)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .task(id: playbackURL) { preview.load(playbackURL) }
            .task(id: item?.previewPath) {
                guard let path = item?.previewPath else { sceneImage = nil; return }
                // NSImage keeps the animation frames of a GIF preview, which a downsampled CGImage would drop.
                // Decoding it is heavy, so it happens off the main actor.
                let decoded = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: path) }.value
                if !Task.isCancelled { sceneImage = decoded }
            }
            .onAppear { preview.setActive(true) }
            .onDisappear { preview.setActive(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                if let window = note.object as? NSWindow, window.styleMask.contains(.titled) {
                    preview.setActive(window.occlusionState.contains(.visible))
                }
            }
    }
}

private struct MediaStage: View {
    let item: VideoItem?
    let broken: Bool
    @ObservedObject var preview: PreviewPlayer
    let sceneImage: NSImage?

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .overlay(alignment: .topLeading) {
            if let info = item?.scene { SceneSupportBadge(info: info).padding(9) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.map { "Preview of \($0.name)" } ?? "No wallpaper selected")
    }

    @ViewBuilder private var content: some View {
        if broken {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30)).foregroundStyle(.orange)
                Text(item?.isScene == true ? "Can’t show this wallpaper" : "Can’t play this video")
                    .font(.headline)
                Text("The file may have been moved or deleted.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        } else if let item {
            if item.isScene {
                if let sceneImage {
                    AnimatedImageView(image: sceneImage)
                } else {
                    Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.tertiary)
                }
            } else {
                PlayerSurface(player: preview.player)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 30, weight: .light))
                Text("Select a wallpaper").font(.callout)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// What a scene cannot do yet, as a short list, plus the way to get Wallpaper Engine's shared files.
@MainActor
fileprivate struct SceneNotes: View {
    let info: SceneInfo
    let openSteamSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(info.notes.enumerated()), id: \.offset) { entry in
                Text("• " + entry.element).font(.callout).foregroundStyle(.secondary)
            }
            if !SceneImporter.hasSharedAssets {
                Text("• Scenes need Wallpaper Engine’s shared files to play.").font(.callout).foregroundStyle(.secondary)
            }
            if info.needsSharedAssets || !SceneImporter.hasSharedAssets {
                Button("Get Wallpaper Engine’s shared files", action: openSteamSetup).buttonStyle(.link)
            }
        }
    }
}
