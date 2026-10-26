import Foundation
import Core
import SceneFormat

// Owner: STEAM. Imports a downloaded scene-type Workshop item into the library (SPEC3.md section 4.7): copies
// scene.pkg (or the loose scene files), project.json and the preview into Library/<id>/, runs the SceneFormat
// analyzer for the support badge and builds the VideoItem. Called by the import step of Workshop.swift when
// project.json says type "scene". The video import path is unchanged. Foundation + Core + SceneFormat only.

struct SceneImportInput {
    var workshopID: String
    var title: String
    var author: String?
    var tags: [String]
    var contentFolder: URL           // where steamcmd put the item (contains project.json and scene.pkg)
    var previewSource: URL?          // preview image already on disk (from the content folder), if any
}

enum SceneImporter {
    private static let sizeCap: Int64 = 3_000_000_000
    private static let unreadableNote = "This scene’s files couldn’t be read, so only its preview is shown."
    private static let previewTypes = ["jpg": "jpg", "jpeg": "jpg", "png": "png", "gif": "gif"]

    /// Where a scene's files are: one package, or a folder with `scene.json` (a loose scene).
    enum Source: Equatable {
        case package(URL)
        case loose(sceneJSON: URL)
    }

    /// project.json's `file` when it names a package or a scene.json, else scene.pkg, else the first package,
    /// else a scene.json at the top. Nothing outside `content` is ever chosen.
    static func chooseSource(in content: URL, project: WorkshopKit.Import.Project) -> Source? {
        let manager = FileManager.default
        if let name = project.file, let url = WorkshopKit.Import.safeChild(of: content, name), manager.fileExists(atPath: url.path) {
            if url.pathExtension.lowercased() == "pkg" { return .package(url) }
            if url.lastPathComponent.lowercased() == "scene.json" { return .loose(sceneJSON: url) }
        }
        let top = content.appendingPathComponent("scene.pkg")
        if manager.fileExists(atPath: top.path) { return .package(top) }
        let names = ((try? manager.contentsOfDirectory(atPath: content.path)) ?? []).sorted()
        if let pkg = names.first(where: { $0.lowercased().hasSuffix(".pkg") }) { return .package(content.appendingPathComponent(pkg)) }
        let loose = content.appendingPathComponent("scene.json")
        return manager.fileExists(atPath: loose.path) ? .loose(sceneJSON: loose) : nil
    }

    /// Throws WorkshopError.importFailed(detail) with nothing half-written (Library/<id>.partial is removed).
    /// The item's `scene` record is filled from SceneLoader's analysis; `path` is Library/<id>/scene.pkg.
    static func importScene(_ input: SceneImportInput) async throws -> VideoItem {
        let manager = FileManager.default
        let content = input.contentFolder
        let project = WorkshopKit.Import.parseProject((try? Data(contentsOf: content.appendingPathComponent("project.json"))) ?? Data())
        guard let source = chooseSource(in: content, project: project) else {
            throw WorkshopError.importFailed("This wallpaper has no scene file.")
        }
        let bytes: Int64
        switch source {
        case .package(let url): bytes = Int64(SteamKit.fileSize(url))
        case .loose: bytes = WorkshopKit.Locate.folderBytes(content)
        }
        guard bytes <= sizeCap else { throw WorkshopError.importFailed("This wallpaper is larger than 3 GB.") }
        let previewExt = input.previewSource.flatMap { previewTypes[$0.pathExtension.lowercased()] }
        let preview = previewExt == nil ? nil : input.previewSource
        let readable = analyze(source)
        if readable == nil, preview == nil {
            throw WorkshopError.importFailed("The scene’s files couldn’t be read and it has no preview image.")
        }

        let partial = AppPaths.libraryDirectory.appendingPathComponent(input.workshopID + ".partial", isDirectory: true)
        let folder = AppPaths.libraryDirectory.appendingPathComponent(input.workshopID, isDirectory: true)
        do {
            try? manager.removeItem(at: partial)
            try AppPaths.ensureDirectory(partial)
            let scenePath: String
            switch source {
            case .package(let url):
                try manager.copyItem(at: url, to: partial.appendingPathComponent("scene.pkg"))
                scenePath = "scene.pkg"
            case .loose(let json):
                try manager.copyItem(at: content, to: partial.appendingPathComponent("scene"))
                scenePath = "scene/" + relativePath(of: json, in: content)
            }
            try? manager.copyItem(at: content.appendingPathComponent("project.json"), to: partial.appendingPathComponent("project.json"))
            var previewName: String?
            if let preview, let previewExt,
               (try? manager.copyItem(at: preview, to: partial.appendingPathComponent("preview." + previewExt))) != nil {
                previewName = "preview." + previewExt
            }
            if readable == nil, previewName == nil { throw WorkshopError.importFailed("The preview image couldn’t be copied.") }
            try? manager.removeItem(at: folder)
            try manager.moveItem(at: partial, to: folder)
            return VideoItem(
                path: folder.appendingPathComponent(scenePath).standardizedFileURL.path,
                title: input.title, author: input.author, workshopID: input.workshopID,
                previewPath: previewName.map { folder.appendingPathComponent($0).standardizedFileURL.path },
                tags: input.tags.isEmpty ? nil : input.tags,
                scene: readable ?? unreadableInfo(needsSharedAssets: false))
        } catch {
            try? manager.removeItem(at: partial)
            throw error as? WorkshopError ?? WorkshopError.importFailed(error.localizedDescription)
        }
    }

