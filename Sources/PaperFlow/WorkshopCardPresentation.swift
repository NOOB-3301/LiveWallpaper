import Foundation

// What a Workshop poster card says about an item, as plain strings. The card shows two small badges (kind and a short
// resolution); everything else (size, date, rating, subscribers) lives in the detail pane. Foundation only, so it is
// unit-tested.

enum WorkshopCardCopy {
    /// "3840 x 2160" -> "4K". Multi-screen and portrait tags collapse to one word; vague tags ("Other resolution",
    /// "Dynamic resolution", "Standard Definition") say nothing useful at a glance, so they give nil.
    static func shortResolution(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let lower = tag.lowercased()
        for (prefix, word) in [("ultrawide", "Ultrawide"), ("dual", "Dual"), ("triple", "Triple"), ("portrait", "Portrait")]
        where lower.hasPrefix(prefix) {
            return word
        }
        let numbers = tag.split(whereSeparator: { $0 == " " }).compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        switch numbers[0] {
        case 7680...: return "8K"
        case 3840...: return "4K"
        case 2560...: return "1440p"
        case 1920...: return "1080p"
        case 1280...: return "720p"
        default: return nil
        }
    }

    /// "scene" -> "Scene". Kinds this app cannot play get their own word so the card can say so at a glance.
    static func kindLabel(_ kind: String?) -> String? {
        switch kind?.lowercased() {
        case "scene": return "Scene"
        case "video": return "Video"
        case "web": return "Web"
        case "application": return "App"
        default: return nil
        }
    }

    /// The badges in the card's top-left corner: kind, then resolution.
    static func badges(kind: String?, resolutionTag: String?) -> [String] {
        [kindLabel(kind), shortResolution(resolutionTag)].compactMap { $0 }
    }

    /// One spoken label for the whole card; the corner control is offered as a separate action.
    static func accessibilityLabel(title: String, kind: String?, resolutionTag: String?) -> String {
        ([title] + badges(kind: kind, resolutionTag: resolutionTag)).joined(separator: ", ")
    }
}
