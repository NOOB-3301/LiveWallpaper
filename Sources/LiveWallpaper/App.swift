import SwiftUI
import AppKit
import Core

// SCAFFOLD (owner: SETTINGS). The Settings app: a normal Dock app with one window. It plays nothing; the
// wallpaper agent (nested helper app) does. Closing the window quits this app, the agent keeps running.
// There is no menu bar extra here; the agent owns the status item.

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // TODO(SETTINGS): single-instance guard first (another running NSRunningApplication with
        // IPC.settingsBundleID whose Info.plist has LWRole == "settings": activate it and terminate this one).
        WorkshopModel.shared.connect(
            onImport: { SettingsModel.shared.addImported($0) },
            isInLibrary: { SettingsModel.shared.hasWorkshopItem($0) })
        SettingsModel.shared.bootstrap()
    }

    // Closing the window quits Settings; the wallpaper agent is a separate process and keeps playing.
    // While a Workshop download runs, Settings stays alive without a window.
    // TODO(SETTINGS): terminate by itself once hasActiveDownloads turns false and no window is open; confirm
    // in applicationShouldTerminate (Cmd-Q) when a download is active.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !WorkshopModel.shared.hasActiveDownloads
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkshopModel.shared.cancelAll()
        SettingsModel.shared.shutdown()
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case library = "Library"
    case workshop = "Workshop"
    case steamSetup = "Steam Setup"

    var id: String { rawValue }
}

/// Window content: segmented section bar, optional banner, then the selected section (SPEC2.md 5.1).
@MainActor
struct RootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    @State private var tab: AppTab = .library

    var body: some View {
        VStack(spacing: 0) {
            // TODO(SETTINGS): agent status pill on the trailing side, banners (legacy app running,
            // "Imported N videos from the previous version").
            Picker("Section", selection: $tab) {
                ForEach(AppTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.vertical, 10)
            Divider()
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
    }
}
