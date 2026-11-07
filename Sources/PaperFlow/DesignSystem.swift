import SwiftUI
import AppKit
import AVFoundation
import Core

// The shared visual language for the Settings app. Keep every custom colour, radius, curve and
// reusable surface here so the library, Workshop and Steam Setup feel like one product.
//
// The look: dark only, after Apple's Landmarks sample. The wallpaper is the content: it runs under the toolbar and
// the glass floats over it. The sidebar and inspector take its tint over their full height. Elsewhere one near-black
// colour, no gradients.
// Real Liquid Glass is for the control layer only: sidebar, toolbar, transport, buttons, search. Content
// cards are a solid fill, so a scrolling grid never samples a live backdrop. One accent gradient used
// sparingly, quiet typography. Reduce Transparency flattens the glass; animations respect Reduce Motion.

// MARK: - Tokens

enum LWTheme {
    static let contentPadding: CGFloat = 28
    static let cardRadius: CGFloat = 18
    static let panelRadius: CGFloat = 22
    static let sidebarWidth: CGFloat = 330
    static let inspectorWidth: CGFloat = 380
    static let gridSpacing: CGFloat = 20
    static let cardMinWidth: CGFloat = 252
    static let sectionSpacing: CGFloat = 26

    static let background = Color(white: 0.04)

    /// The content surface. Solid, so it costs nothing while the grid scrolls.
    static let surfaceCard = Color(white: 0.11)

    /// The light-catching top edge every raised surface shares. White over the fill, so it never changes
    /// the fill's contrast with the text on it.
    static let topSheen = LinearGradient(colors: [.white.opacity(0.16), .clear],
                                        startPoint: .top, endPoint: .center)

    /// The one accent gradient. Reserved for the drop-target border — never under text, never a hairline,
    /// never a card fill: a translucent accent behind white glyph text fails contrast in light mode.
    static let accentFlow = LinearGradient(colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.45)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
}

enum LWMotion {
    static let hover = Animation.spring(response: 0.18, dampingFraction: 0.90)
    static let select = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let panel = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let content = Animation.easeInOut(duration: 0.22)
    static let success = Animation.spring(response: 0.36, dampingFraction: 0.72)
}

// MARK: - Surfaces

/// The content surface: a flat card.
struct LWCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = LWTheme.cardRadius
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glassShape(radius: radius) }
    }
}

/// One surface shape used by cards, banners and rows: flat fill and a hairline.
@ViewBuilder
func glassShape(radius: CGFloat, cornerStyle: RoundedCornerStyle = .continuous,
                fill: some ShapeStyle = AnyShapeStyle(LWTheme.surfaceCard)) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: cornerStyle)
    shape.fill(fill)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
}

extension View {
    /// Wraps the view in the standard glass card.
    func lwGlassCard(padding cardPadding: CGFloat = 16, radius: CGFloat = LWTheme.cardRadius) -> some View {
        self.padding(cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glassShape(radius: radius) }
    }
}

/// Floating glass for the control layer only (transport, pills, search), never for content.
/// On macOS 26 this is real Liquid Glass; earlier systems get a quiet material fallback.
private struct LWGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let clear: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(clear ? .clear : .regular, in: shape)
        } else {
            content
                .background(reduceTransparency
                            ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                            : AnyShapeStyle(.ultraThinMaterial),
                            in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1) }
        }
    }
}

extension View {
    /// `clear` is for controls over a wallpaper only: Apple keeps it for visually rich backgrounds.
    func lwGlass(in shape: some InsettableShape = Capsule(), clear: Bool = false) -> some View {
        modifier(LWGlass(shape: shape, clear: clear))
    }

    /// Mirrors and blurs the view under the sidebar and inspector. One per page, on a still: it re-renders
    /// whatever it extends, so a playing video must not go through it.
    @ViewBuilder func lwBackgroundExtension() -> some View {
        if #available(macOS 26.0, *) { backgroundExtensionEffect() } else { self }
    }

    /// The primary action of a page or sheet.
    @ViewBuilder func lwProminentButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    /// A secondary action. Not for cells of a scrolling grid: that is content, and each would be a glass layer.
    @ViewBuilder func lwGlassButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }
}

// MARK: - Page header

/// The big page title and a quiet subtitle, used to open every page. Typography-led: no icons, no colour.
struct LWPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .kerning(-0.4)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.bottom, 2)
    }
}

extension LWPageHeader where Trailing == EmptyView {
    /// Header without trailing actions.
    init(title: String, subtitle: String = "") {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - Inspector pieces

struct InspectorSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
    }
}

// MARK: - Chips

struct LWChip: View {
    let text: String
    var tint: Color? = nil
    var filled: Bool = false
    var icon: String? = nil
    var selected: Bool = false

    private var color: Color { tint ?? .secondary }

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(filled || selected ? Color.white : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background {
            if selected {
                Capsule().fill(Color.accentColor)
                    .overlay(Capsule().fill(LWTheme.topSheen))
            } else {
                Capsule().fill(filled ? color : color.opacity(0.13))
            }
        }
        .overlay {
            if !filled && !selected {
                Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5)
            }
        }
    }
}

