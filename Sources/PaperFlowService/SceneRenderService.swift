import AppKit
import Core
import IOKit.ps
import SceneBridge

// Scenes on the desktop. Our own renderer (SceneRenderer/, a Rust library) draws them with Metal
// into the CAMetalLayers of SceneWindowManager's windows.

/// One Rust renderer, on its way from the loading thread to the main actor.
final class RendererBox: @unchecked Sendable {
    let renderer: Renderer
    init(_ renderer: Renderer) { self.renderer = renderer }
}

@MainActor final class SceneRenderService: WallpaperService {
    private var renderer: Renderer?
    private let windows = SceneWindowManager()
    private let power = PowerSource()
    private var audio: AnyObject?   // SystemAudioTap on macOS 14.2+
    private var pointerMonitor: Any?
    private var muted = true
    private var generation = 0
    private var state = LibraryState()
    // What the renderer has been given so far; nil = nothing yet, so everything is pushed.
    private var appliedScene: SceneOptions?
    private var appliedFPS: Int?
    private var appliedScale: Double?
    private var appliedPaused: Bool?
    private var paused = false
    /// The displays the renderer draws on.
    private var attached: [String] = []

    override init() {
        super.init()
        power.onChange = { [weak self] in
            guard let self, let item = self.item, self.renderer != nil else { return }
            self.push(item)
        }
    }

    /// The Orchestrator's state changed (or a scene is about to start): push only what differs.
    func update(_ state: LibraryState) {
        self.state = state
        guard renderer != nil, let item else { return }
        push(item)
    }

    override func start(_ item: VideoItem) {
        stopRenderer()
        super.start(item)
        generation += 1
        let mine = generation
        // Loading a scene takes a moment, so it happens off the main actor.
        let path = item.url.path
        Task.detached(priority: .userInitiated) { [weak self] in
            let box: Result<RendererBox, Swift.Error>
            do {
                box = .success(RendererBox(try Renderer(pkgPath: path)))
            } catch {
                box = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.loaded(box, item: item, mine: mine)
            }
        }
    }

    private func loaded(_ result: Result<RendererBox, Swift.Error>, item: VideoItem, mine: Int) {
        guard mine == generation else { return }
        switch result {
        case .failure(let error):
            super.stop()
            onFailure?(item, "Couldn’t play “\(item.name)”. \(error.localizedDescription)")
        case .success(let box):
            let renderer = box.renderer
            self.renderer = renderer
            for message in renderer.loadErrors() {
                NSLog("PaperFlow: \(item.name): \(message)")
            }
            for display in windows.displays() {
                let pointer = UInt64(UInt(bitPattern: Unmanaged.passUnretained(display.layer).toOpaque()))
                renderer.attachLayer(displayId: display.id, layerPtr: pointer,
                                     width: UInt32(display.pixelWidth), height: UInt32(display.pixelHeight))
                attached.append(display.id)
            }
            renderer.setMuted(muted: muted)
            startPointer()
            push(item)
            onReady?(item)
        }
    }

    override func stop() {
        super.stop()
        generation += 1
        stopRenderer()
        windows.close()
    }

    private func stopRenderer() {
        stopPointer()
        for id in attached {
            renderer?.detachLayer(displayId: id)
        }
        attached = []
        renderer?.stop()
        renderer = nil
        setAudioCapture(false)
        appliedScene = nil
        appliedFPS = nil
        appliedScale = nil
        appliedPaused = nil
    }

