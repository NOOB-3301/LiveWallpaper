import Foundation
import AppKit
import Core
import SceneFormat

// Owner: IMPORT. Brings wallpapers the user already has on disk into the library. Videos are added by
// reference like `SettingsModel.addVideos`; Wallpaper Engine scene packages (.pkg) and scene folders are
// copied into Library/<local-id>/ through the same SceneImporter the Workshop uses. Every addition goes
// through SettingsModel, so each import ends as a `.commit` — the service is the one that writes
// state.json, keeping the state-ownership rule of ARCHITECTURE.md intact.

@MainActor
enum WallpaperImporter {

    struct Outcome: Equatable {
        var addedVideos: Int = 0
        var addedScenes: Int = 0
        var failed: [String] = []      // file names with the reason they could not be imported
        var skipped: Int = 0           // neither a video nor a scene

        var addedAnything: Bool { addedVideos > 0 || addedScenes > 0 }
    }

    /// What a dropped or chosen URL is, by looking at it (extension first, then folder contents).
    enum Source: Equatable {
        case video
        case scenePackage(URL)         // a Wallpaper Engine scene.pkg (or any *.pkg with scene.json inside)
        case sceneFolder(URL)          // a folder containing scene.json (loose scene)
        case other
    }

    static func classify(_ url: URL) -> Source {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .other }
        if isDirectory.boolValue {
            let sceneJSON = url.appendingPathComponent("scene.json")
            if FileManager.default.fileExists(atPath: sceneJSON.path) { return .sceneFolder(url) }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if names.contains("project.json"), names.contains(where: { $0.lowercased().hasSuffix(".pkg") }) {
                return .sceneFolder(url)
            }
            return .other
        }
        if VideoItem.isVideo(url) { return .video }
        if url.pathExtension.lowercased() == "pkg" { return .scenePackage(url) }
        return .other
    }

    /// Imports everything it recognises; never throws — per-file failures land in `outcome.failed`.
    static func importURLs(_ urls: [URL], into model: SettingsModel) async -> Outcome {
        var outcome = Outcome()
        var videoURLs: [URL] = []

        for url in urls {
            switch classify(url) {
            case .video:
                videoURLs.append(url)
            case .scenePackage(let package):
                await importScenePackage(package, into: model, outcome: &outcome)
            case .sceneFolder(let folder):
                await importSceneFolder(folder, into: model, outcome: &outcome)
            case .other:
                outcome.skipped += 1
            }
        }

        outcome.addedVideos = model.addVideos(urls: videoURLs)
        return outcome
    }

    /// A bare .pkg has no folder around it, so a content folder is staged next to the other imports.
    private static func importScenePackage(_ package: URL, into model: SettingsModel,
                                           outcome: inout Outcome) async {
        do {
            try AppPaths.ensureDirectory(AppPaths.libraryDirectory)
            let staging = AppPaths.libraryDirectory.appendingPathComponent(
                "import-\(UUID().uuidString.prefix(8)).partial", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try AppPaths.ensureDirectory(staging)
            try FileManager.default.copyItem(at: package, to: staging.appendingPathComponent("scene.pkg"))
            try await importScene(contentFolder: staging,
                                  title: package.deletingPathExtension().lastPathComponent, into: model)
            outcome.addedScenes += 1
        } catch {
            outcome.failed.append("\(package.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func importSceneFolder(_ folder: URL, into model: SettingsModel,
                                          outcome: inout Outcome) async {
        do {
            try await importScene(contentFolder: folder, title: folder.lastPathComponent, into: model)
            outcome.addedScenes += 1
        } catch {
            outcome.failed.append("\(folder.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Runs the shared scene import (copy + analysis) and adds the item to the library. Local imports get
    /// no workshop id, so they read as the user's own wallpapers rather than Workshop items.
    private static func importScene(contentFolder: URL, title: String, into model: SettingsModel) async throws {
        let preview = ["jpg", "jpeg", "png", "gif"]
            .compactMap { ext -> URL? in
                let url = contentFolder.appendingPathComponent("preview.\(ext)")
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            .first
        var item = try await SceneImporter.importScene(SceneImportInput(
            workshopID: "local-\(UUID().uuidString.prefix(8))",
            title: title, author: nil, tags: [],
            contentFolder: contentFolder, previewSource: preview))
        item.workshopID = nil
        model.addImported(item)
    }

    /// The open panel for "Import Wallpapers…": videos, scene packages and scene folders at once.
    @MainActor
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
