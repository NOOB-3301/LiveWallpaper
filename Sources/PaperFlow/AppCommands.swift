import SwiftUI
import AppKit
import Core

@MainActor
enum VideoPicker {
    static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie]
        panel.message = "Choose videos to use as your wallpaper."
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Import panel for videos, Wallpaper Engine scene packages and scene folders in one go.
@MainActor
enum WallpaperPicker {
    static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose videos, Wallpaper Engine scene packages (.pkg) or scene folders."
        panel.prompt = "Import"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

@MainActor
enum ImportCenter {
    /// Opens the import panel and brings whatever it recognises into the library.
    static func importWallpapers(model: SettingsModel) async -> WallpaperImporter.Outcome {
        let urls = WallpaperPicker.choose()
        guard !urls.isEmpty else { return WallpaperImporter.Outcome() }
        return await WallpaperImporter.importURLs(urls, into: model)
    }
}

@MainActor
struct AppCommands: Commands {
    let model: SettingsModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Wallpapers…") {
                Task { @MainActor in _ = await ImportCenter.importWallpapers(model: model) }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Add Videos…") {
                let urls = VideoPicker.choose()
                if !urls.isEmpty { model.addVideos(urls: urls) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Wallpaper") {
            Button(model.isRunning ? "Stop Wallpaper" : "Start Wallpaper") {
                model.clearStatus()
                if model.isRunning { model.stop() } else { model.start() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.isRunning && !model.canStart)

            Divider()

            if let id = model.focusedID ?? model.selectedID {
                Button("Set as Desktop") { model.assign(id, to: [.desktop]) }
                    .keyboardShortcut("d", modifiers: [.option, .command])
                Button("Set as Lock Screen") { model.assign(id, to: [.lock]) }
                    .keyboardShortcut("l", modifiers: [.option, .command])
                Button("Set as Both") { model.assign(id, to: [.desktop, .lock]) }
                    .keyboardShortcut("b", modifiers: [.option, .command])
            } else {
                Button("Select a wallpaper first") {}
                    .disabled(true)
            }
        }
    }
}
