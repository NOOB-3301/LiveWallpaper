import SwiftUI
import AppKit
import Core

// The Workshop detail pane (SPEC3.md 6.3): opens when a result is clicked. Large preview that ANIMATES (Workshop
// previews are often GIFs), title, tags, size, description, Download; after the download the pane shows the
// library item's own preview (the muted looping video, or the scene preview with its support badge).

/// NSImageView with `animates = true`, so animated GIF previews play. SwiftUI's Image and AsyncImage show frame 1.
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage?

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.isEditable = false
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }

    /// An NSImageView asks for the image's pixel size, which for a 4K preview pushes the whole pane apart.
    /// The view takes the size SwiftUI proposes and scales the image into it instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Loads a preview image from a URL (http(s) or file) once; keeps the original bytes so GIFs keep their frames.
@MainActor final class WorkshopPreviewLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var failed = false

    func load(_ url: URL?) async {
        image = nil
        failed = false
        guard let url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if Task.isCancelled { return }
            if let loaded = NSImage(data: data) { image = loaded } else { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

/// Lays chips and small buttons out in rows that wrap at the available width.
fileprivate struct WrappingRows: Layout {
    private let gap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = place(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, placed.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - gap)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}

@MainActor
struct WorkshopDetailView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let item: WorkshopItem
    let close: () -> Void
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void
    let narrowTo: (String) -> Void          // a tag was clicked: filter the results by it
    let open: (WorkshopItem) -> Void        // another item of the same creator was clicked
    @StateObject private var preview = WorkshopPreviewLoader()
    @State private var creatorItems: [WorkshopItem] = []

    init(model: SettingsModel, workshop: WorkshopModel, item: WorkshopItem, close: @escaping () -> Void,
         openSteamSetup: @escaping () -> Void, openLibrary: @escaping () -> Void,
         narrowTo: @escaping (String) -> Void, open: @escaping (WorkshopItem) -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._workshop = ObservedObject(wrappedValue: workshop)
        self.item = item
        self.close = close
        self.openSteamSetup = openSteamSetup
        self.openLibrary = openLibrary
        self.narrowTo = narrowTo
        self.open = open
    }

    private var libraryItem: VideoItem? { model.videos.first { $0.workshopID == item.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(action: close) {
                        Label("Results", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    if let url = steamCommunityURL {
                        Link(destination: url) {
                            Label("Open on Steam", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
                previewArea
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 26, weight: .semibold))
                        .textSelection(.enabled)
                    if let author = item.author {
                        Text(author).font(.callout).foregroundStyle(.secondary)
                    }
                }
                chips
                tags
                Text(item.summary.isEmpty ? "No description." : item.summary)
                    .font(.callout)
                    .foregroundStyle(item.summary.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
                creatorStrip
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: item.id) { await preview.load(item.previewURL) }
        .task(id: item.id) { creatorItems = await workshop.moreFromCreator(of: item) }
    }

    // MARK: Preview

    @ViewBuilder private var previewArea: some View {
        previewImage
            .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
    }

    @ViewBuilder private var previewImage: some View {
        if let video = libraryItem {
            ItemPreviewPane(item: video, broken: !FileManager.default.fileExists(atPath: video.path),
                            openSteamSetup: openSteamSetup)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = preview.image {
                    AnimatedImageView(image: image)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if preview.failed || item.previewURL == nil {
                    Image(systemName: "photo").font(.system(size: 32)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
        }
    }

    /// The item's page on the Steam Community.
    private var steamCommunityURL: URL? {
        URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)")
    }

    // MARK: Facts

    private var chips: some View {
        WrappingRows {
            if item.kind != .unknown {
                if item.isImportable {
                    tagChip(item.kind.rawValue.capitalized, tint: Color.accentColor)
                } else {
                    WorkshopChip(text: item.kind.rawValue.capitalized, tint: Color.orange)
                }
            }
            if let resolution = item.resolutionTag { tagChip(resolution) }
            if let rating = item.ratingTag { tagChip(rating) }
            if item.sizeBytes > 0 {
                WorkshopChip(text: ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
            }
            if let subscriptions = item.subscriptions { WorkshopChip(text: "\(subscriptions.formatted()) subscribers") }
        }
    }

    // Tags that are not already shown as chips.
    private var otherTags: [String] {
        let shown = Set([item.resolutionTag, item.ratingTag, item.kind.rawValue].compactMap { $0?.lowercased() })
        return item.tags.filter { !shown.contains($0.lowercased()) }
    }

    @ViewBuilder private var tags: some View {
        if !otherTags.isEmpty {
            WrappingRows {
                ForEach(otherTags, id: \.self) { tagChip($0) }
            }
        }
    }

    /// A tag that filters the results when clicked.
    private func tagChip(_ text: String, tint: Color? = nil) -> some View {
        Button { narrowTo(text) } label: { WorkshopChip(text: text, tint: tint) }
            .buttonStyle(.plain)
            .help("Show only “\(text)”")
    }

    // MARK: More from the creator

    @ViewBuilder private var creatorStrip: some View {
        if !creatorItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("More from this creator").font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(creatorItems) { other in
                            Button { open(other) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    RemoteStill(url: other.previewURL, maxPixel: 320)
                                    .frame(width: 140, height: 79)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    Text(other.title).font(.caption).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(width: 140, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(other.title)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: Actions

    private var cardAction: WorkshopCardAction {
        WorkshopCardAction.make(item: item, state: workshop.downloads[item.id], inLibrary: libraryItem != nil)
    }

    @ViewBuilder private var actions: some View {
        if let video = libraryItem, case .inLibrary = cardAction {
            librarySection(video)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                WorkshopCardActions(item: item, action: cardAction, ready: workshop.setup.canDownload, compact: false,
                                    workshop: workshop, openSteamSetup: openSteamSetup, showInLibrary: showInLibrary)
                if case .download = cardAction, !workshop.setup.canDownload { setupHint }
            }
        }
    }

    private var setupHint: some View {
        HStack(spacing: 6) {
            Text(WorkshopCardActions.setupFirst).font(.caption).foregroundStyle(.orange)
            Button("Set up Steam…", action: openSteamSetup).buttonStyle(.link).font(.caption)
        }
    }

    private func librarySection(_ video: VideoItem) -> some View {
        WrappingRows {
            Button("Set as Desktop") { model.assign(video.id, to: [.desktop]) }
            Button("Set as Lock Screen") { model.assign(video.id, to: [.lock]) }
            Button("Set as Both") { model.assign(video.id, to: [.desktop, .lock]) }
            Button("Show in Library", action: showInLibrary)
        }
        .controlSize(.small)
    }

    private func showInLibrary() {
        if let video = libraryItem { model.focusedID = video.id }
        openLibrary()
    }
}
