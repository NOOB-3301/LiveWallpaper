import Foundation

// Workshop search: the pure part (no UI, no network, Foundation only). What the user can ask for (sort, filters,
// saved searches), the tag catalog of Wallpaper Engine's own Workshop, and how that becomes a QueryFiles request.
//
// The filter groups mirror the sidebar of Wallpaper Engine's Workshop page on steamcommunity.com (Type, Age Rating,
// Genre, Miscellaneous, Resolution), so a tag here means what the same tag means there. QueryFiles applies its
// required tags with AND (`match_all_tags`), exactly like the website: two genres narrow the list, they do not widen it.

// MARK: - Sort

enum WorkshopSort: String, CaseIterable, Identifiable, Codable {
    case relevance, trending, popular, newest, updated, topRated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: return "Relevance"
        case .trending: return "Trending"
        case .popular: return "Most Subscribed"
        case .newest: return "Newest"
        case .updated: return "Recently Updated"
        case .topRated: return "Top Rated"
        }
    }

    /// Relevance ranks by how well the text matches, so it only exists while searching.
    static let browseOptions: [WorkshopSort] = [.trending, .popular, .newest, .updated, .topRated]

    /// EPublishedFileQueryType.
    var queryType: Int {
        switch self {
        case .relevance: return 12    // RankedByTextSearch
        case .trending: return 3      // RankedByTrend
        case .popular: return 9       // RankedByTotalUniqueSubscriptions
        case .newest: return 1        // RankedByPublicationDate
        case .updated: return 21      // RankedByLastUpdatedDate
        case .topRated: return 0      // RankedByVote
        }
    }
}

/// The window "Trending" ranks over (QueryFiles `days`).
enum WorkshopTrendPeriod: Int, CaseIterable, Identifiable, Codable {
    case day = 1, week = 7, month = 30, quarter = 90, halfYear = 180

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .day: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        case .quarter: return "3 months"
        case .halfYear: return "6 months"
        }
    }
}

// MARK: - Tag catalog

enum WorkshopTags {
    /// Steam's "Genre" tags (without "Unspecified").
    static let genres = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
        "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature", "Pixel art", "Relaxing", "Retro", "Sci-Fi",
        "Sports", "Technology", "Television", "Vehicle",
    ]

    /// The useful part of Steam's "Miscellaneous" tags.
    static let features = ["Approved", "Audio responsive", "3D", "Customizable", "HDR", "Media Integration"]

    static let resolutionGroups: [(title: String, names: [String])] = [
        ("Standard", ["Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160"]),
        ("Ultrawide", ["Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440"]),
        ("Dual monitor", ["Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160"]),
        ("Triple monitor", ["Triple Standard Definition", "Triple 4096 x 768", "Triple 5760 x 1080",
                            "Triple 7680 x 1440", "Triple 11520 x 2160"]),
        ("Portrait", ["Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920",
                      "Portrait 1440 x 2560", "Portrait 2160 x 3840"]),
        ("Other", ["Other resolution", "Dynamic resolution"]),
    ]

    static var resolutions: [String] { resolutionGroups.flatMap(\.names) }

    /// Tags that Steam files under "Category" and "Type" and that this app cannot play.
    static let unplayable = ["Web", "Application", "Preset", "Asset"]

    /// The catalog's spelling of `tag` (case-insensitive), searched in `names`.
    static func canonical(_ tag: String, in names: [String]) -> String? {
        names.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

// MARK: - Filters

/// What the browse grid is narrowed to. Every field is a Steam tag, so it is applied by Steam itself.
enum WorkshopKindFilter: String, CaseIterable, Identifiable, Codable {
    case all, video, scene

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .video: return "Videos"
        case .scene: return "Scenes"
        }
    }

    /// Steam's own tag for this kind, when the list should be narrowed.
    var requiredTag: String? {
        switch self {
        case .all: return nil
        case .video: return "Video"
        case .scene: return "Scene"
        }
    }
}

/// The most explicit rating that may show. Steam rates items Everyone, Questionable or Mature.
enum WorkshopRating: String, CaseIterable, Identifiable, Codable {
    case everyone, questionable, mature

    var id: String { rawValue }
    var label: String {
        switch self {
        case .everyone: return "Everyone"
        case .questionable: return "Up to Questionable"
        case .mature: return "Everything"
        }
    }

    var excludedTags: [String] {
        switch self {
        case .everyone: return ["Questionable", "Mature"]
        case .questionable: return ["Mature"]
        case .mature: return []
        }
    }
}

