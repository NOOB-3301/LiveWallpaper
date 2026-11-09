import SwiftUI
import AppKit
import Core
import UniformTypeIdentifiers

// Playlists. A playlist is a named, ordered list of library wallpapers plus the rules that move it along (shuffle,
// timer, change on wake), saved in state.json (LibraryState.playlists). Each screen runs one playlist or the whole
// library (TargetConfig.playlistID); the rules are copied onto the screen when a playlist is applied or edited.
//
// Pages: PlaylistView (all playlists + what each screen plays) and PlaylistDetailView (one playlist: name, rules,
// reorderable list). Every edit goes through SettingsModel, so the service stays the only writer.

private func screenName(_ target: WallpaperTarget) -> String { target == .desktop ? "Desktop" : "Lock Screen" }

enum PlaylistCopy {
    /// "3 wallpapers · Shuffle · every 5 minutes".
    static func summary(count: Int, rules: PlaylistRules) -> String {
        var parts = ["\(count) \(count == 1 ? "wallpaper" : "wallpapers")"]
        if rules.shuffle { parts.append("Shuffle") }
        if rules.rotateEnabled {
            let unit = rules.intervalUnit.label.lowercased()
            parts.append("every \(rules.intervalValue) \(rules.intervalValue == 1 ? String(unit.dropLast()) : unit)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Transport

/// Previous / pause / next for one screen, or both (`target` nil). Acts on what is playing now.
@MainActor
struct TransportControls: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget?

    var body: some View {
        HStack(spacing: 2) {
            button("backward.fill", "Previous") { model.previous(target: target) }
            button(model.isPaused ? "play.fill" : "pause.fill", model.isPaused ? "Resume" : "Pause") { model.togglePause() }
            button("forward.fill", "Next") { model.next(target: target) }
        }
        .disabled(!model.isRunning)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// "Desktop · Aurora" with transport controls: the item a screen shows right now.
@MainActor
private struct NowPlayingRow: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget
    var showsScreen = true
    var transportTarget: WallpaperTarget?

    private var item: VideoItem? {
        guard model.isRunning, let id = model.currentID(for: target) else { return nil }
        return model.videos.first { $0.id == id }
    }

    var body: some View {
        if let item {
            HStack(spacing: 10) {
                ItemThumbnail(item: item, broken: false, showsHoverPreview: false, cornerRadius: 5, size: .row)
                    .frame(width: 48, height: 27)
                VStack(alignment: .leading, spacing: 1) {
                    Text(showsScreen ? "Now playing · \(screenName(target))" : "Now playing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                TransportControls(model: model, target: transportTarget)
            }
        }
    }
}

// MARK: - Overview page

@MainActor
struct PlaylistView: View {
    @ObservedObject var model: SettingsModel
    let openPlaylist: (UUID) -> Void
    @State private var tab: WallpaperTarget = .desktop
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LWTheme.sectionSpacing) {
                LWPageHeader(title: "Playlists",
                             subtitle: "Group wallpapers into playlists, then choose what each screen plays.") {
                    Button { creating = true } label: { Label("New Playlist", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.videos.isEmpty)
                        .help(model.videos.isEmpty ? "Add wallpapers to your library first." : "Pick wallpapers, name them, and apply.")
                }

                playlists

                VStack(alignment: .leading, spacing: 14) {
                    Text("On your screens").font(.title3.weight(.semibold))
                    PlaylistSegmentedControl(selection: $tab)
                    PlaylistTargetPane(model: model, target: tab,
                                       openPlaylist: openPlaylist, create: { creating = true })
                }
            }
            .padding(LWTheme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .animation(LWMotion.content, value: tab)
        .sheet(isPresented: $creating) {
            NewPlaylistSheet(model: model, seed: [], applyTo: [], onCreated: openPlaylist)
        }
    }

    @ViewBuilder private var playlists: some View {
        if model.playlists.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No playlists yet").font(.headline)
                Text("Create one to pick wallpapers, name it, and play it on your desktop or lock screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Create Playlist") { creating = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.videos.isEmpty)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background { glassShape(radius: LWTheme.cardRadius) }
        } else {
            let desktop = model.activePlaylist(for: .desktop)?.id
            let lock = model.activePlaylist(for: .lock)?.id
            VStack(spacing: 10) {
                ForEach(model.playlists) { list in
                    PlaylistCard(model: model, list: list,
                                 runningOn: WallpaperTarget.allCases.filter { ($0 == .desktop ? desktop : lock) == list.id },
                                 open: { openPlaylist(list.id) })
                }
            }
            .animation(LWMotion.content, value: model.playlists)
        }
    }
}

@MainActor
private struct PlaylistCard: View {
    @ObservedObject var model: SettingsModel
    let list: SavedPlaylist
    let runningOn: [WallpaperTarget]
    let open: () -> Void
    @State private var confirmDelete = false

    private var items: [VideoItem] { list.itemIDs.compactMap { id in model.videos.first { $0.id == id } } }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: open) {
                HStack(spacing: 14) {
                    PlaylistThumbnails(model: model, items: items)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(list.name).font(.callout.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 5) {
                            Text(PlaylistCopy.summary(count: items.count, rules: list.rules))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            ForEach(runningOn, id: \.self) { target in
                                LWChip(text: screenName(target), tint: .accentColor, filled: true, icon: "checkmark")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)

            ApplyMenu(model: model, listID: list.id, enabled: !items.isEmpty)
            Button { confirmDelete = true } label: { Image(systemName: "trash") }
                .controlSize(.small)
                .help("Delete playlist")
                .accessibilityLabel("Delete \(list.name)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
        .contextMenu {
            Button("Open", action: open)
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .deleteConfirmation(isPresented: $confirmDelete, name: list.name, running: !runningOn.isEmpty) {
            model.deletePlaylist(list.id)
        }
    }
}

private extension View {
    func deleteConfirmation(isPresented: Binding<Bool>, name: String, running: Bool,
                            delete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete “\(name)”?", isPresented: isPresented) {
            Button("Delete Playlist", role: .destructive, action: delete)
        } message: {
            Text(running ? "Screens playing it go back to the whole library. Your wallpapers stay in the library."
                         : "Your wallpapers stay in the library.")
        }
    }
}

/// Up to four overlapping stills.
@MainActor
private struct PlaylistThumbnails: View {
    @ObservedObject var model: SettingsModel
    let items: [VideoItem]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(Array(items.prefix(4).enumerated()), id: \.element.id) { index, item in
                ItemThumbnail(item: item, broken: model.brokenIDs.contains(item.id),
                              showsHoverPreview: false, cornerRadius: 6, size: .row)
                    .frame(width: 64, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .zIndex(Double(-index))
            }
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: 64, height: 36)
            }
        }
        .frame(minWidth: 64, alignment: .leading)
    }
}

/// Apply ▾ Desktop / Lock Screen / Both.
@MainActor
private struct ApplyMenu: View {
    @ObservedObject var model: SettingsModel
    let listID: UUID
    let enabled: Bool
    var prominent = false

    var body: some View {
        Menu {
            Button("Desktop") { model.applyPlaylist(listID, to: [.desktop]) }
            Button("Lock Screen") { model.applyPlaylist(listID, to: [.lock]) }
            Button("Desktop & Lock Screen") { model.applyPlaylist(listID, to: [.desktop, .lock]) }
        } label: {
            Label("Apply", systemImage: "checkmark.circle")
        }
        .menuStyle(.button)
        .controlSize(prominent ? .regular : .small)
        .fixedSize()
        .disabled(!enabled)
    }
}

// MARK: - Segmented control

/// Two-option capsule segmented control with a sliding selection. Native accent, nothing else.
@MainActor
private struct PlaylistSegmentedControl: View {
    @Binding var selection: WallpaperTarget
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 4) {
            segment(.desktop, title: "Desktop", icon: "display")
            segment(.lock, title: "Lock Screen", icon: "lock.display")
        }
        .padding(4)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
        .fixedSize()
    }

    private func segment(_ target: WallpaperTarget, title: String, icon: String) -> some View {
        Button {
            withAnimation(LWMotion.select) { selection = target }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(selection == target ? Color.white : Color.secondary)
            .background {
                if selection == target {
                    Capsule()
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "selection", in: indicator)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == target ? .isSelected : [])
    }
}

// MARK: - Per-screen pane

@MainActor
private struct PlaylistTargetPane: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget
    let openPlaylist: (UUID) -> Void
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if target == .lock, model.sameForBoth {
                followCard
            } else {
                activeCard
                if target == .desktop, model.sameForBoth {
                    Label("The lock screen follows this playlist while “Same wallpaper for both” is on.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var followCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("The lock screen plays the desktop playlist.").font(.callout.weight(.medium))
                Text("Make it separate to choose its own playlist.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Use Separate Playlist") { model.setSameForBoth(false) }.controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }

    /// Both screens move together while they share one config.
    private var targets: Set<WallpaperTarget> { target == .desktop && model.sameForBoth ? [.desktop, .lock] : [target] }
    private var active: SavedPlaylist? { model.activePlaylist(for: target) }

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target == .desktop ? "Desktop plays" : "Lock Screen plays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(active?.name ?? "All wallpapers").font(.title3.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let active {
                    Button("Open") { openPlaylist(active.id) }.controlSize(.small)
                }
                Menu("Change") {
                    Button { model.applyPlaylist(nil, to: targets) } label: {
                        Label("All wallpapers", systemImage: active == nil ? "checkmark" : "")
                    }
                    if !model.playlists.isEmpty { Divider() }
                    ForEach(model.playlists) { list in
                        Button { model.applyPlaylist(list.id, to: targets) } label: {
                            Label(list.name, systemImage: active?.id == list.id ? "checkmark" : "")
                        }
                    }
                    Divider()
                    Button("New Playlist…", action: create)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }
            if model.isRunning, model.currentID(for: target) != nil {
                Divider()
                NowPlayingRow(model: model, target: target, showsScreen: false,
                              transportTarget: targets.count > 1 ? nil : target)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }

    private var subtitle: String {
        let count = model.playlistItems(for: target).count
        guard let active else { return "\(count) \(count == 1 ? "wallpaper" : "wallpapers") · library order" }
        return PlaylistCopy.summary(count: count, rules: active.rules)
    }
}

// MARK: - Detail page

/// One playlist: its name, rules and the reorderable list.
@MainActor
struct PlaylistDetailView: View {
    @ObservedObject var model: SettingsModel
    let id: UUID
    let onDeleted: () -> Void
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var ids: [UUID] = []          // live copy while dragging, committed on drop
    @State private var dragID: UUID?
    @State private var adding = false
    @State private var confirmDelete = false

    private var list: SavedPlaylist? { model.playlists.first { $0.id == id } }
    private var runningOn: [WallpaperTarget] {
        WallpaperTarget.allCases.filter { model.activePlaylist(for: $0)?.id == id }
    }
    private func playing(_ target: WallpaperTarget) -> UUID? { model.isRunning ? model.currentID(for: target) : nil }

    var body: some View {
        Group {
            if let list {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(list)
                        if model.isRunning, !runningOn.isEmpty { nowPlaying }
                        PlaylistRulesCard(model: model, list: list)
                        itemsSection(list)
                    }
                    .padding(LWTheme.contentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
            } else {
                Color.clear.onAppear(perform: onDeleted)
            }
        }
        .onAppear { sync() }
        .onChange(of: list) { sync() }
        .sheet(isPresented: $adding) {
            AddWallpapersSheet(model: model, playlistID: id)
        }
    }

    private func sync() {
        guard let list else { return }
        ids = list.itemIDs
        if !nameFocused { name = list.name }
    }

    // MARK: Header

    private func header(_ list: SavedPlaylist) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Playlist name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold))
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                HStack(spacing: 6) {
                    Text(PlaylistCopy.summary(count: list.itemIDs.count, rules: list.rules))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(runningOn, id: \.self) { target in
                        LWChip(text: screenName(target), tint: .accentColor, filled: true, icon: "checkmark")
                    }
                }
            }
            Spacer(minLength: 12)
            ApplyMenu(model: model, listID: id, enabled: !list.itemIDs.isEmpty, prominent: true)
            Menu {
                Button("Add Wallpapers…") { adding = true }
                Divider()
                Button("Delete Playlist…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
        }
        .deleteConfirmation(isPresented: $confirmDelete, name: list.name, running: !runningOn.isEmpty) {
            model.deletePlaylist(id)
            onDeleted()
        }
    }

