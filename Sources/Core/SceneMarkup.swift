import Foundation
import SwiftSoup

// Wallpaper Engine renders a scene property's `text` (project.json general.properties) as a small HTML subset
// in its CEF editor. Authors rely on it for bold headings, <br>, <hr> separators, remote <img> rows, links and
// <font color>. This turns that markup into styled runs and blocks so SwiftUI never shows raw tags.
// SwiftSoup tokenizes and builds the DOM; the walk below decides what each node means to us.

public struct SceneMarkup: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading, center
    }

    public struct Color: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var isBold: Bool
        public var isItalic: Bool
        public var isUnderlined: Bool
        public var scale: Double        // 1 = normal; <big>/<small> compound
        public var color: Color?
        public var link: URL?

        public init(text: String, isBold: Bool = false, isItalic: Bool = false, isUnderlined: Bool = false,
                    scale: Double = 1, color: Color? = nil, link: URL? = nil) {
            self.text = text
            self.isBold = isBold
            self.isItalic = isItalic
            self.isUnderlined = isUnderlined
            self.scale = scale
            self.color = color
            self.link = link
        }

        fileprivate var style: Style { Style(bold: isBold, italic: isItalic, underlined: isUnderlined,
                                             scale: scale, color: color, link: link) }

        fileprivate init(text: String, style: Style) {
            self.init(text: text, isBold: style.bold, isItalic: style.italic, isUnderlined: style.underlined,
                      scale: style.scale, color: style.color, link: style.link)
        }
    }

    public struct Line: Equatable, Sendable {
        public var runs: [Run]
        public var alignment: Alignment
        public var isHeading: Bool

        public init(runs: [Run], alignment: Alignment = .leading, isHeading: Bool = false) {
            self.runs = runs
            self.alignment = alignment
            self.isHeading = isHeading
        }

        public var text: String { runs.map(\.text).joined() }
        public var isBlank: Bool { !text.contains(where: { !$0.isMarkupBlank }) }
    }

    public struct Image: Equatable, Sendable {
        public var url: URL
        public var width: Int?
        public var height: Int?
        public var alignment: Alignment

        public init(url: URL, width: Int? = nil, height: Int? = nil, alignment: Alignment = .leading) {
            self.url = url
            self.width = width
            self.height = height
            self.alignment = alignment
        }

        /// Chinese authors commonly use a 2000×1 (or 2/5 px) image as a horizontal separator.
        public var isSeparator: Bool {
            guard let height, height <= 8 else { return false }
            return width == nil || width! >= 120
        }
    }

    public enum Block: Equatable, Sendable {
        case line(Line)
        case rule
        case image(Image)
    }

    public let blocks: [Block]
    public let plainText: String
    /// True when the label is only rules/images/invisible padding — usually a decorative separator property.
    public let isDecorationOnly: Bool

    public init(_ raw: String) {
        let blocks = SceneMarkup.cleaned(SceneMarkup.blocks(from: raw))
        self.blocks = blocks
        let lines = blocks.compactMap { block -> String? in
            guard case .line(let line) = block else { return nil }
            return line.text
        }
        self.plainText = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(SceneMarkup.invisible))
        self.isDecorationOnly = plainText.isEmpty
    }

    // MARK: - Cleaning

    private static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200E}\u{200F}\u{FEFF}")

    private static func cleaned(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        for block in blocks {
            switch block {
            case .line(var line):
                trim(&line)
                if case .line(let previous)? = out.last, previous.isBlank, line.isBlank {
                    continue
                }
                out.append(.line(line))
            case .rule:
                if case .rule? = out.last { continue }
                out.append(.rule)
            case .image:
                out.append(block)
            }
        }
        while case .line(let line)? = out.first, line.isBlank { out.removeFirst() }
        while case .line(let line)? = out.last, line.isBlank { out.removeLast() }
        return out
    }

    /// Left/right padding is ignored by a browser at the start and end of a line; match that.
    private static func trim(_ line: inout Line) {
        guard !line.runs.isEmpty else { return }
        line.runs[0].text = String(line.runs[0].text.drop(while: { $0 == " " }))
        let last = line.runs.count - 1
        line.runs[last].text = String(line.runs[last].text.reversed().drop(while: { $0 == " " }).reversed())
        line.runs.removeAll { $0.text.isEmpty }
    }

    // MARK: - Parsing

    fileprivate struct Style: Equatable {
        var bold = false
        var italic = false
        var underlined = false
        var scale = 1.0
        var color: Color?
        var link: URL?
        var alignment: Alignment = .leading
        var headingLevel = 0
    }

    private static func blocks(from raw: String) -> [Block] {
        // Some authors saved JSON-escaped quotes inside the markup (src=\"...\" width=\"2000\"). A browser
        // would never see the backslash; removing it lets the tag parse the way its author intended.
        let source = raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
        guard let body = (try? SwiftSoup.parseBodyFragment(source))?.body() else {
            return [.line(Line(runs: [Run(text: source)]))]   // never drop what we cannot parse
        }
        var walker = Walker()
        for node in body.childNodesCopy() { walker.visit(node) }
        walker.flush(force: false)
        return walker.blocks
    }

    /// Depth-first walk of the DOM, carrying the style the enclosing tags ask for.
    fileprivate struct Walker {
        var style = Style()
        var line = Line(runs: [])
        var blocks: [Block] = []

        /// Block containers start a fresh line before and after their content.
        private static let blocksLine: Set<String> = ["p", "div", "blockquote", "li", "h1", "h2", "h3", "h4"]
        /// Never shown: markup that carries no words for the user.
        private static let skipped: Set<String> = ["style", "script", "head", "meta", "link", "title", "template"]

        mutating func visit(_ node: Node) {
            if node is Comment || node is DataNode { return }
            if let text = node as? TextNode {
                append(text.text())
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagName()
            if Self.skipped.contains(tag) { return }

            switch tag {
            case "br":
                flush(force: true)
            case "hr":
                flush(force: false)
                blocks.append(.rule)
            case "img":
                flush(force: false)
                if let image = image(element) { blocks.append(.image(image)) }
            default:
                let breaking = Self.blocksLine.contains(tag)
                if breaking { flush(force: false) }
                let enclosing = style
                style = Self.styled(style, by: tag, element: element)
                for child in element.childNodesCopy() { visit(child) }
                // Close the line while the block's own style still applies, then step back out.
                if breaking { flush(force: false) }
                style = enclosing
            }
        }

        // MARK: Style

        private static func styled(_ base: Style, by tag: String, element: Element) -> Style {
            var style = base
            switch tag {
            case "b", "strong":
                style.bold = true
            case "i", "em":
                style.italic = true
            case "u":
                style.underlined = true
            case "big":
                style.scale *= 1.2
            case "small":
                style.scale *= 0.85
            case "font":
                if let color = color(attribute("color", on: element)) { style.color = color }
            case "a":
                style.link = webURL(attribute("href", on: element))
            case "center":
                style.alignment = .center
            case "h1":
                style.headingLevel = 1; style.scale = max(style.scale, 1.6); style.bold = true
            case "h2":
                style.headingLevel = 2; style.scale = max(style.scale, 1.45); style.bold = true
            case "h3":
                style.headingLevel = 3; style.scale = max(style.scale, 1.3); style.bold = true
            case "h4":
                style.headingLevel = 4; style.scale = max(style.scale, 1.15); style.bold = true
            default:
                break       // unknown tags are dropped, their contents are kept
            }
            return style
        }

        // MARK: Text

        private mutating func append(_ raw: String) {
            var text = Self.collapseWhitespace(raw)
            guard !text.isEmpty else { return }
            if text.hasPrefix(" "), let last = line.runs.last, last.text.hasSuffix(" ") {
                text.removeFirst()
                guard !text.isEmpty else { return }
            }
            let run = Run(text: text, style: style)
            if let last = line.runs.last, last.style == style {
                line.runs[line.runs.count - 1].text += text
            } else {
                line.runs.append(run)
            }
        }

        mutating func flush(force: Bool) {
            let finished = Line(runs: line.runs, alignment: style.alignment, isHeading: style.headingLevel > 0)
            if force || !finished.isBlank || !finished.runs.isEmpty {
                blocks.append(.line(finished))
            }
            line = Line(runs: [], alignment: style.alignment, isHeading: style.headingLevel > 0)
        }

        private static func collapseWhitespace(_ text: String) -> String {
            var out = ""
            var lastWasSpace = false
            for character in text {
                let isSpace = character == " " || character == "\t" || character == "\n" || character == "\r"
                if isSpace {
                    if !lastWasSpace { out.append(" ") }
                } else {
                    out.append(character)
                }
                lastWasSpace = isSpace
            }
            return out
        }

        // MARK: Attributes

        private func image(_ element: Element) -> Image? {
            guard let source = Self.attribute("src", on: element), let url = Self.webURL(source) else { return nil }
            return Image(url: url, width: Self.int(Self.attribute("width", on: element)),
                         height: Self.int(Self.attribute("height", on: element)), alignment: style.alignment)
        }

        /// The parser has already decoded entities inside attribute values; an absent one reads as nil.
        private static func attribute(_ key: String, on element: Element) -> String? {
            guard element.hasAttr(key), let value = try? element.attr(key), !value.isEmpty else { return nil }
            return value
        }

        private static func int(_ raw: String?) -> Int? {
            guard let raw else { return nil }
            return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private static func webURL(_ raw: String?) -> URL? {
            guard let raw else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }

        private static func color(_ raw: String?) -> Color? {
            guard let raw else { return nil }
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("#") { value.removeFirst() }
            if value.count == 3 {
                value = value.map { "\($0)\($0)" }.joined()
            }
            if value.count == 6, let number = UInt32(value, radix: 16) {
                return Color(red: Double((number >> 16) & 0xFF) / 255,
                             green: Double((number >> 8) & 0xFF) / 255,
                             blue: Double(number & 0xFF) / 255)
            }
            switch value {
            case "white": return Color(red: 1, green: 1, blue: 1)
            case "black": return Color(red: 0, green: 0, blue: 0)
            case "red": return Color(red: 1, green: 0, blue: 0)
            case "green": return Color(red: 0, green: 0.5, blue: 0)
            case "blue": return Color(red: 0, green: 0, blue: 1)
            case "yellow": return Color(red: 1, green: 1, blue: 0)
            case "orange": return Color(red: 1, green: 0.6, blue: 0)
            case "pink": return Color(red: 1, green: 0.75, blue: 0.8)
            case "gray", "grey": return Color(red: 0.5, green: 0.5, blue: 0.5)
            case "cyan": return Color(red: 0, green: 1, blue: 1)
            case "magenta": return Color(red: 1, green: 0, blue: 1)
            case "purple": return Color(red: 0.5, green: 0, blue: 0.5)
            default: return nil
            }
        }
    }
}

private extension Character {
    var isMarkupBlank: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || $0 == "\u{200B}" || $0 == "\u{200E}" || $0 == "\u{200F}" || $0 == "\u{FEFF}"
        }
    }
}