struct WorkshopFilters: Equatable, Codable {
    var kind: WorkshopKindFilter = .all
    /// Hides what cannot play here: web and application wallpapers, presets and assets. Off by default, so the
    /// grid shows what Steam shows (unplayable items carry an "unsupported" note and no download).
    var playableOnly = false
    var genres: [String] = []        // all must match
    var features: [String] = []      // all must match
    var resolution: String?
    var rating: WorkshopRating = .everyone

    init() {}

    // Lenient on purpose: a field added later must not throw away what the user saved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = (try? c.decodeIfPresent(WorkshopKindFilter.self, forKey: .kind)) ?? .all
        playableOnly = (try? c.decodeIfPresent(Bool.self, forKey: .playableOnly)) ?? false
        genres = ((try? c.decodeIfPresent([String].self, forKey: .genres)) ?? []).compactMap {
            WorkshopTags.canonical($0, in: WorkshopTags.genres)
        }
        features = ((try? c.decodeIfPresent([String].self, forKey: .features)) ?? []).compactMap {
            WorkshopTags.canonical($0, in: WorkshopTags.features)
        }
        resolution = (try? c.decodeIfPresent(String.self, forKey: .resolution))
            .flatMap { WorkshopTags.canonical($0, in: WorkshopTags.resolutions) }
        rating = (try? c.decodeIfPresent(WorkshopRating.self, forKey: .rating)) ?? .everyone
    }

    private enum Keys: String, CodingKey { case kind, playableOnly, genres, features, resolution, rating }

    var isDefault: Bool { self == WorkshopFilters() }

    /// Tags an item must carry.
    var requiredTags: [String] {
        [kind.requiredTag].compactMap { $0 } + genres + features + [resolution].compactMap { $0 }
    }

    /// Tags an item must not carry.
    var excludedTags: [String] {
        rating.excludedTags + (playableOnly ? WorkshopTags.unplayable : [])
    }

    /// How many filters the "Filters" popover holds that are switched on (genres and kind have chips of their own).
    var advancedCount: Int {
        features.count + (resolution == nil ? 0 : 1) + (rating == .everyone ? 0 : 1) + (playableOnly ? 1 : 0)
    }

    /// One value that changes exactly when the Steam query changes.
    var queryKey: String { (requiredTags + ["!"] + excludedTags).joined(separator: ",") }

    mutating func toggle(genre: String) {
        if let index = genres.firstIndex(of: genre) { genres.remove(at: index) } else { genres.append(genre) }
    }

    mutating func toggle(feature: String) {
        if let index = features.firstIndex(of: feature) { features.remove(at: index) } else { features.append(feature) }
    }

    /// Narrows by a tag the user clicked (on a card or in the detail pane). False when the tag is not one Steam
    /// filters on, so the caller can fall back to a text search.
    @discardableResult
    mutating func apply(tag: String) -> Bool {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        if let kind = WorkshopKindFilter.allCases.first(where: { $0.requiredTag?.caseInsensitiveCompare(tag) == .orderedSame }) {
            self.kind = kind
        } else if let genre = WorkshopTags.canonical(tag, in: WorkshopTags.genres) {
            if !genres.contains(genre) { genres.append(genre) }
        } else if let feature = WorkshopTags.canonical(tag, in: WorkshopTags.features) {
            if !features.contains(feature) { features.append(feature) }
        } else if let size = WorkshopTags.canonical(tag, in: WorkshopTags.resolutions) {
            resolution = size
        } else if let rating = Self.rating(forTag: tag) {
            self.rating = rating
        } else {
            return false
        }
        return true
    }

    /// Steam's rating tag -> the most explicit rating that lets that item through.
    private static func rating(forTag tag: String) -> WorkshopRating? {
        switch tag.lowercased() {
        case "everyone": return .everyone
        case "questionable": return .questionable
        case "mature": return .mature
        default: return nil
        }
    }

    /// One removable piece of the active filters, in display order.
    struct Piece: Identifiable, Equatable {
        enum Kind: Equatable { case kind, playable, genre(String), feature(String), resolution, rating }
        let kind: Kind
        let label: String
        var id: String { label }
        /// Genres have chips of their own, so the applied-filter bar leaves them out.
        var isGenre: Bool {
            if case .genre = kind { return true }
            return false
        }
    }

    var pieces: [Piece] {
        var result: [Piece] = []
        if let tag = kind.requiredTag { result.append(Piece(kind: .kind, label: tag)) }
        result += genres.map { Piece(kind: .genre($0), label: $0) }
        result += features.map { Piece(kind: .feature($0), label: $0) }
        if let resolution { result.append(Piece(kind: .resolution, label: resolution)) }
        if rating != .everyone { result.append(Piece(kind: .rating, label: rating.label)) }
        if playableOnly { result.append(Piece(kind: .playable, label: "Playable only")) }
        return result
    }

    mutating func remove(_ piece: Piece) {
        switch piece.kind {
        case .kind: kind = .all
        case .playable: playableOnly = false
        case .genre(let name): genres.removeAll { $0 == name }
        case .feature(let name): features.removeAll { $0 == name }
        case .resolution: resolution = nil
        case .rating: rating = .everyone
        }
    }
}

