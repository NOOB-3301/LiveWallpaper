import SwiftUI
import AppKit
import Core

// The Playlists page. Playlists are named, ordered sets of library wallpapers saved in state.json
// (LibraryState.playlists). "New Playlist" opens a sheet: pick wallpapers, name it, optionally apply it. Each
// screen (Desktop, Lock Screen) runs one saved playlist (TargetConfig.playlistID) or the whole library, plus
// its rotation settings. Every edit goes through SettingsModel, so the service stays the only writer.

/// What the editor sheet opens with: an existing playlist, or a new one seeded with `seed` ids.
private struct PlaylistDraft: Identifiable {
    let id = UUID()
    var existing: SavedPlaylist? = nil
    var seed: [UUID] = []
    var applyTo: Set<WallpaperTarget> = []
}

@MainActor
struct PlaylistView: View {
    @ObservedObject var model: SettingsModel
    @State private var tab: WallpaperTarget = .desktop
    @State private var draft: PlaylistDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LWTheme.sectionSpacing) {
                LWPageHeader(title: "Playlists",
                             subtitle: "Group wallpapers into playlists, then choose what each screen plays.") {
                    Button { draft = PlaylistDraft() } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.videos.isEmpty)
                    .help(model.videos.isEmpty ? "Add wallpapers to your library first." : "Pick wallpapers, name them, and apply.")
                }

                PlaylistLibrarySection(model: model, draft: $draft)

                VStack(alignment: .leading, spacing: 14) {
                    Text("On your screens").font(.title3.weight(.semibold))
                    PlaylistSegmentedControl(selection: $tab)
                    PlaylistTargetPane(model: model, target: tab) { draft = $0 }
                }
            }
            .padding(LWTheme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .animation(LWMotion.content, value: tab)
        .sheet(item: $draft) { draft in
            PlaylistEditorSheet(model: model, draft: draft)
        }
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

// MARK: - Saved playlists

@MainActor
private struct PlaylistLibrarySection: View {
    @ObservedObject var model: SettingsModel
    @Binding var draft: PlaylistDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.playlists.isEmpty {
                emptyState
            } else {
                let running = Dictionary(uniqueKeysWithValues: WallpaperTarget.allCases.map {
                    ($0, model.activePlaylist(for: $0)?.id)
                })
                ForEach(model.playlists) { list in
                    PlaylistCard(model: model, list: list,
                                 runningOn: WallpaperTarget.allCases.filter { running[$0] == list.id }) {
                        draft = PlaylistDraft(existing: list)
                    }
                }
            }
        }
        .animation(LWMotion.content, value: model.playlists)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No playlists yet").font(.headline)
            Text("Create one to pick wallpapers, name it, and play it on your desktop or lock screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Playlist") { draft = PlaylistDraft() }
                .buttonStyle(.borderedProminent)
                .disabled(model.videos.isEmpty)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }
}

@MainActor
private struct PlaylistCard: View {
    @ObservedObject var model: SettingsModel
    let list: SavedPlaylist
    let runningOn: [WallpaperTarget]
    let onEdit: () -> Void
    @State private var confirmDelete = false

