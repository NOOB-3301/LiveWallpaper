import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isTargeted = false
    @State private var intervalText: String
    @State private var skippedCount = 0
    @State private var showSkipped = false
    @FocusState private var intervalFocused: Bool

    init(model: AppModel) {
        self._model = ObservedObject(wrappedValue: model)
        self._intervalText = State(initialValue: String(model.intervalValue))
    }

    var body: some View {
        Group {
            if model.videos.isEmpty { emptyState } else { HStack(spacing: 0) { sidebar; Divider(); detail } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { isTargeted = $0 }
        .alert(skippedTitle, isPresented: $showSkipped) { Button("OK", role: .cancel) {} }
        .onChange(of: model.selectedID) { id in
            if model.isRunning, !model.rotateEnabled, let id, id != model.currentID { model.play(id) }
        }
        .onChange(of: model.intervalValue) { intervalText = String($0) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 56))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text(isTargeted ? "Release to add" : "Drop videos here").font(.title2.weight(.semibold))
            Text("or choose files from your Mac. MP4, MOV and M4V work best.").font(.callout).foregroundStyle(.secondary)
            Button("Choose Videos…", action: chooseVideos).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary))
        .background(Color.accentColor.opacity(isTargeted ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
            isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
            style: StrokeStyle(lineWidth: isTargeted ? 3 : 2, dash: isTargeted ? [] : [8, 6])))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: chooseVideos)
        .padding(32)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(model.videos, selection: $model.selectedID) { item in
                VideoRow(item: item, broken: isBroken(item), isCurrent: item.id == model.currentID, isPaused: model.isPaused)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onDeleteCommand(perform: removeSelected)
            .contextMenu(forSelectionType: VideoItem.ID.self) { ids in
                if !ids.isEmpty { Button("Remove") { remove(ids) } }
            } primaryAction: { ids in
                if let id = ids.first { model.play(id) }
            }
            Divider()
            footer
        }
        .frame(width: 264)
        .background(.regularMaterial)
    }

    private var footer: some View {
        HStack {
            Button(action: chooseVideos) { Label("Add Videos…", systemImage: "plus") }
                .keyboardShortcut("o").help("Add videos (⌘O)")
            Button(action: removeSelected) { Image(systemName: "minus") }
                .keyboardShortcut(.delete, modifiers: .command).disabled(model.selectedItem == nil)
                .help("Remove selected video (⌘⌫)").accessibilityLabel("Remove selected video")
            Spacer()
            Text(model.videos.count == 1 ? "1 video" : "\(model.videos.count) videos").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var detail: some View {
        VStack(spacing: 16) {
            PreviewPane(item: model.selectedItem, broken: model.selectedItem.map { isBroken($0) } ?? false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            settingsCard
            actionBar
        }
        .padding(24)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rotate wallpaper")
                Spacer()
                Toggle("Rotate wallpaper", isOn: rotateBinding).labelsHidden().toggleStyle(.switch)
            }
            .disabled(!model.canRotate)
            .help("Automatically switch between your videos, in list order.")
            if model.rotateEnabled && model.canRotate { intervalRow }
            if let helper {
                Text(helper.text).font(.caption).foregroundStyle(helper.warning ? Color.orange : Color.secondary)
            }
            Divider().padding(.vertical, 4)
            HStack(spacing: 16) {
                Text("Apply to")
                Toggle("Desktop", isOn: $model.applyToDesktop)
                Toggle("Lock Screen", isOn: $model.applyToLockScreen)
                    .help("On macOS 26 and later the Lock Screen plays your video by taking the place of a downloaded Apple Aerial wallpaper. Older versions show a still frame of the current video.")
            }
            .toggleStyle(.checkbox)
            Label("Lock Screen plays your video through an Apple Aerial wallpaper (macOS 26+; older versions get a still frame). Download and select any Aerial in Wallpaper settings once.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            Link("Open Wallpaper Settings", destination: URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
        .animation(.default, value: model.rotateEnabled && model.canRotate)
    }

    private var intervalRow: some View {
        HStack(spacing: 8) {
            Text("Change every")
            TextField("", text: $intervalText)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 56)
                .focused($intervalFocused)
                .onSubmit(commitInterval)
                .onChange(of: intervalFocused) { if !$0 { commitInterval() } }
                .accessibilityLabel("Interval value")
            Picker("Interval unit", selection: $model.intervalUnit) {
                ForEach(IntervalUnit.allCases) { Text($0.label.lowercased()).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 104)
        }
        .help("How long each video plays before the next one. Minimum 5 seconds.")
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Text(status.text).font(.subheadline).foregroundStyle(status.warning ? Color.orange : Color.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                model.clearStatus()
                model.toggleRunning()
            } label: {
                Label(model.isRunning ? "Stop Wallpaper" : "Start Wallpaper", systemImage: model.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(model.isRunning ? Color.red : nil)
            .frame(width: 168)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.isRunning && !model.canStart)
        }
    }

    private var rotateBinding: Binding<Bool> {
        Binding(get: { model.rotateEnabled && model.canRotate }, set: { model.rotateEnabled = $0 })
    }

    private var enteredValue: Int? { Int(intervalText).flatMap { $0 > 0 ? min($0, 999) : nil } }

    private var helper: (text: String, warning: Bool)? {
        guard model.canRotate else { return ("Add at least two videos to rotate.", false) }
        guard model.rotateEnabled else { return nil }
        if enteredValue == nil { return ("Enter a number from 1 to 999.", true) }
        if model.intervalIsClamped { return ("Minimum is 5 seconds.", true) }
        return ("Cycles through \(model.videos.count) videos in list order.", false)
    }

    private var status: (text: String, warning: Bool) {
        if let message = model.statusMessage { return (message, true) }
        if model.isRunning {
            let name = model.videos.first { $0.id == model.currentID }?.name ?? ""
            return (model.isPaused ? "Paused · \(name)" : "Playing \(name)", false)
        }
        if !model.canStart { return ("Turn on Desktop or Lock Screen to start.", true) }
        if model.videos.allSatisfy({ isBroken($0) }) { return ("None of your videos can be played.", true) }
        return ("Stopped", false)
    }

    private var skippedTitle: String {
        skippedCount == 1 ? "Skipped 1 file that isn’t a video." : "Skipped \(skippedCount) files that aren’t videos."
    }

    private func isBroken(_ item: VideoItem) -> Bool {
        model.failedIDs.contains(item.id) || !FileManager.default.fileExists(atPath: item.path)
    }

    private func commitInterval() {
        if let value = enteredValue { model.intervalValue = value }
        intervalText = String(model.intervalValue)
    }

    private func add(_ urls: [URL]) {
        skippedCount = urls.filter { !VideoItem.isVideo($0) }.count
        showSkipped = skippedCount > 0
        model.addVideos(urls: urls)
    }

    private func chooseVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie]
        panel.message = "Choose videos to use as your wallpaper."
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func removeSelected() { if let id = model.selectedID { remove([id]) } }

    private func remove(_ ids: Set<VideoItem.ID>) {
        let index = model.videos.firstIndex { ids.contains($0.id) } ?? 0
        model.remove(ids: ids)
        if model.selectedItem == nil, !model.videos.isEmpty { model.selectedID = model.videos[min(index, model.videos.count - 1)].id }
    }
}

fileprivate let thumbnailCache = NSCache<NSString, NSImage>()

fileprivate struct VideoRow: View {
    let item: VideoItem
    let broken: Bool
    let isCurrent: Bool
    let isPaused: Bool
    @State private var image: NSImage?
    @State private var meta = ""

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle).opacity(broken ? 0.6 : 1)
                if broken {
                    Text("Missing or unreadable").font(.caption).foregroundStyle(.orange)
                } else {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isCurrent { Image(systemName: isPaused ? "pause.fill" : "play.fill").foregroundStyle(.tint).opacity(isPaused ? 0.5 : 1) }
        }
        .frame(height: 52)
        .help(broken ? "This file was moved, deleted, or can’t be played. Remove it or add it again." : "")
        .task(id: item.path) {
            let bytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            meta = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            image = await Self.loadThumbnail(for: item.url)
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if broken {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private static func loadThumbnail(for url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let cgImage = await VideoStills.cgImage(for: url, maxPixelSize: CGSize(width: 320, height: 180)) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        thumbnailCache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
fileprivate final class PreviewPlayer: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var url: URL?
    private var isActive = true

    func load(_ url: URL?) {
        guard url != self.url else { return }
        self.url = url
        player?.pause()
        looper = nil
        player = nil
        guard let url else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        setActive(isActive)
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { player?.play() } else { player?.pause() }
    }
}

fileprivate struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

@MainActor
fileprivate struct PreviewPane: View {
    let item: VideoItem?
    let broken: Bool
    @StateObject private var preview = PreviewPlayer()

    private var playbackURL: URL? { broken ? nil : item?.url }

    var body: some View {
        ZStack {
            Color.black
            if broken {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(.orange)
                    Text("Can’t play this video").font(.headline)
                    Text("The file may have been moved or deleted.").font(.callout).foregroundStyle(.secondary)
                }
                .environment(\.colorScheme, .dark)
            } else if let item {
                PlayerSurface(player: preview.player).accessibilityLabel("Video preview of \(item.name), muted, looping")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: playbackURL) { preview.load(playbackURL) }
        .onAppear { preview.setActive(true) }
        .onDisappear { preview.setActive(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let window = note.object as? NSWindow, window.styleMask.contains(.titled) {
                preview.setActive(window.occlusionState.contains(.visible))
            }
        }
    }
}