/// A tappable capsule used for topic chips and filter segments. Text only, system accent when selected.
struct LWTopicChip: View {
    let title: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule().fill(Color.accentColor)
                            .overlay(Capsule().fill(LWTheme.topSheen))
                    } else {
                        Capsule()
                            .fill(LWTheme.surfaceCard)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(LWMotion.hover, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Status

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulsing {
                    // Scoped to these two modifiers: a repeating `.animation(_:value:)` on the dot also caught
                    // its position while the sidebar laid out, and the dot drifted across the window for good.
                    Circle().stroke(color.opacity(0.45), lineWidth: 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                            $0.scaleEffect(on ? 2.1 : 0.9).opacity(on ? 0 : 1)
                        }
                }
            }
            .onAppear { on = pulsing }
            .onChange(of: pulsing) { _, isOn in on = isOn }
    }
}

/// Small animated equaliser shown while a wallpaper is on screen.
struct ActivityBars: View {
    let playing: Bool
    let paused: Bool
    var tint: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.09, paused: !playing || paused || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(width: 2.5, height: height(index: index, time: t))
                }
            }
            .frame(height: 13, alignment: .bottom)
        }
        .opacity(playing ? 1 : 0)
        .accessibilityHidden(true)
    }

    private func height(index: Int, time: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return index == 1 ? 9 : 5 }
        let phase = time * (2.1 + Double(index) * 0.35) + Double(index) * 1.7
        return 4 + CGFloat((sin(phase) + 1) / 2) * 9
    }
}

struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 34
    var lineWidth: CGFloat = 3
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: progress)
            if size >= 26 {
                Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Progress \(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
    }
}

/// A chunky linear progress bar for downloads. `progress` nil = indeterminate (a travelling highlight).
struct LWProgressBar: View {
    let progress: Double?
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelling = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let progress {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(height, min(max(progress, 0), 1) * proxy.size.width))
                        .animation(.easeOut(duration: 0.2), value: progress)
                } else {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: proxy.size.width * 0.3)
                        .offset(x: travelling ? proxy.size.width * 0.7 : 0)
                        .animation(reduceMotion ? nil
                                   : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                                   value: travelling)
                }
            }
        }
        .frame(height: height)
        .onAppear { travelling = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Search field

/// Glass capsule search field with icon, clear button and an escape-to-clear shortcut.
struct LWSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .lwGlass()
        .frame(maxWidth: 260)
    }
}

// MARK: - View helpers

extension View {
    /// The standard trailing inspector.
    @ViewBuilder
    func lwInspector<Inspector: View>(isPresented: Binding<Bool>,
                                      @ViewBuilder inspector: @escaping () -> Inspector) -> some View {
        self.inspector(isPresented: isPresented) {
            inspector()
                .inspectorColumnWidth(min: 320, ideal: LWTheme.inspectorWidth, max: 440)
        }
    }

    /// Cells dim and settle as they cross the viewport edge, tracking the fling. A no-op under Reduce Motion.
    func lwScrollEntry() -> some View {
        modifier(LWScrollEntry())
    }
}

private struct LWScrollEntry: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(.interactive) { view, phase in
                view.opacity(phase.isIdentity ? 1 : 0.8)
                    .scaleEffect(phase.isIdentity ? 1 : 0.985)
            }
        }
    }
}

// MARK: - Thumbnails

/// Shared thumbnail loading. Decodes downsampled off the main actor, keeps the result, and answers a
/// synchronous hit so a recycled cell can be seeded before its `.task` runs.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, ThumbnailEntry>()
    private var inFlight: [NSString: Task<CGImage?, Never>] = [:]

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ item: VideoItem, _ size: ThumbnailSize) -> CGImage? {
        cache.object(forKey: key(item, size))?.image
    }

    func image(for item: VideoItem, _ size: ThumbnailSize) async -> CGImage? {
        let name = key(item, size)
        if let hit = cache.object(forKey: name)?.image { return hit }
        if let pending = inFlight[name] { return await pending.value }

        let previewPath = item.previewPath
        let url = item.url
        let wantsVideoStill = !item.isScene
        let pixel = size.rawValue
        let task = Task<CGImage?, Never>.detached(priority: .userInitiated) {
            if let previewPath, let still = StillDownsampler.image(atPath: previewPath, maxPixel: pixel) {
                return still
            }
            guard wantsVideoStill else { return nil }
            return await VideoStills.cgImage(for: url, maxPixelSize: CGSize(width: pixel, height: pixel))
        }
        inFlight[name] = task
        let decoded = await task.value
        inFlight[name] = nil
        if let decoded {
            cache.setObject(ThumbnailEntry(decoded), forKey: name, cost: decoded.bytesPerRow * decoded.height)
        }
        return decoded
    }

    /// A re-download writes new bytes into the same library folder, so the replaced record's entries are stale.
    func invalidate(_ item: VideoItem) {
        for size in [ThumbnailSize.row, .card] {
            cache.removeObject(forKey: key(item, size))
        }
    }

    private func key(_ item: VideoItem, _ size: ThumbnailSize) -> NSString {
        "\(item.previewPath ?? item.path)|\(size.rawValue)" as NSString
    }
}

