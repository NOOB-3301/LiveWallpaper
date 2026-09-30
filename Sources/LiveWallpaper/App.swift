import SwiftUI
import AppKit

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Live Wallpaper", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 800, height: 560)
        .windowResizability(.contentMinSize) // the content's minimum frame is the window minimum

        MenuBarExtra("Live Wallpaper", systemImage: menuBarSymbol) {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarSymbol: String {
        guard model.isRunning else { return "play.rectangle" }
        return model.isPaused ? "pause.rectangle.fill" : "play.rectangle.fill"
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.bootstrap()
    }

    // The wallpaper keeps playing with the window closed; it is reopened from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(model.isRunning ? "Stop Wallpaper" : "Start Wallpaper") {
            model.toggleRunning()
        }
        .disabled(!model.isRunning && !model.canStart)

        Button(model.isPaused ? "Resume Wallpaper" : "Pause Wallpaper") {
            model.togglePause()
        }
        .disabled(!model.isRunning)

        Button("Next Video") {
            model.next()
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(!model.isRunning || !model.canRotate)

        Divider()

        Button("Quit Live Wallpaper") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