    private func commitName() {
        guard var list else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { name = list.name; return }
        name = trimmed
        guard trimmed != list.name else { return }
        list.name = trimmed
        model.savePlaylist(list)
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(runningOn, id: \.self) { target in
                NowPlayingRow(model: model, target: target, transportTarget: runningOn.count > 1 ? nil : target)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }

    // MARK: Items

    private func itemsSection(_ list: SavedPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wallpapers").font(.title3.weight(.semibold))
                if list.rules.shuffle {
                    Text("Shown in list order; plays shuffled.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { adding = true } label: { Label("Add Wallpapers", systemImage: "plus") }
                    .controlSize(.small)
                    .disabled(model.videos.count == list.itemIDs.count)
            }
            if ids.isEmpty {
                HStack(spacing: 10) {
                    Text("This playlist is empty.").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Add Wallpapers…") { adding = true }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, itemID in
                        if let item = model.videos.first(where: { $0.id == itemID }) {
                            row(item, at: index)
                                .onDrag {
                                    dragID = itemID
                                    return NSItemProvider(object: itemID.uuidString as NSString)
                                }
                                .onDrop(of: [.text],
                                        delegate: PlaylistDropDelegate(targetID: itemID, ids: $ids, dragID: $dragID) {
                                            save(order: $0)
                                        })
                        }
                    }
                }
                .padding(6)
                .background { glassShape(radius: LWTheme.cardRadius) }
                .animation(.easeOut(duration: 0.2), value: ids)
            }
        }
    }

