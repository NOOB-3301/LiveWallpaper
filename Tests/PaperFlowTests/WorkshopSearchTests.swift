import Foundation
import Testing
@testable import PaperFlow

struct WorkshopSearchTests {
    private func value(_ name: String, in pairs: [(String, String)]) -> String? {
        pairs.first { $0.0 == name }?.1
    }

    private func values(prefix: String, in pairs: [(String, String)]) -> [String] {
        pairs.filter { $0.0.hasPrefix(prefix) }.map(\.1)
    }

    // MARK: Sort and text combine

    @Test func textSearchKeepsTheChosenSort() {
        let query = WorkshopQuery(text: "cyberpunk", sort: .popular)
        let pairs = query.pairs(appID: "431960")
        #expect(value("query_type", in: pairs) == "9")
        #expect(value("search_text", in: pairs) == "cyberpunk")
    }

    @Test func relevanceIsTheTextSearchRanking() {
        let pairs = WorkshopQuery(text: "anime", sort: .relevance).pairs(appID: "431960")
        #expect(value("query_type", in: pairs) == "12")
    }

    @Test func relevanceWithoutTextFallsBackToTrending() {
        let query = WorkshopQuery(text: "   ", sort: .relevance)
        #expect(query.effectiveSort == .trending)
        let pairs = query.pairs(appID: "431960")
        #expect(value("query_type", in: pairs) == "3")
        #expect(value("search_text", in: pairs) == nil)
    }

    @Test func trendingCarriesItsPeriodAndOthersDoNot() {
        let trending = WorkshopQuery(sort: .trending, period: .month).pairs(appID: "431960")
        #expect(value("days", in: trending) == "30")
        let newest = WorkshopQuery(sort: .newest, period: .month).pairs(appID: "431960")
        #expect(value("days", in: newest) == nil)
    }

    @Test func everySortHasItsOwnQueryType() {
        let types = WorkshopSort.allCases.map(\.queryType)
        #expect(Set(types).count == WorkshopSort.allCases.count)
    }

    // MARK: Filters

    @Test func defaultsMatchTheOldBrowse() {
        let pairs = WorkshopQuery().pairs(appID: "431960")
        #expect(values(prefix: "requiredtags", in: pairs).isEmpty)
        #expect(values(prefix: "excludedtags", in: pairs) == ["Questionable", "Mature"])
        #expect(value("match_all_tags", in: pairs) == nil)
        #expect(WorkshopFilters().isDefault)
    }

    @Test func genresMatchAllOfThem() {
        var filters = WorkshopFilters()
        filters.kind = .scene
        filters.toggle(genre: "Anime")
        filters.toggle(genre: "Cyberpunk")
        let pairs = WorkshopQuery(filters: filters).pairs(appID: "431960")
        #expect(values(prefix: "requiredtags", in: pairs) == ["Scene", "Anime", "Cyberpunk"])
        #expect(value("match_all_tags", in: pairs) == "true")
    }

    @Test func playableOnlyExcludesWhatCannotPlay() {
        var filters = WorkshopFilters()
        filters.playableOnly = true
        filters.rating = .mature
        #expect(filters.excludedTags == ["Web", "Application", "Preset", "Asset"])
    }

    @Test func ratingLimits() {
        #expect(WorkshopRating.everyone.excludedTags == ["Questionable", "Mature"])
        #expect(WorkshopRating.questionable.excludedTags == ["Mature"])
        #expect(WorkshopRating.mature.excludedTags.isEmpty)
    }

    @Test func togglingTwiceRemoves() {
        var filters = WorkshopFilters()
        filters.toggle(genre: "Nature")
        filters.toggle(feature: "Approved")
        #expect(!filters.isDefault)
        filters.toggle(genre: "Nature")
        filters.toggle(feature: "Approved")
        #expect(filters.isDefault)
    }

    @Test func advancedCountSkipsGenresAndKind() {
        var filters = WorkshopFilters()
        filters.kind = .scene
        filters.toggle(genre: "Anime")
        #expect(filters.advancedCount == 0)
        filters.toggle(feature: "HDR")
        filters.resolution = "1920 x 1080"
        filters.rating = .mature
        filters.playableOnly = true
        #expect(filters.advancedCount == 4)
    }

    @Test func genrePiecesAreFlagged() {
        var filters = WorkshopFilters()
        filters.kind = .scene
        filters.toggle(genre: "Anime")
        filters.toggle(feature: "HDR")
        #expect(filters.pieces.map(\.isGenre) == [false, true, false])
        #expect(filters.pieces.filter { !$0.isGenre }.map(\.label) == ["Scene", "HDR"])
    }

