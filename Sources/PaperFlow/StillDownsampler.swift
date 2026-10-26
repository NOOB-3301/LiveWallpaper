import CoreGraphics
import Foundation
import ImageIO

/// The pixel bucket a still is decoded into, so ImageIO never hands back a full-resolution bitmap.
/// Card and row cover everything the scrollers draw at 2x; the hero preview is a live video or an
/// animated GIF, both of which need their original bytes.
enum ThumbnailSize: Int {
    case row = 220
    case card = 768
}

/// Still-image decode for previews and scene packages. ImageIO scales while reading, so a 4K preview costs
/// its bucket rather than its full bitmap. Blocking — call off the main actor.
enum StillDownsampler {
    static func image(atPath path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Without CacheImmediately the CGImage keeps a lazy provider and its pixels decode inside the
            // Core Animation commit, on the main thread, exactly when a cell scrolls in.
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
