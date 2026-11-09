import SwiftUI
import AVKit
import AppKit
import Core

// Full-screen wallpaper preview: a borderless window over the screen the app is on. A video loops with its sound
// (muted until asked); a scene shows its preview image, because scenes are rendered by the background service and
// the Settings app does not link the renderer. Esc or Space closes it; the controls hide while the mouse rests.
//
// The covered app window is fully occluded, so its own preview players release their decoders (ItemPreviewPane
// watches the window's occlusion state): only this window decodes while it is open.

@MainActor
final class WallpaperPreviewController {
    static let shared = WallpaperPreviewController()

    private var window: PreviewWindow?

    var isShowing: Bool { window != nil }

    func show(_ item: VideoItem, model: SettingsModel) {
        guard window == nil else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let window = PreviewWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
                                   defer: false, screen: screen)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.onClose = { [weak self] in self?.close() }
        window.contentView = NSHostingView(rootView: WallpaperPreviewView(item: item, model: model) { [weak self] in
            self?.close()
        })
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.orderOut(nil)
        window.contentView = nil      // drops the hosting view, which stops and releases the player
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

/// A borderless window can't become key by default, and it needs to, to see Esc and Space.
private final class PreviewWindow: NSWindow {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: onClose?()     // Space, Esc
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

/// One looping, full-size player for the preview window.
@MainActor
private final class FullPreviewPlayer: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    func start(_ url: URL, muted: Bool) {
        guard player == nil else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = muted
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        queue.play()
    }

    func setMuted(_ muted: Bool) { player?.isMuted = muted }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
    }
}

private struct FullPlayerSurface: NSViewRepresentable {
    let player: AVPlayer?
    let fill: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        view.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

@MainActor
private struct WallpaperPreviewView: View {
    let item: VideoItem
    @ObservedObject var model: SettingsModel
    let close: () -> Void

    @StateObject private var player = FullPreviewPlayer()
    @State private var sceneImage: NSImage?
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var fill = false
    @State private var muted: Bool

    init(item: VideoItem, model: SettingsModel, close: @escaping () -> Void) {
        self.item = item
        self._model = ObservedObject(wrappedValue: model)
        self.close = close
        self._muted = State(initialValue: model.muted)
    }

    var body: some View {
        ZStack {
            Color.black
            media
            if showControls {
                controls.transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .task {
            if item.isScene {
                guard let path = item.previewPath else { return }
                let decoded = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: path) }.value
                if !Task.isCancelled { sceneImage = decoded }
            } else {
                player.start(item.url, muted: muted)
            }
            revealControls()
        }
        .onDisappear {
            hideTask?.cancel()
            player.stop()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of \(item.name)")
    }

    // MARK: Media

    @ViewBuilder private var media: some View {
        if item.isScene {
            if let sceneImage {
                AnimatedImageView(image: sceneImage)
            } else {
                Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.4))
            }
        } else {
            FullPlayerSurface(player: player.player, fill: fill)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(kindLine).font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Button(action: close) {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Close the preview (Esc)")
            }
            Spacer()
            VStack(spacing: 10) {
                if item.isScene {
                    Text("This is the scene’s preview image. Scenes are drawn live on your desktop.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                bar
            }
        }
        .padding(28)
        .foregroundStyle(.white)
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
            }
            .allowsHitTesting(false)
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            if !item.isScene {
                barButton(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", muted ? "Sound off" : "Sound on") {
                    muted.toggle()
                    player.setMuted(muted)
                }
                barButton(fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          fill ? "Fit" : "Fill") { fill.toggle() }
            }
            Menu {
                setAsEntry("Desktop", [.desktop])
                setAsEntry("Lock Screen", [.lock])
                setAsEntry("Both", [.desktop, .lock])
            } label: {
                Label("Set as", systemImage: "rectangle.on.rectangle.angled")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                model.clearStatus()
                model.startOnly(item.id)
                close()
            } label: {
                Label("Play on desktop", systemImage: "play.fill")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Start this wallpaper on the desktop and close the preview")
        }
        .font(.callout.weight(.medium))
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func setAsEntry(_ title: String, _ targets: Set<WallpaperTarget>) -> some View {
        Button { model.assign(item.id, to: targets) } label: {
            if model.roles(of: item.id) == targets { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var kindLine: String {
        var parts = [item.isScene ? "Scene" : "Video"]
        if item.isWorkshop { parts.append("Workshop") }
        if let author = item.author, !author.isEmpty { parts.append("by \(author)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Auto-hide

    private func revealControls() {
        hideTask?.cancel()
        NSCursor.setHiddenUntilMouseMoves(false)
        withAnimation(.easeOut(duration: 0.15)) { showControls = true }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { showControls = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
