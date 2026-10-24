import SwiftUI
import AppKit
import Core

// The shared visual language for the Settings app. Keep every custom colour, radius, curve and
// reusable surface here so the library, Workshop and Steam Setup feel like one product.
//
// The look: soft ambient colour behind everything, translucent "liquid glass" surfaces on top with a
// light-catching top edge, one accent gradient used sparingly, and quiet typography that leans on
// weight and spacing. Materials respect Reduce Transparency; every animation respects Reduce Motion.

// MARK: - Tokens

enum LWTheme {
    static let contentPadding: CGFloat = 28
    static let cardRadius: CGFloat = 18
    static let panelRadius: CGFloat = 22
    static let sidebarWidth: CGFloat = 236
    static let inspectorWidth: CGFloat = 330
    static let gridSpacing: CGFloat = 20
    static let cardMinWidth: CGFloat = 252
    static let sectionSpacing: CGFloat = 26

    /// Hairline used on every glass edge: a light top and a shadowed bottom, in one pass.
    static let edgeGradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.28), location: 0),
            .init(color: .white.opacity(0.04), location: 0.35),
            .init(color: .black.opacity(0.10), location: 1),
        ],
        startPoint: .top, endPoint: .bottom)
}

enum LWMotion {
    static let hover = Animation.easeOut(duration: 0.16)
    static let select = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let hero = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let panel = Animation.easeInOut(duration: 0.26)
    static let content = Animation.easeInOut(duration: 0.22)
    static let success = Animation.spring(response: 0.36, dampingFraction: 0.72)
}

// MARK: - Ambient background

/// The page background every content area sits on. Deliberately plain: the window colour and nothing else.
/// The depth in this app comes from the glass surfaces and their hairlines, not from colour washes.
struct LWBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

// MARK: - Surfaces

/// The content surface: a translucent card with a light-catching top edge and a soft shadow. This is the
/// app's glass — solid fill when the user asked for reduced transparency.
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

/// One glass shape used by cards, banners and rows: material fill, top sheen, gradient hairline, shadow.
@ViewBuilder
func glassShape(radius: CGFloat, cornerStyle: RoundedCornerStyle = .continuous,
                fill: some ShapeStyle = AnyShapeStyle(.regularMaterial)) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: cornerStyle)
    ZStack {
        shape.fill(fill)
        LinearGradient(colors: [.white.opacity(0.16), .clear],
                       startPoint: .top, endPoint: .center)
            .clipShape(shape)
    }
    .overlay(shape.strokeBorder(LWTheme.edgeGradient, lineWidth: 1))
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
}

extension View {
    /// Wraps the view in the standard glass card.
    func lwGlassCard(padding cardPadding: CGFloat = 16, radius: CGFloat = LWTheme.cardRadius) -> some View {
        self.padding(cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glassShape(radius: radius) }
    }
}

/// Floating glass for the navigation/transport layer only (hero controls, status popover, pills).
/// On macOS 26 this is real Liquid Glass; earlier systems get a quiet material fallback.
struct GlassPanel<Content: View>: View {
    var radius: CGFloat = 18
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(reduceTransparency
                            ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                            : AnyShapeStyle(.ultraThinMaterial),
                            in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
        }
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
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
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
                    } else {
                        Capsule()
                            .fill(.regularMaterial)
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
                    Circle().stroke(color.opacity(0.45), lineWidth: 1)
                        .scaleEffect(on ? 2.1 : 0.9)
                        .opacity(on ? 0 : 1)
                }
            }
            .animation(pulsing ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default, value: on)
            .onAppear { on = pulsing }
            .onChange(of: pulsing) { on = $0 }
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
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
        .frame(maxWidth: 260)
    }
}

// MARK: - View helpers

extension View {
    func hoverLift(_ enabled: Bool = true) -> some View {
        modifier(HoverLiftModifier(enabled: enabled))
    }

    /// The inspector on macOS 14+, a trailing panel on older systems. Keeps the app on its macOS 13 floor.
    @ViewBuilder
    func lwInspector<Inspector: View>(isPresented: Binding<Bool>,
                                      @ViewBuilder inspector: @escaping () -> Inspector) -> some View {
        if #available(macOS 14.0, *) {
            self.inspector(isPresented: isPresented) {
                inspector()
                    .inspectorColumnWidth(min: 280, ideal: LWTheme.inspectorWidth, max: 380)
            }
        } else {
            HStack(spacing: 0) {
                self
                if isPresented.wrappedValue {
                    Divider()
                    inspector().frame(width: LWTheme.inspectorWidth)
                }
            }
        }
    }
}

private struct HoverLiftModifier: ViewModifier {
    let enabled: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && hovering && !reduceMotion ? 1.015 : 1)
            .shadow(color: .black.opacity(hovering && enabled ? 0.22 : 0), radius: hovering ? 16 : 0, y: hovering ? 8 : 0)
            .animation(LWMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Thumbnails

/// Shared thumbnail loading. Decodes once, keeps the result, and never does disk work in `body`.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for item: VideoItem) async -> NSImage? {
        let key = (item.previewPath ?? item.path) as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image: NSImage?
        if let preview = item.previewPath, let loaded = NSImage(contentsOfFile: preview) {
            image = loaded
        } else if !item.isScene,
                  let cgImage = await VideoStills.cgImage(for: item.url,
                                                          maxPixelSize: CGSize(width: 640, height: 360)) {
            image = NSImage(cgImage: cgImage, size: .zero)
        } else {
            image = nil
        }

        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

struct ItemThumbnail: View {
    let item: VideoItem
    var broken = false
    var showsHoverPreview = true
    var cornerRadius: CGFloat = 12

    @State private var image: NSImage?
    @State private var hovering = false
    @State private var previewVisible = false
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
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
        .task(id: [item.path, item.previewPath ?? ""]) {
            let loaded = await ThumbnailCache.shared.image(for: item)
            withAnimation(.easeInOut(duration: 0.2)) { image = loaded }
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
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled, hovering else { return }
            withAnimation(.easeInOut(duration: 0.2)) { previewVisible = true }
        }
    }
}

private struct HoverPreview: View {
    let item: VideoItem
    @StateObject private var player = PreviewPlayer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Color.black
            } else {
                PlayerSurface(player: player.player)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            player.load(item.url)
            player.setActive(true)
        }
        .onDisappear { player.setActive(false) }
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
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(.bordered)
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
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.22),
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
