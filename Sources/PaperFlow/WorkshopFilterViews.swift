import SwiftUI
import AppKit
import Core

// The pieces of the Workshop filter bar: type, sort, the Filters popover, genre chips, applied-filter chips and the
// saved/recent searches menu, plus the toolbar search field. The rules (what a filter means for Steam) live in
// WorkshopSearch.swift.

// MARK: - The bar

/// Everything that narrows the grid, pinned above it. It sits outside the scroll view, so changing a filter never
/// means scrolling back up. The controls fold as the column narrows (the detail pane takes 330 pt of the window).
@MainActor
struct WorkshopFilterBar: View {
    @ObservedObject var workshop: WorkshopModel
    @State private var showFilters = false

    private enum Style { case full, compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                controls(.full)
                controls(.compact)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { kindPicker; Spacer(minLength: 8); filtersButton(.compact); WorkshopSavedMenu(workshop: workshop, compact: true) }
                    WorkshopSortMenu(workshop: workshop)
                }
            }
            WorkshopGenreRow(workshop: workshop)
            WorkshopActiveFilters(workshop: workshop)
        }
        .padding(.horizontal, LWTheme.contentPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func controls(_ style: Style) -> some View {
        HStack(spacing: 10) {
            kindPicker
            WorkshopSortMenu(workshop: workshop)
            filtersButton(style)
            Spacer(minLength: 8)
            WorkshopSavedMenu(workshop: workshop, compact: style == .compact)
            if style == .full {
                Text(countText).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
            }
        }
    }

    private var kindPicker: some View {
        Picker("Type", selection: $workshop.filters.kind) {
            ForEach(WorkshopKindFilter.allCases) { kind in Text(kind.label).tag(kind) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Videos, scenes, or both")
    }

    private func filtersButton(_ style: Style) -> some View {
        let count = workshop.filters.advancedCount
        return Button { showFilters.toggle() } label: {
            if style == .full {
                Label(count > 0 ? "Filters · \(count)" : "Filters", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                Label(count > 0 ? "\(count)" : "Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showFilters, arrowEdge: .bottom) { WorkshopFilterPopover(workshop: workshop) }
        .help(count > 0 ? "Filters (\(count) on): rating, resolution, features" : "Rating, resolution, features and more")
        .accessibilityLabel("Filters")
    }

    /// "12,431 wallpapers" when Steam said how many match, else what is loaded so far.
    private var countText: String {
        let count = workshop.totalResults ?? workshop.results.count
        return "\(count.formatted()) \(count == 1 ? "wallpaper" : "wallpapers")"
    }
}

// MARK: - Genres

/// Steam's own genre tags as chips. Picking several narrows the list: an item must carry all of them. A fade on the
/// trailing edge says the row scrolls.
@MainActor
struct WorkshopGenreRow: View {
    @ObservedObject var workshop: WorkshopModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LWTopicChip(title: "All genres", selected: workshop.filters.genres.isEmpty) {
                    workshop.filters.genres = []
                }
                ForEach(WorkshopTags.genres, id: \.self) { genre in
                    LWTopicChip(title: genre, selected: workshop.filters.genres.contains(genre)) {
                        workshop.filters.toggle(genre: genre)
                    }
                }
            }
            .padding(.trailing, 36)
            .padding(.vertical, 2)
        }
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 36)
            }
        }
    }
}

// MARK: - Sort

/// Order of the grid. While searching it offers Relevance too, and the choice is kept apart from the browse order.
@MainActor
struct WorkshopSortMenu: View {
    @ObservedObject var workshop: WorkshopModel

    private var options: [WorkshopSort] {
        workshop.isSearching ? [.relevance] + WorkshopSort.browseOptions : WorkshopSort.browseOptions
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(options) { sort in
                    Button {
                        workshop.activeSort = sort
                    } label: {
                        if sort == workshop.activeSort {
                            Label(sort.label, systemImage: "checkmark")
                        } else {
                            Text(sort.label)
                        }
                    }
                }
            } label: {
                Label(workshop.activeSort.label, systemImage: "arrow.up.arrow.down")
                    .font(.callout.weight(.medium))
            }
            .fixedSize()
            .help(workshop.isSearching ? "Order of the search results" : "Order of the browse grid")

            if workshop.activeSort == .trending {
                Menu {
                    ForEach(WorkshopTrendPeriod.allCases) { period in
                        Button {
                            workshop.trendPeriod = period
                        } label: {
                            if period == workshop.trendPeriod {
                                Label(period.label, systemImage: "checkmark")
                            } else {
                                Text(period.label)
                            }
                        }
                    }
                } label: {
                    Text(workshop.trendPeriod.label).font(.callout)
                }
                .fixedSize()
                .help("How far back Trending looks")
            }
        }
    }
}

// MARK: - Filters popover

