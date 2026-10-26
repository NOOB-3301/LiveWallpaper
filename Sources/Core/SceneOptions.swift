import Foundation

// Per-scene and global render settings. Stored in state.json (LibraryState.sceneOptions / .power), edited in the
// settings app, applied by PaperFlowService through SceneBridge. Every field has a default, so older files load.

/// How a scene is fitted to a display (maps to the bridge's scaling mode).
public enum SceneFitMode: String, Codable, CaseIterable, Sendable {
    case fill, fit, stretch, none, matchBlurred
    public var title: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .none: return "Original size"
        case .matchBlurred: return "Fit with blurred backdrop"
        }
    }
}

/// One value of a scene's own user property (from its project.json), set from the settings app.
public enum ScenePropertyValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case color(red: Double, green: Double, blue: Double)
}

/// Settings for one scene wallpaper. Keyed by the item's id in `LibraryState.sceneOptions`.
public struct SceneOptions: Codable, Equatable, Sendable {
    public var fps: Int?                 // nil = the global frame-rate setting
    public var renderScale: Double       // 0.25...1, share of the display's pixels the scene is drawn at
    public var zoom: Double              // 0.5...2, 1 = as authored
    public var fitMode: SceneFitMode
    public var panX: Double              // 0...1, 0.5 = centred
    public var panY: Double
    public var volume: Double            // 0...1, scene sound
    public var audioResponse: Bool       // scene reacts to what the Mac plays
    public var antialiasing: Bool        // shortcut: scene FXAA not in the renderer yet; stored, applied later
    public var properties: [String: ScenePropertyValue]

    public init(fps: Int? = nil, renderScale: Double = 1, zoom: Double = 1, fitMode: SceneFitMode = .matchBlurred,
                panX: Double = 0.5, panY: Double = 0.5, volume: Double = 1, audioResponse: Bool = false,
                antialiasing: Bool = false, properties: [String: ScenePropertyValue] = [:]) {
        self.fps = fps
        self.renderScale = min(max(renderScale, 0.25), 1)
        self.zoom = min(max(zoom, 0.5), 2)
        self.fitMode = fitMode
        self.panX = min(max(panX, 0), 1)
        self.panY = min(max(panY, 0), 1)
        self.volume = min(max(volume, 0), 1)
        self.audioResponse = audioResponse
        self.antialiasing = antialiasing
        self.properties = properties
    }

    public static let standard = SceneOptions()
}

/// What the scene battery rule does (maps to the bridge's battery mode).
public enum BatteryMode: String, Codable, CaseIterable, Sendable {
    case keepRunning, reducedQuality, pause
    public var title: String {
        switch self {
        case .keepRunning: return "Keep running"
        case .reducedQuality: return "Reduced quality"
        case .pause: return "Pause"
        }
    }
}

/// Global scene settings, all displays. Stored in `LibraryState.power`.
public struct PowerOptions: Codable, Equatable, Sendable {
    public var frameRateCap: Int?              // nil = no global cap
    public var batteryMode: BatteryMode
    public var batteryRenderScale: Double      // 0.25...1, used in reduced quality
    public var batteryFPS: Int                 // used in reduced quality
    public var skipRepeatedFrames: Bool        // scene render optimisation
    public var renderOnlyOnChange: Bool        // "update only when the scene changes" (stops idle scenes)

    public init(frameRateCap: Int? = nil, batteryMode: BatteryMode = .reducedQuality, batteryRenderScale: Double = 0.5,
                batteryFPS: Int = 24, skipRepeatedFrames: Bool = true, renderOnlyOnChange: Bool = false) {
        self.frameRateCap = frameRateCap
        self.batteryMode = batteryMode
        self.batteryRenderScale = min(max(batteryRenderScale, 0.25), 1)
        self.batteryFPS = min(max(batteryFPS, 10), 120)
        self.skipRepeatedFrames = skipRepeatedFrames
        self.renderOnlyOnChange = renderOnlyOnChange
    }

    public static let standard = PowerOptions()
}