    @Test func queryKeyChangesWithTheQueryOnly() {
        var filters = WorkshopFilters()
        let base = filters.queryKey
        filters.toggle(genre: "Anime")
        #expect(filters.queryKey != base)
        filters.toggle(genre: "Anime")
        #expect(filters.queryKey == base)
    }

    // MARK: Clicking a tag

    @Test func tagsMapToTheirFilters() {
        var filters = WorkshopFilters()
        let results = ["anime", "Scene", "Approved", "2560 x 1440", "Mature"].map { filters.apply(tag: $0) }
        #expect(results == [true, true, true, true, true])
        #expect(filters.genres == ["Anime"])
        #expect(filters.kind == .scene)
        #expect(filters.features == ["Approved"])
        #expect(filters.resolution == "2560 x 1440")
        #expect(filters.rating == .mature)
    }

    @Test func applyingATagTwiceDoesNotDuplicateIt() {
        var filters = WorkshopFilters()
        filters.apply(tag: "Anime")
        filters.apply(tag: "Anime")
        #expect(filters.genres == ["Anime"])
    }

    @Test func unknownTagsAreLeftForTextSearch() {
        var filters = WorkshopFilters()
        let mapped = filters.apply(tag: "Genshin Impact")
        #expect(!mapped)
        #expect(filters.isDefault)
    }

    @Test func piecesCanBeRemovedOneByOne() {
        var filters = WorkshopFilters()
        filters.kind = .video
        filters.toggle(genre: "Space")   // not a Steam genre in the catalog: still stored when toggled directly
        filters.resolution = "1920 x 1080"
        filters.playableOnly = true
        for piece in filters.pieces { filters.remove(piece) }
        #expect(filters.isDefault)
    }

    // MARK: Saved and recent searches

    @Test func savedSearchTitle() {
        var filters = WorkshopFilters()
        filters.kind = .scene
        filters.toggle(genre: "Anime")
        let saved = WorkshopSavedSearch(text: "genshin", sort: .popular, period: .week, filters: filters)
        #expect(saved.title == "“genshin” · Scene · Anime · Most Subscribed")
        #expect(WorkshopSavedSearch(text: "", sort: .trending, period: .week, filters: WorkshopFilters()).title == "Everything")
    }

    @Test func savedSearchMatchesIgnoringCaseAndSpaces() {
        let saved = WorkshopSavedSearch(text: "Genshin", sort: .relevance, period: .week, filters: WorkshopFilters())
        #expect(saved.matches(text: " genshin ", sort: .relevance, period: .month, filters: WorkshopFilters()))
        #expect(!saved.matches(text: "genshin", sort: .newest, period: .week, filters: WorkshopFilters()))
    }

    @Test func recentsKeepTheNewestFirstWithoutDuplicates() {
        var list: [String] = []
        for text in ["a", "b", "c", "A", "  ", "d"] { list = WorkshopRecents.remembering(text, in: list) }
        #expect(list == ["d", "A", "c", "b"])
        for number in 0..<20 { list = WorkshopRecents.remembering("q\(number)", in: list) }
        #expect(list.count == WorkshopRecents.limit)
        #expect(list.first == "q19")
    }

    // MARK: Persistence

    @Test func prefsRoundTripAndSurviveMissingFields() throws {
        var prefs = WorkshopBrowsePrefs()
        prefs.sort = .popular
        prefs.filters.toggle(genre: "Anime")
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(WorkshopBrowsePrefs.self, from: data) == prefs)

        let sparse = try JSONDecoder().decode(WorkshopBrowsePrefs.self, from: Data(#"{"sort":"newest"}"#.utf8))
        #expect(sparse.sort == .newest)
        #expect(sparse.filters.isDefault)
    }

    @Test func savedRelevanceBrowseSortBecomesTrending() throws {
        let prefs = try JSONDecoder().decode(WorkshopBrowsePrefs.self, from: Data(#"{"sort":"relevance"}"#.utf8))
        #expect(prefs.sort == .trending)
    }

    @Test func garbageInStorageFallsBackToDefaults() throws {
        let prefs = try JSONDecoder().decode(
            WorkshopBrowsePrefs.self,
            from: Data(#"{"sort":"nonsense","period":99,"filters":{"genres":["Anime","Bogus"],"kind":"x"}}"#.utf8))
        #expect(prefs.sort == .trending)
        #expect(prefs.period == .week)
        #expect(prefs.filters.genres == ["Anime"])
        #expect(prefs.filters.kind == .all)
    }
}