    private var items: [VideoItem] {
        list.itemIDs.compactMap { id in model.videos.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: -10) {
                ForEach(Array(items.prefix(4).enumerated()), id: \.element.id) { index, item in
                    ItemThumbnail(item: item, broken: model.brokenIDs.contains(item.id),
                                  showsHoverPreview: false, cornerRadius: 6, size: .row)
                        .frame(width: 64, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .zIndex(Double(-index))
                }
            }
            .frame(minWidth: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(list.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Text("\(items.count) \(items.count == 1 ? "wallpaper" : "wallpapers")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(runningOn, id: \.self) { target in
                        LWChip(text: target == .desktop ? "Desktop" : "Lock Screen",
                               tint: .accentColor, filled: true, icon: "checkmark")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("Desktop") { model.applyPlaylist(list.id, to: [.desktop]) }
                Button("Lock Screen") { model.applyPlaylist(list.id, to: [.lock]) }
                Button("Desktop & Lock Screen") { model.applyPlaylist(list.id, to: [.desktop, .lock]) }
            } label: {
                Label("Apply", systemImage: "checkmark.circle")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(items.isEmpty)

            Button(action: onEdit) { Image(systemName: "pencil") }
                .controlSize(.small)
                .help("Edit playlist")
                .accessibilityLabel("Edit \(list.name)")
            Button { confirmDelete = true } label: { Image(systemName: "trash") }
                .controlSize(.small)
                .help("Delete playlist")
                .accessibilityLabel("Delete \(list.name)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(list.name)”?", isPresented: $confirmDelete) {
            Button("Delete Playlist", role: .destructive) { model.deletePlaylist(list.id) }
        } message: {
            Text(runningOn.isEmpty
                 ? "Your wallpapers stay in the library."
                 : "Screens playing it go back to the whole library. Your wallpapers stay in the library.")
        }
    }
}

// MARK: - Per-target pane

@MainActor
private struct PlaylistTargetPane: View {
    @ObservedObject var model: SettingsModel
    let target: WallpaperTarget
    let openEditor: (PlaylistDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if target == .lock, model.sameForBoth {
                followCard
            } else {
                activeCard
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
                Text("Make it separate to choose its own playlist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Use Separate Playlist") { model.setSameForBoth(false) }
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }

    /// Both screens move together while they share one config.
    private var targets: Set<WallpaperTarget> { target == .desktop && model.sameForBoth ? [.desktop, .lock] : [target] }
    private var active: SavedPlaylist? { model.activePlaylist(for: target) }
    private var customIDs: [UUID]? { active == nil ? model.playlistIDs(for: target) : nil }

    private var activeCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target == .desktop ? "Desktop plays" : "Lock Screen plays")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(activeTitle).font(.title3.weight(.semibold))
                Text(activeSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let custom = customIDs {
                Button("Save as Playlist…") {
                    openEditor(PlaylistDraft(seed: custom, applyTo: targets))
                }
                .controlSize(.small)
            }
            Menu("Change") {
                Button { model.applyPlaylist(nil, to: targets) } label: {
                    Label("All wallpapers", systemImage: model.playlistIDs(for: target) == nil ? "checkmark" : "")
                }
                if !model.playlists.isEmpty { Divider() }
                ForEach(model.playlists) { list in
                    Button { model.applyPlaylist(list.id, to: targets) } label: {
                        Label(list.name, systemImage: active?.id == list.id ? "checkmark" : "")
                    }
                }
                Divider()
                Button("New Playlist…") { openEditor(PlaylistDraft(applyTo: targets)) }
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassShape(radius: LWTheme.cardRadius) }
    }

    private var activeTitle: String {
        if let active { return active.name }
        return customIDs == nil ? "All wallpapers" : "Custom selection"
    }

    private var activeSubtitle: String {
        let count = model.playlistItems(for: target).count
        let noun = "\(count) \(count == 1 ? "wallpaper" : "wallpapers")"
        return customIDs == nil && active == nil ? "\(noun) · library order" : noun
    }

    /// Rotation is a property of a chosen playlist; with the whole library there is nothing to show but the hint.
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
                Text("Apply a playlist to rotate wallpapers.")
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

// MARK: - Editor sheet

/// Create or edit a playlist: every library wallpaper is listed, picking numbers it in play order.
@MainActor
private struct PlaylistEditorSheet: View {
    @ObservedObject var model: SettingsModel
    let draft: PlaylistDraft
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked: [UUID] = []        // play order
    @State private var searchText = ""
    @State private var applyTo: Set<WallpaperTarget> = []

    private var isNew: Bool { draft.existing == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visible: [VideoItem] {
        model.videos.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    private var allVisiblePicked: Bool {
        !visible.isEmpty && visible.allSatisfy { picked.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(isNew ? "New Playlist" : "Edit Playlist").font(.headline)
                TextField("Playlist name", text: $name)
                    .textFieldStyle(.roundedBorder)
                LWSearchField(prompt: "Search your library", text: $searchText)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    if visible.isEmpty {
                        Text(model.videos.isEmpty
                             ? "Your library is empty."
                             : "Nothing in your library matches “\(searchText)”.")
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

            Divider()

            footer
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let valid = Set(model.videos.map(\.id))
            picked = (draft.existing?.itemIDs ?? draft.seed).filter { valid.contains($0) }
            name = draft.existing?.name ?? "Playlist \(model.playlists.count + 1)"
            applyTo = draft.applyTo
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if isNew {
                HStack(spacing: 14) {
                    Text("Apply to").font(.caption).foregroundStyle(.secondary)
                    Toggle("Desktop", isOn: applyBinding(.desktop))
                    Toggle("Lock Screen", isOn: applyBinding(.lock))
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
            HStack(spacing: 12) {
                Button(allVisiblePicked ? "Deselect All" : "Select All") {
                    if allVisiblePicked {
                        let hidden = Set(visible.map(\.id))
                        picked.removeAll { hidden.contains($0) }
                    } else {
                        picked += visible.map(\.id).filter { !picked.contains($0) }
                    }
                }
                .controlSize(.small)
                .disabled(visible.isEmpty)
                Text(picked.isEmpty ? "Click wallpapers to add them in play order." : "\(picked.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? (applyTo.isEmpty ? "Create Playlist" : "Create & Apply") : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || picked.isEmpty)
            }
        }
        .padding(14)
    }

    private func applyBinding(_ target: WallpaperTarget) -> Binding<Bool> {
        Binding(get: { applyTo.contains(target) },
                set: { if $0 { applyTo.insert(target) } else { applyTo.remove(target) } })
    }

    private func save() {
        let list = SavedPlaylist(id: draft.existing?.id ?? UUID(), name: trimmedName, itemIDs: picked)
        model.savePlaylist(list)
        if isNew, !applyTo.isEmpty { model.applyPlaylist(list.id, to: applyTo) }
        dismiss()
    }

    private func candidateRow(_ item: VideoItem) -> some View {
        let position = picked.firstIndex(of: item.id)
        return Button {
            if position != nil { picked.removeAll { $0 == item.id } } else { picked.append(item.id) }
        } label: {
            HStack(spacing: 12) {
                badge(position)
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
        .accessibilityLabel(item.name)
        .accessibilityValue(position.map { "Position \($0 + 1)" } ?? "Not in playlist")
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
