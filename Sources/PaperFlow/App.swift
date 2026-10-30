import SwiftUI
import AppKit
import Combine
import Core

// The Settings app: a normal Dock app with one window. It plays nothing; the wallpaper agent (nested helper
// app) does. Closing the window quits this app and the agent keeps running, except while a Workshop download
// is active. There is no menu bar extra here; the agent owns the status item.

@main
struct PaperFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SettingsModel.shared
    @StateObject private var workshop = WorkshopModel.shared

    var body: some Scene {
        Window("PaperFlow", id: "main") {
            RootView(model: model, workshop: workshop)
        }
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize) // the content's minimum frame is the window minimum
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: model) }

        Settings {
            PlaybackSettingsView(model: model)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var downloadWatch: AnyCancellable?
    private var lingering = false   // the last window closed while a download was still running

    func applicationDidFinishLaunching(_ notification: Notification) {
        if yieldToRunningSettings() { return }
        WorkshopModel.shared.connect(
            onImport: { SettingsModel.shared.addImported($0) },
            isInLibrary: { SettingsModel.shared.hasWorkshopItem($0) })
        SettingsModel.shared.bootstrap()
        Task { await UpdateChecker.check(interactive: false) }
        // `$downloads` fires before the value changes; the hop reads the settled state.
        downloadWatch = WorkshopModel.shared.$downloads.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.quitWhenDownloadsEnd() }
        }
    }

    // Closing the window quits Settings; the wallpaper service is a separate process and keeps playing.
    // While a Workshop download runs, Settings stays alive without a window and quits when the queue is empty.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lingering = WorkshopModel.shared.hasActiveDownloads
        return !lingering
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkshopModel.shared.cancelAll()
        SteamSetupModel.shared.cancelSignIn()   // never leave a steamcmd sign-in waiting on a prompt
        SteamSetupModel.shared.cancelInstall()
        SettingsModel.shared.shutdown()
    }

    /// A second copy hands over to the first (lowest process id wins, as with the agent) and quits.
    private func yieldToRunningSettings() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let peers = SettingsModel.otherInstances().filter { !$0.legacy }.map { $0.app }
        guard let first = peers.min(by: { $0.processIdentifier < $1.processIdentifier }),
              first.processIdentifier < me else { return false }
        first.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    private func quitWhenDownloadsEnd() {
        let hasWindow = NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled) }
        if lingering, !WorkshopModel.shared.hasActiveDownloads, !hasWindow { NSApp.terminate(nil) }
    }
}

// MARK: - Navigation

enum SidebarSelection: Hashable {
    case all, desktop, lockScreen, scenes, playlists, workshop, downloads, steamSetup

    var isLibrary: Bool {
        switch self {
        case .all, .desktop, .lockScreen, .scenes: return true
        default: return false
        }
    }

    var libraryFilter: LibraryFilter {
        switch self {
        case .desktop: return .desktop
        case .lockScreen: return .lock
        case .scenes: return .scenes
        default: return .all
        }
    }

    var title: String {
        switch self {
        case .all: return "All Wallpapers"
        case .desktop: return "Desktop"
        case .lockScreen: return "Lock Screen"
        case .scenes: return "Scenes"
        case .playlists: return "Playlists"
        case .workshop: return "Workshop"
        case .downloads: return "Downloads"
        case .steamSetup: return "Steam Setup"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "rectangle.on.rectangle"
        case .desktop: return "display"
        case .lockScreen: return "lock.display"
        case .scenes: return "sparkles.rectangle.stack"
        case .playlists: return "list.bullet.rectangle"
        case .workshop: return "square.grid.2x2"
        case .downloads: return "arrow.down.circle"
        case .steamSetup: return "key.horizontal"
        }
    }
}

