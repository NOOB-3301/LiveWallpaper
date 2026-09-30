import SwiftUI
import AppKit
import Combine
import Core

// The Settings app: a normal Dock app with one window. It plays nothing; the wallpaper agent (nested helper
// app) does. Closing the window quits this app and the agent keeps running, except while a Workshop download
// is active. There is no menu bar extra here; the agent owns the status item.

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SettingsModel.shared
    @StateObject private var workshop = WorkshopModel.shared

    var body: some Scene {
        Window("Live Wallpaper", id: "main") {
            RootView(model: model, workshop: workshop)
                .frame(minWidth: 720, minHeight: 540)
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize) // the content's minimum frame is the window minimum
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
        // `$downloads` fires before the value changes; the hop reads the settled state.
        downloadWatch = WorkshopModel.shared.$downloads.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.quitWhenDownloadsEnd() }
        }
    }

    // Closing the window quits Settings; the wallpaper agent is a separate process and keeps playing.
    // While a Workshop download runs, Settings stays alive without a window and quits when the queue is empty.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lingering = WorkshopModel.shared.hasActiveDownloads
        return !lingering
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkshopModel.shared.cancelAll()
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

fileprivate enum AppTab: String, CaseIterable, Identifiable {
    case library = "Library"
    case workshop = "Workshop"
    case steamSetup = "Steam Setup"

    var id: String { rawValue }
}

/// Window content: segmented section bar with the agent pill, one optional banner, then the selected section
/// (SPEC2.md 5.1).
@MainActor
struct RootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    @State private var tab: AppTab = .library

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let banner { BannerBar(banner: banner) }
            section
        }
    }

    private var topBar: some View {
        ZStack {
            Picker("Section", selection: $tab) {
                ForEach(AppTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            HStack {
                Spacer()
                AgentPill(model: model)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
    }

    @ViewBuilder private var section: some View {
        switch tab {
        case .library:
            LibraryView(model: model, openWorkshop: { tab = .workshop })
        case .workshop:
            WorkshopView(model: model, workshop: workshop,
                         openSteamSetup: { tab = .steamSetup }, openLibrary: { tab = .library })
        case .steamSetup:
            SteamSetupView(workshop: workshop)
        }
    }

    /// One banner at a time, in priority order.
    private var banner: Banner? {
        if model.legacyAppRunning {
            return Banner(text: "An older copy of Live Wallpaper is still running. Quit it so the two don’t fight over your wallpaper.")
        }
        if model.agentStoppedUnexpectedly {
            return Banner(text: "The wallpaper agent stopped unexpectedly.",
                          action: (title: "Restart Agent", run: { model.restartAgent() }))
        }
        if model.agentIsOutdated {
            return Banner(text: "The wallpaper agent is from an older build. Restart it to finish updating.",
                          action: (title: "Restart Agent", run: { model.restartAgent() }))
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
        HStack(spacing: 8) {
            Image(systemName: banner.warning ? "exclamationmark.triangle.fill" : "info.circle").foregroundStyle(tint)
            Text(banner.text).font(.callout).lineLimit(2)
            Spacer(minLength: 8)
            if let action = banner.action { Button(action.title, action: action.run).buttonStyle(.link) }
            if let dismiss = banner.dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)))
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}

/// Dot + text in the top bar; the text opens a menu, which is where "Quit Agent" lives in Settings.
/// The dot sits outside the menu because menu labels are drawn by the system and may drop custom colours.
@MainActor
fileprivate struct AgentPill: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Menu {
                Button("Start Agent") { model.launchAgentIfNeeded() }.disabled(model.agentIsAlive)
                Button("Restart Agent") { model.restartAgent() }.disabled(!model.agentIsAlive)
                Button("Quit Agent") { model.quitAgent() }.disabled(!model.agentIsAlive)
            } label: {
                Text(text).font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var dot: Color {
        switch model.presence {
        case .running: return .green
        case .unresponsive: return .orange
        case .unknown, .notRunning, .launching: return .secondary
        }
    }

    private var text: String {
        switch model.presence {
        case .running: return "Agent running"
        case .launching: return "Agent starting…"
        case .unresponsive: return "Agent not responding"
        case .unknown, .notRunning: return "Agent not running"
        }
    }
}