    /// The cursor drives parallax: its position on the main screen goes to the renderer, 0...1 with
    /// the origin at the top-left. A left press on the bare desktop goes to the scene's scripts, so a
    /// clock can be dragged.
    private func startPointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            // Global monitors run on the main thread.
            MainActor.assumeIsolated { self?.pointerEvent(event.type) }
        }
    }

    private var pressedOnDesktop = false

    private func pointerEvent(_ type: NSEvent.EventType) {
        sendPointer()
        switch type {
        case .leftMouseDown where Self.isDesktop(at: NSEvent.mouseLocation):
            pressedOnDesktop = true
            renderer?.setPointerDown(down: true)
        case .leftMouseUp where pressedOnDesktop:
            pressedOnDesktop = false
            renderer?.setPointerDown(down: false)
        default:
            break
        }
    }

    /// Whether a click at `point` lands on the desktop rather than on some app's window.
    private static func isDesktop(at point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let level = info.first?[kCGWindowLayer as String] as? Int
        else { return true }
        return level <= Int(CGWindowLevelForKey(.desktopIconWindow))
    }

    private func stopPointer() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        pressedOnDesktop = false
    }

    private func sendPointer() {
        guard let renderer, let screen = NSScreen.main else { return }
        let frame = screen.frame
        let mouse = NSEvent.mouseLocation
        renderer.setPointer(x: Float((mouse.x - frame.minX) / frame.width),
                            y: Float(1 - (mouse.y - frame.minY) / frame.height))
    }

    override func setPaused(_ paused: Bool) {
        self.paused = paused
        if let item, renderer != nil { push(item) }
    }

    override func setMuted(_ muted: Bool) {
        self.muted = muted
        renderer?.setMuted(muted: muted)
    }

    /// The lock screen covers the desktop: nothing is drawn and nothing is heard.
    override func setScreenLocked(_ locked: Bool) {
        renderer?.setVisible(visible: !locked)
    }

    /// Sends the settings that changed since the last push. Battery rules apply here: on battery
    /// (or in Low Power Mode) the scene pauses or runs slower and smaller, as the user chose.
    private func push(_ item: VideoItem) {
        guard let renderer else { return }
        let new = state.sceneOptions[item.id.uuidString] ?? .standard
        let old = appliedScene
        let rules = state.power
        let saving = power.isSaving
        var fps = new.fps ?? state.sceneFPS
        var scale = new.renderScale
        if let cap = rules.frameRateCap { fps = min(fps, max(cap, 1)) }
        if saving && rules.batteryMode == .reducedQuality {
            fps = min(fps, rules.batteryFPS)
            scale = min(scale, rules.batteryRenderScale)
        }
        let pause = paused || (saving && rules.batteryMode == .pause)

        if new.fitMode != old?.fitMode {
            renderer.setFitMode(mode: new.fitMode.renderer)
        }
        if new.panX != old?.panX || new.panY != old?.panY || new.zoom != old?.zoom {
            // The sliders are 0...1 with 0.5 in the middle; the renderer wants the offset.
            renderer.setPanZoom(panX: Float(new.panX - 0.5), panY: Float(new.panY - 0.5), zoom: Float(new.zoom))
        }
        if scale != appliedScale {
            renderer.setRenderScale(scale: Float(scale))
        }
        if new.volume != old?.volume {
            renderer.setVolume(volume: Float(new.volume))
        }
        if new.audioResponse != old?.audioResponse {
            renderer.setAudioResponse(enabled: new.audioResponse)
        }
        for (key, value) in new.properties where old?.properties[key] != value {
            renderer.applyProperty(name: key, valueJson: value.json)
        }
        if fps != appliedFPS {
            renderer.setFpsCap(fps: Float(fps))
        }
        if pause != appliedPaused {
            if pause { renderer.pause() } else { renderer.play() }
        }
        setAudioCapture(new.audioResponse && !pause)
        appliedScene = new
        appliedFPS = fps
        appliedScale = scale
        appliedPaused = pause
    }

    /// System audio is captured only while a playing scene asks for audio response.
    private func setAudioCapture(_ on: Bool) {
        guard #available(macOS 14.2, *) else { return }
        if on, audio == nil, let renderer {
            let tap = SystemAudioTap()
            tap.onSpectrum = { left, right in renderer.setAudioSpectrum(left: left, right: right) }
            do {
                try tap.start()
                audio = tap
            } catch {
                NSLog("PaperFlow: audio response unavailable: \(error)")
            }
        } else if !on, let tap = audio as? SystemAudioTap {
            tap.stop()
            audio = nil
        }
    }
}

/// Whether the Mac runs on battery or in Low Power Mode, with a callback when that changes.
@MainActor private final class PowerSource {
    var onChange: (() -> Void)?
    private(set) var isSaving = PowerSource.current()
    private var source: CFRunLoopSource?
    private var token: NSObjectProtocol?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<PowerSource>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.refresh() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        token = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let now = Self.current()
        guard now != isSaving else { return }
        isSaving = now
        onChange?()
    }

    private static func current() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

private extension SceneFitMode {
    var renderer: FitMode {
        switch self {
        case .fill: return .fill
        case .fit: return .fit
        case .stretch: return .stretch
        case .none: return .unscaled
        case .matchBlurred: return .matchBlurred
        }
    }
}

extension ScenePropertyValue {
    /// The renderer takes JSON: a number, a string or "r g b" for a colour.
    var json: String {
        switch self {
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return String(v)
        case .string(let v):
            let data = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        case .color(let r, let g, let b): return "\"\(r) \(g) \(b)\""
        }
    }
}
