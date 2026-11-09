import SwiftUI
import Core

// The pieces of the Workshop search bar: genre chips, sort menu, the Filters popover, the active-filter bar and the
// saved/recent searches row. The rules (what a filter means for Steam) live in WorkshopSearch.swift.

// MARK: - Genres

/// Steam's own genre tags as chips. Picking several narrows the list: an item must carry all of them.
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
            .padding(.vertical, 2)
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

/// What is narrowing the list right now, each piece removable, and a way to drop it all.
@MainActor
struct WorkshopActiveFilters: View {
    @ObservedObject var workshop: WorkshopModel

    var body: some View {
        let pieces = workshop.filters.pieces
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

@MainActor
struct WorkshopSavedRow: View {
    @ObservedObject var workshop: WorkshopModel

    private var showsRecents: Bool { !workshop.isSearching && !workshop.recentSearches.isEmpty }

    var body: some View {
        if !workshop.savedSearches.isEmpty || showsRecents {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if !workshop.savedSearches.isEmpty {
                        Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.secondary)
                        ForEach(workshop.savedSearches) { saved in
                            LWTopicChip(title: saved.title, selected: isCurrent(saved)) { workshop.apply(saved) }
                                .contextMenu {
                                    Button("Remove saved search", role: .destructive) {
                                        workshop.removeSavedSearch(saved.id)
                                    }
                                }
                                .help("Right-click to remove")
                        }
                    }
                    if showsRecents {
                        Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                        ForEach(workshop.recentSearches, id: \.self) { text in
                            LWTopicChip(title: text) { workshop.searchText = text }
                        }
                        Button("Clear") { workshop.clearRecentSearches() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func isCurrent(_ saved: WorkshopSavedSearch) -> Bool {
        saved.matches(text: workshop.searchText, sort: workshop.activeSort, period: workshop.trendPeriod,
                      filters: workshop.filters)
    }
}
