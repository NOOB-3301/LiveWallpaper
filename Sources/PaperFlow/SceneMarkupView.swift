import SwiftUI
import Core

/// Draws one Wallpaper Engine property label. The text is authored as a small HTML subset, parsed into
/// runs/blocks by Core's SceneMarkup: this view only maps that model to SwiftUI.
struct SceneMarkupView: View {
    let markup: SceneMarkup
    var baseSize: CGFloat = 13
    var maxImageWidth: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(markup.blocks.indices, id: \.self) { index in
                block(markup.blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ block: SceneMarkup.Block) -> some View {
        switch block {
        case .line(let line):
            lineView(line)
        case .rule:
            Divider().padding(.vertical, 2)
        case .image(let image):
            imageView(image)
        }
    }

    @ViewBuilder private func lineView(_ line: SceneMarkup.Line) -> some View {
        if line.isBlank {
            Color.clear.frame(height: baseSize * 0.8)
        } else {
            Text(attributed(line))
                .font(.system(size: baseSize))
                .multilineTextAlignment(line.alignment == .center ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: line.alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attributed(_ line: SceneMarkup.Line) -> AttributedString {
        var result = AttributedString()
        for run in line.runs {
            var piece = AttributedString(run.text)
            var font = Font.system(size: baseSize * run.scale)
            if run.isBold { font = font.bold() }
            if run.isItalic { font = font.italic() }
            piece.font = font
            if run.isUnderlined { piece.underlineStyle = .single }
            if let color = run.color {
                piece.foregroundColor = Color(red: color.red, green: color.green, blue: color.blue)
            }
            if let link = run.link {
                piece.link = link
                piece.foregroundColor = .accentColor
            }
            result += piece
        }
        return result
    }

    @ViewBuilder private func imageView(_ image: SceneMarkup.Image) -> some View {
        if image.isSeparator {
            Divider().padding(.vertical, 2)
        } else {
            AsyncImage(url: secure(image.url)) { phase in
                switch phase {
                case .success(let loaded):
                    loaded
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(image.width.map { CGFloat($0) } ?? maxImageWidth, maxImageWidth),
                               maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                case .failure:
                    EmptyView()
                case .empty:
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: min(image.width.map { CGFloat($0) } ?? 120, maxImageWidth),
                               height: min(image.height.map { CGFloat($0) } ?? 60, 160))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: image.alignment == .center ? .center : .leading)
        }
    }

    /// The app has no ATS exception for cleartext HTTP; the same CDNs answer on HTTPS.
    private func secure(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }
}