@MainActor
struct WorkshopFilterPopover: View {
    @ObservedObject var workshop: WorkshopModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Playable only", isOn: $workshop.filters.playableOnly)
                Text("Hides web and application wallpapers, presets and assets.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Picker("Age rating", selection: $workshop.filters.rating) {
                ForEach(WorkshopRating.allCases) { rating in Text(rating.label).tag(rating) }
            }
            .pickerStyle(.menu)

            Menu {
                Button("Any resolution") { workshop.filters.resolution = nil }
                ForEach(Array(WorkshopTags.resolutionGroups.enumerated()), id: \.offset) { _, group in
                    Section(group.title) {
                        ForEach(group.names, id: \.self) { name in
                            Button(name) { workshop.filters.resolution = name }
                        }
                    }
                }
            } label: {
                Text("Resolution: " + (workshop.filters.resolution ?? "Any"))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Features").font(.subheadline.weight(.semibold))
                ForEach(WorkshopTags.features, id: \.self) { feature in
                    Toggle(feature, isOn: Binding(
                        get: { workshop.filters.features.contains(feature) },
                        set: { _ in workshop.filters.toggle(feature: feature) }))
                        .toggleStyle(.checkbox)
                }
                Text("Approved items were picked by the Wallpaper Engine team.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Button("Reset filters") { workshop.filters = WorkshopFilters() }
                .disabled(workshop.filters.isDefault)
        }
        .padding(16)
        .frame(width: 270)
    }
}

// MARK: - Active filters

/// What is narrowing the list besides the genre chips (which show their own state): the search text and each other
/// filter as a removable chip, and a way to drop it all. Hidden while there is nothing to show.
@MainActor
struct WorkshopActiveFilters: View {
    @ObservedObject var workshop: WorkshopModel

    var body: some View {
        let pieces = workshop.filters.pieces.filter { !$0.isGenre }
        if workshop.isSearching || !pieces.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if workshop.isSearching {
                        RemovableChip(text: "“\(workshop.searchText.trimmingCharacters(in: .whitespacesAndNewlines))”") {
                            workshop.searchText = ""
                        }
                    }
                    ForEach(pieces) { piece in
                        RemovableChip(text: piece.label) { workshop.filters.remove(piece) }
                    }
                    Button("Clear all") { workshop.resetSearch() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.vertical, 1)
            }
        }
    }
}

@MainActor
private struct RemovableChip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(text).font(.caption.weight(.medium))
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove “\(text)”")
        .accessibilityLabel("Remove \(text)")
    }
}

// MARK: - Saved and recent searches

/// One menu for what used to be two rows: saved searches (apply, save the current one, remove) and recent ones.
@MainActor
struct WorkshopSavedMenu: View {
    @ObservedObject var workshop: WorkshopModel
    var compact = false

    var body: some View {
        Menu {
            if !workshop.savedSearches.isEmpty {
                Section("Saved searches") {
                    ForEach(workshop.savedSearches) { saved in
                        Button { workshop.apply(saved) } label: {
                            if saved.matches(text: workshop.searchText, sort: workshop.activeSort,
                                             period: workshop.trendPeriod, filters: workshop.filters) {
                                Label(saved.title, systemImage: "checkmark")
                            } else {
                                Text(saved.title)
                            }
                        }
                    }
                }
            }
            Button { workshop.saveCurrentSearch() } label: {
                Label("Save current search", systemImage: "bookmark")
            }
            .disabled(!workshop.canSaveSearch)
            if !workshop.savedSearches.isEmpty {
                Menu("Remove a saved search") {
                    ForEach(workshop.savedSearches) { saved in
                        Button(saved.title, role: .destructive) { workshop.removeSavedSearch(saved.id) }
                    }
                }
            }
            if !workshop.recentSearches.isEmpty {
                Divider()
                Section("Recent searches") {
                    ForEach(workshop.recentSearches, id: \.self) { text in
                        Button(text) { workshop.searchText = text }
                    }
                }
                Button("Clear recent searches") { workshop.clearRecentSearches() }
            }
        } label: {
            if compact {
                Label("Saved", systemImage: "bookmark").labelStyle(.iconOnly)
            } else {
                Label("Saved", systemImage: "bookmark")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Saved and recent searches")
        .accessibilityLabel("Saved and recent searches")
    }
}

// MARK: - Toolbar search

/// The search field of the window toolbar while the Workshop is showing. A native `.searchable` would also be
/// contributed by the Workshop view while it is hidden (it stays alive between visits), clashing with the Library's.
struct WorkshopToolbarSearch: NSViewRepresentable {
    @Binding var text: String
    var prompt = "Search Workshop"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search the Workshop")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: 220, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func changed(_ sender: NSSearchField) {
            if text.wrappedValue != sender.stringValue { text.wrappedValue = sender.stringValue }
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { changed(field) }
        }
    }
}