private final class ThumbnailEntry: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

struct ItemThumbnail: View {
    let item: VideoItem
    var broken = false
    var showsHoverPreview = true
    var cornerRadius: CGFloat = 12
    var size: ThumbnailSize = .card

    @State private var image: CGImage?
    @State private var hovering = false
    @State private var previewVisible = false
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(item: VideoItem, broken: Bool = false, showsHoverPreview: Bool = true,
         cornerRadius: CGFloat = 12, size: ThumbnailSize = .card) {
        self.item = item
        self.broken = broken
        self.showsHoverPreview = showsHoverPreview
        self.cornerRadius = cornerRadius
        self.size = size
        _image = State(initialValue: ThumbnailCache.shared.cached(item, size))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.05))

            if broken {
                VStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                    Text("Missing").font(.caption2)
                }
                .foregroundStyle(.orange)
            } else if let image {
                // In an overlay, so a fill image of another aspect can't grow the frame past the cell's 16:9.
                Color.clear.overlay {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                Image(systemName: item.isScene ? "photo" : "film")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
            }

            if previewVisible && !broken && !item.isScene {
                HoverPreview(item: item)
                    .transition(.opacity)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(item.previewPath ?? item.path)|\(size.rawValue)") {
            if let loaded = await ThumbnailCache.shared.image(for: item, size) { image = loaded }
        }
        .onHover(perform: hoverChanged)
        .onDisappear {
            previewTask?.cancel()
            previewVisible = false
        }
    }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        previewTask?.cancel()
        guard inside, showsHoverPreview, !item.isScene, !reduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            withAnimation(.easeOut(duration: 0.16)) { previewVisible = false }
            return
        }
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, hovering else { return }
            withAnimation(.easeInOut(duration: 0.2)) { previewVisible = true }
        }
    }
}

/// One decoder for the whole hover layer. A cell appearing must not spin up its own `AVQueuePlayer`: the
/// player keeps its identity and only its item changes, so no view has to observe anything.
@MainActor
final class HoverPlayer {
    static let shared = HoverPlayer()

    let player: AVQueuePlayer = {
        let queue = AVQueuePlayer()
        queue.isMuted = true
        return queue
    }()
    private var looper: AVPlayerLooper?
    private var url: URL?

    func show(_ url: URL) {
        guard url != self.url else { player.play(); return }
        self.url = url
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    /// A cell leaving must not pause a wallpaper a newer cell just started showing, so only the cell that
    /// still owns the player gets to stop it.
    func hide(ifShowing url: URL) {
        guard url == self.url else { return }
        player.pause()
    }
}

private struct HoverPreview: View {
    let item: VideoItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Color.black
            } else {
                PlayerSurface(player: HoverPlayer.shared.player)
            }
        }
        .allowsHitTesting(false)
        .onAppear { HoverPlayer.shared.show(item.url) }
        .onDisappear { HoverPlayer.shared.hide(ifShowing: item.url) }
    }
}

// MARK: - Empty states

/// A drop-in empty state used by the library and Workshop. One card: the dashed border and the surface
/// are the same rounded rectangle, so the border always contains everything inside it.
struct LWEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(targeted ? 0.10 : 0.06))
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            Text(targeted ? "Release to add" : title)
                .font(.title3.weight(.semibold))
            // Never pin this text to its full wrapped height (`fixedSize(vertical:)`): while sizing the window and its
            // split columns, SwiftUI measures the card at a very narrow width, so a pinned text reports a huge minimum
            // height. Next to the Library inspector, AppKit then re-solves the window's constraints until it throws
            // ("more Update Constraints in Window passes than there are views") and the app terminates at launch (seen
            // on macOS 27). Unpinned, the text still wraps in full: the card always gets the height it asks for.
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .lwProminentButton()
                        .controlSize(.large)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .lwGlassButton()
                        .controlSize(.large)
                }
            }
            .padding(.top, 2)
        }
        .padding(34)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background { glassShape(radius: 24) }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(targeted ? AnyShapeStyle(LWTheme.accentFlow)
                                       : AnyShapeStyle(Color.secondary.opacity(0.22)),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1,
                                                 dash: targeted ? [] : [6, 6]))
                .animation(LWMotion.hover, value: targeted)
        }
    }
}

// MARK: - Settings rows

struct LWSettingRow<Content: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.callout)
            Spacer(minLength: 8)
            content
        }
        .help(help ?? "")
    }
}

struct SkeletonBlock: View {
    var height: CGFloat = 12
    var width: CGFloat? = nil
    var radius: CGFloat = 6
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.secondary.opacity(dim ? 0.09 : 0.16))
            .frame(width: width, height: height)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