// MARK: - Query

/// One page of a browse or search, and how it becomes QueryFiles parameters.
struct WorkshopQuery: Equatable {
    var text = ""
    var sort: WorkshopSort = .trending
    var period: WorkshopTrendPeriod = .week
    var filters = WorkshopFilters()
    var cursor = "*"
    var pageSize = 24

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Relevance means nothing without text; Steam's own page falls back to trending then, and so do we.
    var effectiveSort: WorkshopSort { trimmedText.isEmpty && sort == .relevance ? .trending : sort }

    /// The query string pairs, key excluded (the caller adds it, so it never lives in a value that is logged).
    /// Text and sort combine: `search_text` narrows whatever `query_type` ranks, like the website's search box.
    func pairs(appID: String) -> [(String, String)] {
        let sort = effectiveSort
        var pairs: [(String, String)] = [("appid", appID), ("creator_appid", appID), ("query_type", String(sort.queryType))]
        if sort == .trending { pairs.append(("days", String(period.rawValue))) }
        if !trimmedText.isEmpty { pairs.append(("search_text", trimmedText)) }
        pairs += [("cursor", cursor), ("numperpage", String(pageSize))]
        let required = filters.requiredTags
        for (index, tag) in required.enumerated() { pairs.append(("requiredtags[\(index)]", tag)) }
        if required.count > 1 { pairs.append(("match_all_tags", "true")) }
        for (index, tag) in filters.excludedTags.enumerated() { pairs.append(("excludedtags[\(index)]", tag)) }
        pairs += [("return_tags", "true"), ("return_short_description", "true"), ("return_previews", "false"),
                  ("return_vote_data", "false"), ("return_metadata", "false")]
        return pairs
    }
}

// MARK: - Saved and recent searches

struct WorkshopSavedSearch: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var sort: WorkshopSort
    var period: WorkshopTrendPeriod
    var filters: WorkshopFilters

    /// "cyberpunk · Scene · Anime", or "Everything" when nothing narrows it.
    var title: String {
        var parts: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append("“\(trimmed)”") }
        parts += filters.pieces.map(\.label)
        let defaultSort: WorkshopSort = trimmed.isEmpty ? .trending : .relevance
        if sort != defaultSort { parts.append(sort.label) }
        return parts.isEmpty ? "Everything" : parts.joined(separator: " · ")
    }

    /// The same search, whatever its name or id.
    func matches(text otherText: String, sort otherSort: WorkshopSort, period otherPeriod: WorkshopTrendPeriod,
                 filters otherFilters: WorkshopFilters) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
            otherText.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            && sort == otherSort && filters == otherFilters && (sort != .trending || period == otherPeriod)
    }
}

enum WorkshopRecents {
    static let limit = 8

    /// `text` first, without a copy further down, at most `limit` entries. Blank text changes nothing.
    static func remembering(_ text: String, in list: [String]) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        let rest = list.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        return Array(([trimmed] + rest).prefix(limit))
    }
}

// MARK: - Persistence

/// What the browse grid remembers between launches.
struct WorkshopBrowsePrefs: Codable, Equatable {
    var sort: WorkshopSort = .trending
    var period: WorkshopTrendPeriod = .week
    var filters = WorkshopFilters()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let saved = (try? c.decodeIfPresent(WorkshopSort.self, forKey: .sort)) ?? .trending
        sort = saved == .relevance ? .trending : saved     // relevance only exists while searching
        period = (try? c.decodeIfPresent(WorkshopTrendPeriod.self, forKey: .period)) ?? .week
        filters = (try? c.decodeIfPresent(WorkshopFilters.self, forKey: .filters)) ?? WorkshopFilters()
    }

    private enum Keys: String, CodingKey { case sort, period, filters }
}

enum WorkshopStore {
    static let browseKey = "LiveWallpaper.workshop.browse"
    static let savedKey = "LiveWallpaper.workshop.savedSearches"
    static let recentKey = "LiveWallpaper.workshop.recentSearches"

    static func load<Value: Decodable>(_ type: Value.Type, key: String, from defaults: UserDefaults = .standard) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    static func save<Value: Encodable>(_ value: Value, key: String, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