    /// Re-runs the analyzer for an already imported scene (after an engine update raised
    /// SceneAnalysis.revision or EngineCapabilities.current changed). Returns the item with a fresh `scene` record.
    static func reanalyze(_ item: VideoItem) -> VideoItem {
        guard item.scene != nil else { return item }
        let url = item.url
        let source: Source = url.pathExtension.lowercased() == "pkg" ? .package(url) : .loose(sceneJSON: url)
        var fresh = item
        fresh.scene = analyze(source) ?? unreadableInfo(needsSharedAssets: item.scene?.needsSharedAssets ?? false)
        return fresh
    }

    // MARK: Analysis

    /// The SceneFormat verdict as a library record; nil when the files cannot be read at all.
    private static func analyze(_ source: Source) -> SceneInfo? {
        let assets = sharedAssets()
        let loaded: LoadedScene?
        switch source {
        case .package(let url): loaded = try? SceneLoader.load(packageAt: url, sharedAssets: assets)
        case .loose(let json): loaded = try? SceneLoader.load(directory: json.deletingLastPathComponent(), sharedAssets: assets)
        }
        guard let analysis = loaded?.analysis else { return nil }
        return SceneInfo(
            support: SceneSupport(rawValue: analysis.support.rawValue) ?? .previewOnly, notes: analysis.notes,
            designWidth: analysis.designWidth, designHeight: analysis.designHeight, loopSeconds: analysis.loopSeconds,
            needsSharedAssets: analysis.needsSharedAssets, analysisRevision: SceneAnalysis.revision)
    }

    private static func unreadableInfo(needsSharedAssets: Bool) -> SceneInfo {
        SceneInfo(support: .previewOnly, notes: [unreadableNote], needsSharedAssets: needsSharedAssets,
                  analysisRevision: SceneAnalysis.revision)
    }

    /// The scene renderer won't start any scene without these, so the UI asks for them while they are missing.
    static var hasSharedAssets: Bool { sharedAssets() != nil }

    /// The user's own copy of Wallpaper Engine's shared files, when they have fetched it.
    private static func sharedAssets() -> URL? {
        let folder = AppPaths.sharedAssetsDirectory
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return items.isEmpty ? nil : folder
    }

    private static func relativePath(of file: URL, in folder: URL) -> String {
        let base = folder.resolvingSymlinksInPath().path + "/"
        let path = file.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : file.lastPathComponent
    }
}