    private func save(order: [UUID]) {
        guard var list else { return }
        list.itemIDs = order
        model.savePlaylist(list)
    }

    private func row(_ item: VideoItem, at index: Int) -> some View {
        let screens = WallpaperTarget.allCases.filter { runningOn.contains($0) && playing($0) == item.id }
        return HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)
            ItemThumbnail(item: item, broken: model.brokenIDs.contains(item.id),
                          showsHoverPreview: false, cornerRadius: 6, size: .row)
                .frame(width: 72, height: 41)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    if let info = item.scene { SceneSupportBadge(info: info) } else { LWChip(text: "Video") }
                    if !screens.isEmpty {
                        LWChip(text: "Now playing", tint: .accentColor, filled: true, icon: "waveform")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                if !runningOn.isEmpty {
                    Button("Play Now") {
                        for target in runningOn { model.jump(to: item.id, on: target) }
                    }
                }
                Button("Move to Top") { save(order: [item.id] + ids.filter { $0 != item.id }) }
                    .disabled(index == 0)
                Button("Move to Bottom") { save(order: ids.filter { $0 != item.id } + [item.id]) }
                    .disabled(index == ids.count - 1)
                Divider()
                Button("Remove from Playlist", role: .destructive) { save(order: ids.filter { $0 != item.id }) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(item.name)")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dragID == item.id ? Color.primary.opacity(0.07) : .clear)
        }
        .opacity(dragID == item.id ? 0.65 : 1)
        .contextMenu {
            Button("Remove from Playlist", role: .destructive) { save(order: ids.filter { $0 != item.id }) }
        }
    }
}