/// Window content: native sidebar, gallery, inspector and a toolbar status pill.
@MainActor
struct RootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    @State private var selection: SidebarSelection = .all
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 208, ideal: LWTheme.sidebarWidth, max: 300)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 640)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let counts = assignmentCounts
        return List(selection: $selection) {
            Section("Library") {
                sidebarRow(.all, count: model.videos.count)
                sidebarRow(.desktop, count: counts.desktop)
                sidebarRow(.lockScreen, count: counts.lock)
                sidebarRow(.scenes, count: counts.scenes)
                sidebarRow(.playlists, count: nil)
            }
            Section("Discover") {
                sidebarRow(.workshop, count: workshop.results.isEmpty ? nil : workshop.results.count)
                sidebarRow(.downloads, count: workshop.downloadEntries.isEmpty ? nil : workshop.downloadEntries.count,
                           live: workshop.hasActiveDownloads)
                sidebarRow(.steamSetup, count: nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ServiceFooter(model: model)
                .padding(10)
        }
    }

    private func sidebarRow(_ item: SidebarSelection, count: Int?, live: Bool = false) -> some View {
        HStack(spacing: 0) {
            Label(item.title, systemImage: item.symbol)
                .font(.callout.weight(.medium))
            Spacer(minLength: 4)
            if live {
                ProgressRing(progress: workshop.overallDownloadProgress ?? 0,
                             size: 16, lineWidth: 2)
                    .opacity(workshop.overallDownloadProgress == nil ? 0.4 : 1)
            } else if let count, count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
        .padding(.vertical, 1)
        .tag(item)
    }

    /// All three library counts in one pass; the sidebar re-evaluates with the rest of the window.
    private var assignmentCounts: (desktop: Int, lock: Int, scenes: Int) {
        var desktop = 0
        var lock = 0
        var scenes = 0
        for item in model.videos {
            let targets = model.targets(of: item.id)
            if targets.contains(.desktop) { desktop += 1 }
            if targets.contains(.lock) { lock += 1 }
            if item.isScene { scenes += 1 }
        }
        return (desktop, lock, scenes)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            if let banner = banner {
                BannerBar(banner: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
                .transition(.opacity)
        }
        .background(LWBackground())
        .animation(LWMotion.content, value: selection)
        .animation(LWMotion.content, value: banner?.text)
        .toolbar {
            if selection.isLibrary {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(LWMotion.panel) { showInspector.toggle() }
                    } label: {
                        Image(systemName: showInspector ? "sidebar.right" : "sidebar.right")
                    }
                    .help(showInspector ? "Hide Inspector" : "Show Inspector")
                    .accessibilityLabel(showInspector ? "Hide Inspector" : "Show Inspector")
                    .keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if workshop.hasActiveDownloads {
                    Button {
                        selection = .downloads
                    } label: {
                        HStack(spacing: 6) {
                            ProgressRing(progress: workshop.overallDownloadProgress ?? 0,
                                         size: 16, lineWidth: 2)
                                .opacity(workshop.overallDownloadProgress == nil ? 0.4 : 1)
                            Text("\(workshop.activeDownloadCount)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            Capsule()
                                .fill(.regularMaterial)
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Downloads in progress")
                    .accessibilityLabel("Downloads in progress")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ServiceStatusPill(model: model)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .all, .desktop, .lockScreen, .scenes:
            LibraryView(model: model,
                        filter: selection.libraryFilter,
                        showInspector: $showInspector,
                        openWorkshop: { selection = .workshop },
                        openSteamSetup: { selection = .steamSetup })
                .lwInspector(isPresented: $showInspector) {
                    LibraryInspectorView(model: model,
                                         item: focusedLibraryItem,
                                         openSteamSetup: { selection = .steamSetup },
                                         remove: removeFocused)
                }
        case .playlists:
            PlaylistView(model: model)
        case .workshop:
            WorkshopView(model: model, workshop: workshop,
                         openSteamSetup: { selection = .steamSetup },
                         openLibrary: { selection = .all },
                         openDownloads: { selection = .downloads })
        case .downloads:
            DownloadsView(model: model, workshop: workshop,
                          openLibrary: { selection = .all },
                          openWorkshop: { selection = .workshop })
        case .steamSetup:
            SteamSetupView(workshop: workshop, setup: SteamSetupModel.shared)
        }
    }

    private var focusedLibraryItem: VideoItem? {
        let filter = selection.libraryFilter
        let visible = model.videos.filter { filter.includes($0, targets: model.targets(of: $0.id)) }
        return visible.first { $0.id == model.focusedID } ?? visible.first
    }

    private func removeFocused() {
        guard let id = focusedLibraryItem?.id else { return }
        model.remove(ids: [id])
    }

    /// One banner at a time, in priority order.
    private var banner: Banner? {
        if model.legacyAppRunning {
            return Banner(text: "An older copy of this app is still running. Quit it so the two don’t fight over your wallpaper.")
        }
        if model.importedFromPhase1 > 0 {
            let count = model.importedFromPhase1
            return Banner(text: "Imported \(count) \(count == 1 ? "video" : "videos") from the previous version.",
                          warning: false, dismiss: { model.dismissImportNotice() })
        }
        return nil
    }
}

fileprivate struct Banner {
    let text: String
    var warning = true
    var action: (title: String, run: () -> Void)? = nil
    var dismiss: (() -> Void)? = nil
}

@MainActor
fileprivate struct BannerBar: View {
    let banner: Banner

    private var tint: Color { banner.warning ? .orange : .accentColor }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(tint)
            Text(banner.text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let action = banner.action {
                Button(action.title, action: action.run).buttonStyle(.link)
            }
            if let dismiss = banner.dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.25), lineWidth: 1)
                }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }
}

// MARK: - Service status

@MainActor
private struct ServiceFooter: View {
    @ObservedObject var model: SettingsModel
    @State private var showingMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                StatusDot(color: dot, pulsing: model.client.state == .connecting)
                Text(shortText)
                    .font(.caption)
                    .foregroundStyle(model.client.state == .connected ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Connect to Service") { model.startService() }
                        .disabled(model.client.state == .connected)
                    Button("Restart Service") { model.restartService() }
                        .disabled(model.client.state != .connected)
                    Button("Quit Service") { model.quitService() }
                        .disabled(model.client.state != .connected)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Service options")
                .accessibilityLabel("Service options")
            }
            HStack(spacing: 6) {
                Button(model.isRunning ? "Stop" : "Start") {
                    model.clearStatus()
                    if model.isRunning { model.stop() } else { model.start() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.isRunning && !model.canStart)
            }
        }
        .padding(10)
        .background { glassShape(radius: 12) }
    }

    private var dot: Color {
        switch model.client.state {
        case .connected: return model.isRunning ? .green : .secondary
        case .connecting: return .orange
        case .needsApproval, .unavailable: return .orange
        case .unknown: return .secondary
        }
    }

    private var shortText: String {
        switch model.client.state {
        case .connected: return model.isRunning ? "Wallpaper service · running" : "Wallpaper service · ready"
        case .connecting: return "Starting service…"
        case .needsApproval: return "Service needs approval"
        case .unavailable: return "Service not responding"
        case .unknown: return "Service not running"
        }
    }
}

@MainActor
struct ServiceStatusPill: View {
    @ObservedObject var model: SettingsModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                StatusDot(color: dot, pulsing: model.client.state == .connecting)
                Text(pillText)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .help("Wallpaper service status and controls")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ServicePopover(model: model)
                .frame(width: 320)
        }
    }

    private var dot: Color {
        switch model.client.state {
        case .connected: return model.isRunning ? .green : .secondary
        case .connecting: return .orange
        case .needsApproval, .unavailable: return .orange
        case .unknown: return .secondary
        }
    }

    private var pillText: String {
        if model.client.state == .connecting { return "Starting…" }
        if model.client.state == .unavailable { return "Service offline" }
        if model.client.state == .needsApproval { return "Needs approval" }
        if model.isRunning { return model.isPaused ? "Paused" : "Live" }
        return "Ready"
    }
}

