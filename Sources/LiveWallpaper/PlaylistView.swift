import SwiftUI
import AppKit
import Core
import UniformTypeIdentifiers

// The Playlists page. Each screen (Desktop, Lock Screen) gets its own ordered list of wallpapers plus
// its rotation settings. The storage is TargetConfig.playlist in state.json (nil = the whole library in
// library order); every edit goes through SettingsModel.setPlaylist, so the service stays the only writer.

@MainActor
struct PlaylistView: View {
    @ObservedObject var model: SettingsModel
    @State private var tab: WallpaperTarget = .desktop

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LWTheme.sectionSpacing) {
                LWPageHeader(title: "Playlists",
                             subtitle: "Choose the wallpapers that rotate on each screen, and in what order.")
                PlaylistSegmentedControl(selection: $tab)
                PlaylistTargetPane(model: model, target: tab)
            }
            .padding(LWTheme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .animation(LWMotion.content, value: tab)
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

// MARK: - Per-target pane

@MainActor
private struct PlaylistTargetPane: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if target == .lock, model.sameForBoth {
                followCard
            } else {
                PlaylistEditorCard(model: model, target: target)
                rotationCard
                if target == .desktop, model.sameForBoth {
                    Label("The lock screen follows this playlist while “Same wallpaper for both” is on.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// While the two screens share one config, the lock screen has nothing of its own to edit.
    private var followCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("The lock screen plays the desktop playlist.")
                    .font(.callout.weight(.medium))
                Text("Make it separate to choose its own wallpapers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Use Separate Playlist") {
                let current = model.playlistItems(for: .lock).map(\.id)
                model.setPlaylist(current, for: .lock)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }

    /// Rotation is a property of a curated playlist; without one there is nothing to show but the hint.
    @ViewBuilder private var rotationCard: some View {
        if model.playlistIDs(for: target) != nil {
            InspectorSection(title: "Rotation") {
                RotationBlock(model: model, target: target, title: nil)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glassShape(radius: LWTheme.cardRadius) }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("Start a playlist above to rotate wallpapers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glassShape(radius: LWTheme.cardRadius) }
        }
    }
}

// MARK: - Editor card

@MainActor
private struct PlaylistEditorCard: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget
    @State private var addSheet = false
    @State private var dragID: UUID?
    @State private var ids: [UUID] = []          // live copy, committed on drop

    private var storedIDs: [UUID]? { model.playlistIDs(for: target) }
    private var isCustom: Bool { storedIDs != nil }
    private var items: [VideoItem] { model.playlistItems(for: target) }
    private var playingID: UUID? { model.isRunning ? model.currentID(for: target) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target == .desktop ? "Desktop playlist" : "Lock Screen playlist")
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Custom order", isOn: customBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Choose wallpapers and the order they play in.")
                if isCustom {
                    Button { addSheet = true } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            }

            if isCustom {
                if items.isEmpty { emptyRow } else { rows }
            } else {
                Text("Start a playlist and add wallpapers to play them in your own order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
        .sheet(isPresented: $addSheet) {
            PlaylistAddSheet(model: model, target: target) { added in
                model.setPlaylist((storedIDs ?? []) + added, for: target)
            }
        }
        .onAppear { ids = storedIDs ?? [] }
        .onChange(of: storedIDs ?? []) { _, stored in ids = stored }
        .animation(LWMotion.content, value: isCustom)
    }

    private var subtitle: String {
        guard isCustom else { return "No playlist yet" }
        let count = items.count
        return count == 0 ? "Empty" : "\(count) \(count == 1 ? "wallpaper" : "wallpapers") · drag to reorder"
    }

    /// Turning custom order on starts from the order the screen shows today.
    private var customBinding: Binding<Bool> {
        Binding(
            get: { isCustom },
            set: { on in
                model.setPlaylist(on ? items.map(\.id) : nil, for: target)
            })
    }

    // MARK Rows

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if let item = model.videos.first(where: { $0.id == id }) {
                    row(item, at: index)
                        .onDrag {
                            dragID = id
                            return NSItemProvider(object: id.uuidString as NSString)
                        }
                        .onDrop(of: [.text],
                                delegate: PlaylistDropDelegate(targetID: id, ids: $ids, dragID: $dragID) {
                                    model.setPlaylist($0, for: target)
                                })
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: ids)
    }

    private func row(_ item: VideoItem, at index: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            ItemThumbnail(item: item,
                          broken: model.brokenIDs.contains(item.id),
                          showsHoverPreview: false, cornerRadius: 6, size: .row)
                .frame(width: 72, height: 41)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if let info = item.scene {
                        SceneSupportBadge(info: info)
                    } else {
                        LWChip(text: "Video")
                    }
                    if item.id == playingID {
                        LWChip(text: "Now playing", tint: .accentColor, filled: true, icon: "waveform")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            Button {
                model.setPlaylist(ids.filter { $0 != item.id }, for: target)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from playlist")
            .accessibilityLabel("Remove \(item.name) from playlist")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dragID == item.id ? Color.primary.opacity(0.07) : .clear)
        }
        .opacity(dragID == item.id ? 0.65 : 1)
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Text("This playlist is empty — add some wallpapers.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Add Wallpapers…") { addSheet = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22),
                              style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
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

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let settled = ids
        dragID = nil
        commit(settled)
        return true
    }
}

// MARK: - Add sheet

@MainActor
private struct PlaylistAddSheet: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget
    let onAdd: ([UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selected: Set<UUID> = []

    private var inPlaylist: Set<UUID> { Set(model.playlistIDs(for: target) ?? []) }

    private var candidates: [VideoItem] {
        model.videos
            .filter { !inPlaylist.contains($0.id) }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add to \(target == .desktop ? "Desktop" : "Lock Screen") Playlist")
                    .font(.headline)
                LWSearchField(prompt: "Search your library", text: $searchText)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    if candidates.isEmpty {
                        Text(searchText.isEmpty
                             ? "Every wallpaper in your library is already in this playlist."
                             : "Nothing in your library matches “\(searchText)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                    ForEach(candidates) { item in
                        candidateRow(item)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)

            Divider()

            HStack(spacing: 12) {
                Text(selected.isEmpty ? "" : "\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(selected.isEmpty ? "" : "\(selected.count) ")Wallpaper\(selected.count == 1 ? "" : "s")") {
                    // Library order, so the appended order is stable.
                    let ordered = model.videos.filter { selected.contains($0.id) }.map(\.id)
                    onAdd(ordered)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 500, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func candidateRow(_ item: VideoItem) -> some View {
        let isSelected = selected.contains(item.id)
        return Button {
            if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 18)
                ItemThumbnail(item: item,
                              broken: model.brokenIDs.contains(item.id),
                              showsHoverPreview: false, cornerRadius: 5, size: .row)
                    .frame(width: 64, height: 36)
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let info = item.scene {
                    SceneSupportBadge(info: info)
                } else {
                    LWChip(text: "Video")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
