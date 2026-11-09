import Foundation

// The Library page's presentation rules that need no UI: how the stage (preview + details) lays out at a given
// width, and the wording of the count line and the rotation summary. Foundation only, so it is unit-tested.

/// How the stage at the top of the Library arranges its preview and its details.
enum LibraryStageLayout: Equatable {
    case wide       // preview left, details right
    case medium     // the same with a smaller preview
    case stacked    // preview above the details, height capped

    /// `width` is the width of the stage itself (the page minus its padding, and minus the inspector when open).
    static func forWidth(_ width: Double) -> LibraryStageLayout {
        width >= 720 ? .wide : (width >= 480 ? .medium : .stacked)
    }

    /// The preview is 16:9, so this also fixes the stage's height: at most 231 pt wide, 200 pt stacked.
    func previewWidth(contentWidth: Double) -> Double {
        switch self {
        case .wide: return min(410, (contentWidth * 0.46).rounded(.down))
        case .medium: return 240
        case .stacked: return min(max(contentWidth, 0), 356)
        }
    }
}

enum LibraryCountScope: Equatable {
    case all, desktop, lock, scenes
}

enum LibraryCopy {
    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    /// The line above the grid: the count, or what is selected while selecting, or how many results a search has.
    static func countTitle(count: Int, scope: LibraryCountScope, selected: Int, selecting: Bool, search: String) -> String {
        if selected > 1 { return "\(selected) selected" }
        if selecting { return selected == 0 ? "Select wallpapers" : "1 selected" }
        if !search.isEmpty { return "\(plural(count, "result", "results")) for “\(search)”" }
        switch scope {
        case .all: return plural(count, "wallpaper", "wallpapers")
        case .desktop: return "\(count) set for your desktop"
        case .lock: return "\(count) set for the lock screen"
        case .scenes: return "\(count) Wallpaper Engine \(count == 1 ? "scene" : "scenes")"
        }
    }

    /// The grey line under a library card's name: "Scene · Workshop · by Talia".
    static func cardSubtitle(isScene: Bool, isWorkshop: Bool, author: String?) -> String {
        var parts = [isScene ? "Scene" : "Video"]
        if isWorkshop { parts.append("Workshop") }
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty { parts.append("by \(author)") }
        return parts.joined(separator: " · ")
    }

    /// One line under the stage's buttons; rotation itself is edited on the Playlists page.
    static func rotationSummary(desktop: Bool, lock: Bool) -> String {
        switch (desktop, lock) {
        case (true, true): return "Rotation is on for both screens."
        case (true, false): return "Rotation is on for the desktop."
        case (false, true): return "Rotation is on for the lock screen."
        case (false, false): return "Rotation is off."
        }
    }
}
