import SwiftUI
import AppKit
import Core

// The Downloads page: every Workshop download the app has tracked, split into what is running now and
// what has settled. The entries come from WorkshopModel.downloadEntries, which keeps the item info even
// after the results grid has moved on, so progress survives navigation and window resizing.

@MainActor
struct DownloadsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let openLibrary: () -> Void
    let openWorkshop: () -> Void

    private var entries: [WorkshopDownloadEntry] { workshop.downloadEntries }
    private var active: [WorkshopDownloadEntry] { entries.filter(\.phase.isActive) }
    private var settled: [WorkshopDownloadEntry] { entries.filter { !$0.phase.isActive } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LWTheme.sectionSpacing) {
                header
                if entries.isEmpty {
                    emptyState
                } else {
                    if !active.isEmpty { activeSection }
                    if !settled.isEmpty { settledSection }
                }
            }
            .padding(LWTheme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .background(LWBackground())
        .animation(LWMotion.content, value: entries.map(\.id))
    }

    // MARK: Header

    private var header: some View {
        LWPageHeader(
            title: "Downloads",
            subtitle: headerSubtitle,
            trailing: {
                if !settled.filter(\.phase.isDone).isEmpty {
                    Button("Clear Finished") {
                        for entry in settled where entry.phase.isDone { workshop.dismissDownload(entry.id) }
                    }
                    .controlSize(.small)
                }
            })
    }

    private var headerSubtitle: String {
        switch active.count {
        case 0: return "Workshop downloads appear here while they run."
        case 1: return "One wallpaper downloading · the rest of the app stays free to use."
        default: return "\(active.count) wallpapers queued · they download one at a time."
        }
    }

    private var emptyState: some View {
        LWEmptyState(
            icon: "arrow.down.circle",
            title: "Nothing downloading",
            message: "Wallpapers you download from the Workshop appear here with their progress.",
            actionTitle: "Browse the Workshop",
            action: openWorkshop)
    }

    // MARK: Sections

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("In progress", count: active.count)
            VStack(spacing: 10) {
                ForEach(active) { entry in
                    DownloadRow(entry: entry, queuePosition: workshop.queuePosition(of: entry.id),
                                workshop: workshop, model: model, openLibrary: openLibrary)
                }
            }
        }
    }

    private var settledSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Finished", count: settled.count)
            VStack(spacing: 10) {
                ForEach(settled) { entry in
                    DownloadRow(entry: entry, queuePosition: nil,
                                workshop: workshop, model: model, openLibrary: openLibrary)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

private extension WorkshopDownloadPhase {
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

// MARK: - Row

@MainActor
private struct DownloadRow: View {
    let entry: WorkshopDownloadEntry
    let queuePosition: Int?
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject var model: SettingsModel
    let openLibrary: () -> Void
    @State private var hovering = false

    private var item: WorkshopItem { entry.item }
    private var phase: WorkshopDownloadPhase { entry.phase }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
                if phase.isActive { progressBar }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(14)
        .background { glassShape(radius: LWTheme.cardRadius) }
        .overlay {
            RoundedRectangle(cornerRadius: LWTheme.cardRadius, style: .continuous)
                .strokeBorder(hovering ? Color.primary.opacity(0.10) : .clear, lineWidth: 1)
        }
        .animation(LWMotion.hover, value: hovering)
        .onHover { hovering = $0 }
    }

    // MARK: Pieces

    private var thumbnail: some View {
        AsyncImage(url: item.previewURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.05))
                    Image(systemName: item.kind == .scene ? "sparkles" : "film")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 112, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var phaseText: String {
        switch phase {
        case .queued(let position):
            return position > 1 ? "Waiting · \(ordinal(position)) in queue" : "Waiting…"
        case .signingIn: return "Signing in to Steam…"
        case .downloading(let progress):
            guard let progress else { return "Downloading…" }
            return "Downloading · \(Int((min(max(progress, 0), 1) * 100).rounded()))%"
        case .importing: return "Adding to your library…"
        case .done: return "Added to your library"
        case .failed(let error): return error.title
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(phaseText)
                .font(.caption)
                .foregroundStyle(isFailed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.secondary))
            if item.sizeBytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let kind = kindChip { kindChipView(kind) }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var statusIcon: some View {
        switch phase {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.tertiary).font(.caption)
        case .signingIn, .downloading, .importing:
            StatusDot(color: .accentColor, pulsing: true)
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var kindChip: (text: String, tint: Color)? {
        guard item.kind != .unknown else { return nil }
        return (item.kind.rawValue.capitalized, item.isImportable ? Color.accentColor : Color.orange)
    }

    @ViewBuilder private func kindChipView(_ chip: (text: String, tint: Color)) -> some View {
        LWChip(text: chip.text, tint: chip.tint)
    }

    @ViewBuilder private var progressBar: some View {
        if case .downloading(let progress) = phase {
            LWProgressBar(progress: progress)
        } else {
            LWProgressBar(progress: nil)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch phase {
        case .queued:
            cancelButton("Remove from queue")
        case .signingIn, .downloading:
            cancelButton("Cancel download")
        case .importing:
            // The copy into the library is short and not interruptible.
            ProgressView().controlSize(.small)
        case .done:
            HStack(spacing: 8) {
                Button("Show in Library", action: showInLibrary)
                    .controlSize(.small)
                Button {
                    workshop.dismissDownload(entry.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear from the list")
                .opacity(hovering ? 1 : 0.45)
            }
        case .failed:
            HStack(spacing: 8) {
                Button("Retry") { workshop.download(item) }
                    .controlSize(.small)
                    .disabled(!item.isImportable)
                Button {
                    workshop.dismissDownload(entry.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear from the list")
                .opacity(hovering ? 1 : 0.45)
            }
        }
    }

    private func cancelButton(_ help: String) -> some View {
        Button {
            workshop.cancelDownload(entry.id)
        } label: {
            Image(systemName: "xmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func showInLibrary() {
        if let video = model.videos.first(where: { $0.workshopID == item.id }) { model.focusedID = video.id }
        openLibrary()
    }

    private func ordinal(_ value: Int) -> String {
        switch value % 10 {
        case 1 where value % 100 != 11: return "\(value)st"
        case 2 where value % 100 != 12: return "\(value)nd"
        case 3 where value % 100 != 13: return "\(value)rd"
        default: return "\(value)th"
        }
    }
}
