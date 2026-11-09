import SwiftUI
import ImageIO

// Remote preview images for cards and rows. A Workshop preview is often a multi-megabyte GIF; a card needs one small
// still. The bytes are fetched through URLSession's own HTTP cache, decoded off the main actor straight into a
// card-sized bitmap (first frame only), and kept in a bounded in-memory cache, so scrolling back never decodes twice.
// The animated original is only loaded by the detail pane.

@MainActor
final class RemoteStillCache {
    static let shared = RemoteStillCache()

    private let cache = NSCache<NSString, Entry>()

    private final class Entry: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixel))?.image
    }

    /// Nil when the download or the decode failed, or the calling task was cancelled (a card scrolled away).
    func image(_ url: URL, maxPixel: Int) async -> CGImage? {
        let name = key(url, maxPixel)
        if let hit = cache.object(forKey: name)?.image { return hit }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        if Task.isCancelled { return nil }
        let decoded = await Task.detached(priority: .userInitiated) {
            StillDownsampler.image(data: data, maxPixel: maxPixel)
        }.value
        guard let decoded else { return nil }
        cache.setObject(Entry(decoded), forKey: name, cost: decoded.bytesPerRow * decoded.height)
        return decoded
    }

    private func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.absoluteString)|\(maxPixel)" as NSString
    }
}

/// Fills its frame with the still of `url` (cover-fit), or a quiet placeholder while it loads or when there is none.
@MainActor
struct RemoteStill: View {
    let url: URL?
    var maxPixel = 768
    var symbol = "film"
    @State private var image: CGImage?

    init(url: URL?, maxPixel: Int = 768, symbol: String = "film") {
        self.url = url
        self.maxPixel = maxPixel
        self.symbol = symbol
        _image = State(initialValue: url.flatMap { RemoteStillCache.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        // The rectangle alone sizes the view; the image sits in an overlay, so a large still can never push its
        // container's layout, and `clipped` trims what overflows.
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            if let loaded = await RemoteStillCache.shared.image(url, maxPixel: maxPixel) { image = loaded }
        }
    }
}