@MainActor
private struct ServicePopover: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Wallpaper Service").font(.headline)
                Spacer()
                StatusDot(color: model.client.state == .connected ? .green : .orange)
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                targetRow(.desktop)
                Divider()
                targetRow(.lock)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }

            HStack(spacing: 8) {
                Button(model.isRunning ? "Stop Wallpaper" : "Start Wallpaper") {
                    model.clearStatus()
                    model.isRunning ? model.stop() : model.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isRunning && !model.canStart)

                Toggle("Mute", isOn: $model.muted)
                    .toggleStyle(.checkbox)
                Spacer()
            }

            if let message = model.statusMessage, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }

            HStack(spacing: 10) {
                if model.client.state == .unavailable {
                    Button("Reconnect") { model.startService() }.buttonStyle(.link)
                }
                Button("Restart") { model.restartService() }
                    .buttonStyle(.link)
                    .disabled(model.client.state != .connected)
                Button("Quit") { model.quitService() }
                    .buttonStyle(.link)
                    .disabled(model.client.state != .connected)
            }
            .font(.caption)
        }
        .padding(16)
    }

    private var stateText: String {
        switch model.client.state {
        case .connected: return model.isRunning ? "running" : "ready"
        case .connecting: return "starting"
        case .needsApproval: return "needs approval"
        case .unavailable: return "offline"
        case .unknown: return "not running"
        }
    }

    private func targetRow(_ target: WallpaperTarget) -> some View {
        let id = model.currentID(for: target)
        let item = model.videos.first { $0.id == id }
        return HStack(spacing: 9) {
            Image(systemName: target == .desktop ? "display" : "lock.display")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.label).font(.caption).foregroundStyle(.secondary)
                Text(item?.name ?? "Off")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            ActivityBars(playing: id != nil && model.isRunning, paused: model.isPaused)
        }
    }
}