/// Moves the dragged row as the pointer crosses other rows; commits the new order once, on drop.
private struct PlaylistDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var ids: [UUID]
    @Binding var dragID: UUID?
    let commit: ([UUID]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = dragID, dragged != targetID,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: targetID) else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        let settled = ids
        dragID = nil
        commit(settled)
        return true
    }
}

// MARK: - Rules

/// Shuffle, timer and wake behaviour of one playlist. Edits are saved at once and reach the screens running it.
@MainActor
private struct PlaylistRulesCard: View {
    @ObservedObject var model: SettingsModel
    let list: SavedPlaylist
    @State private var intervalText = ""
    @FocusState private var intervalFocused: Bool

    private var rules: PlaylistRules { list.rules }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                row("Shuffle", detail: "Plays every wallpaper once in random order before repeating.",
                    isOn: binding(\.shuffle))
                Divider()
                row("Change automatically", detail: nil, isOn: binding(\.rotateEnabled))
                if rules.rotateEnabled { intervalRow }
                Divider()
                row("Also change on wake and login",
                    detail: "Moves to the next wallpaper when your Mac wakes up or you sign in.",
                    isOn: binding(\.changeOnWake))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glassShape(radius: LWTheme.cardRadius) }
            if list.itemIDs.count < 2 {
                Text("Add at least two wallpapers for these to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { intervalText = String(rules.intervalValue) }
        .onChange(of: rules.intervalValue) { _, value in if !intervalFocused { intervalText = String(value) } }
    }

    private func row(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("Every").font(.callout).foregroundStyle(.secondary)
            TextField("", text: $intervalText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($intervalFocused)
                .onSubmit(commitInterval)
                .onChange(of: intervalFocused) { _, focused in if !focused { commitInterval() } }
                .accessibilityLabel("Interval value")
            Picker("Interval unit", selection: Binding(get: { rules.intervalUnit },
                                                       set: { value in edit { $0.rules.intervalUnit = value } })) {
                ForEach(IntervalUnit.allCases) { Text($0.label.lowercased()).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 104)
            if intervalIsShort {
                Text("Minimum is 5 seconds.").font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }

    private var intervalIsShort: Bool {
        Double(rules.intervalValue) * rules.intervalUnit.multiplier < LibraryState.minimumInterval
    }

    private func binding(_ keyPath: WritableKeyPath<PlaylistRules, Bool>) -> Binding<Bool> {
        Binding(get: { rules[keyPath: keyPath] }, set: { value in edit { $0.rules[keyPath: keyPath] = value } })
    }

    private func commitInterval() {
        if let value = Int(intervalText), value > 0 {
            let clamped = LibraryState.clampedInterval(value)
            if clamped != rules.intervalValue { edit { $0.rules.intervalValue = clamped } }
        }
        intervalText = String(rules.intervalValue)
    }

    /// Always applied to the stored playlist, never to a stale copy.
    private func edit(_ change: (inout SavedPlaylist) -> Void) {
        guard var current = model.playlists.first(where: { $0.id == list.id }) else { return }
        change(&current)
        model.savePlaylist(current)
    }
}

// MARK: - Sheets

/// Create a playlist: name it, click wallpapers in play order, optionally apply it.
@MainActor
private struct NewPlaylistSheet: View {
    @ObservedObject var model: SettingsModel
    let seed: [UUID]
    let applyTo: Set<WallpaperTarget>
    let onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked: [UUID] = []        // play order
    @State private var searchText = ""
    @State private var apply: Set<WallpaperTarget> = []

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New Playlist").font(.headline)
                TextField("Playlist name", text: $name).textFieldStyle(.roundedBorder)
                LWSearchField(prompt: "Search your library", text: $searchText)
            }
            .padding(16)
            Divider()
            WallpaperPickerList(model: model, searchText: searchText, picked: $picked, emptyText: "Your library is empty.")
            Divider()
            footer
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let valid = Set(model.videos.map(\.id))
            picked = seed.filter { valid.contains($0) }
            name = model.nextPlaylistName()
            apply = applyTo
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Text("Apply to").font(.caption).foregroundStyle(.secondary)
                Toggle("Desktop", isOn: applyBinding(.desktop))
                Toggle("Lock Screen", isOn: applyBinding(.lock))
                Spacer()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            HStack(spacing: 12) {
                PickerSelectAllButton(model: model, searchText: searchText, picked: $picked)
                Text(picked.isEmpty ? "Click wallpapers to add them in play order." : "\(picked.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(apply.isEmpty ? "Create Playlist" : "Create & Apply") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || picked.isEmpty)
            }
        }
        .padding(14)
    }

    private func applyBinding(_ target: WallpaperTarget) -> Binding<Bool> {
        Binding(get: { apply.contains(target) },
                set: { if $0 { apply.insert(target) } else { apply.remove(target) } })
    }

    private func create() {
        let id = model.createPlaylist(named: trimmedName, ids: picked)
        if !apply.isEmpty { model.applyPlaylist(id, to: apply) }
        dismiss()
        onCreated(id)
    }
}

/// Add more wallpapers to an existing playlist (only those it does not have yet).
@MainActor
private struct AddWallpapersSheet: View {
    @ObservedObject var model: SettingsModel
    let playlistID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var picked: [UUID] = []

    private var existing: Set<UUID> { Set(model.playlists.first { $0.id == playlistID }?.itemIDs ?? []) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add Wallpapers").font(.headline)
                LWSearchField(prompt: "Search your library", text: $searchText)
            }
            .padding(16)
            Divider()
            WallpaperPickerList(model: model, searchText: searchText, picked: $picked, excluding: existing,
                                emptyText: "Every wallpaper in your library is already in this playlist.")
            Divider()
            HStack(spacing: 12) {
                PickerSelectAllButton(model: model, searchText: searchText, picked: $picked, excluding: existing)
                Text(picked.isEmpty ? "" : "\(picked.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(picked.isEmpty ? "" : "\(picked.count) ")Wallpaper\(picked.count == 1 ? "" : "s")") {
                    model.addToPlaylist(playlistID, ids: picked)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(picked.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Every library wallpaper (minus `excluding`); clicking numbers it in play order.
@MainActor
private struct WallpaperPickerList: View {
    @ObservedObject var model: SettingsModel
    let searchText: String
    @Binding var picked: [UUID]
    var excluding: Set<UUID> = []
    let emptyText: String

    private var visible: [VideoItem] {
        model.videos.filter { !excluding.contains($0.id) }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if visible.isEmpty {
                    Text(searchText.isEmpty ? emptyText : "Nothing in your library matches “\(searchText)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }
                ForEach(visible) { item in candidateRow(item) }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.visible)
    }

    private func candidateRow(_ item: VideoItem) -> some View {
        let position = picked.firstIndex(of: item.id)
        return Button {
            if position != nil { picked.removeAll { $0 == item.id } } else { picked.append(item.id) }
        } label: {
            HStack(spacing: 12) {
                badge(position)
                ItemThumbnail(item: item, broken: model.brokenIDs.contains(item.id),
                              showsHoverPreview: false, cornerRadius: 5, size: .row)
                    .frame(width: 64, height: 36)
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let info = item.scene { SceneSupportBadge(info: info) } else { LWChip(text: "Video") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(position.map { "Position \($0 + 1)" } ?? "Not selected")
        .accessibilityAddTraits(position != nil ? .isSelected : [])
    }

    @ViewBuilder private func badge(_ position: Int?) -> some View {
        ZStack {
            if let position {
                Circle().fill(Color.accentColor)
                Text("\(position + 1)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(width: 20, height: 20)
    }
}

@MainActor
private struct PickerSelectAllButton: View {
    @ObservedObject var model: SettingsModel
    let searchText: String
    @Binding var picked: [UUID]
    var excluding: Set<UUID> = []

    private var visible: [UUID] {
        model.videos.filter { !excluding.contains($0.id) }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .map(\.id)
    }
    private var allPicked: Bool { !visible.isEmpty && visible.allSatisfy { picked.contains($0) } }

    var body: some View {
        Button(allPicked ? "Deselect All" : "Select All") {
            if allPicked {
                let shown = Set(visible)
                picked.removeAll { shown.contains($0) }
            } else {
                picked += visible.filter { !picked.contains($0) }
            }
        }
        .controlSize(.small)
        .disabled(visible.isEmpty)
    }
}
