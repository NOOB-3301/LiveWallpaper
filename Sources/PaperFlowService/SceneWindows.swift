import AppKit
import QuartzCore

// The windows a scene is drawn in. The old renderer made its own windows; ours draws into a
// CAMetalLayer that the app hands over, so the app keeps control of the window level, the
// spaces and the occlusion state.

/// A view whose backing layer is a CAMetalLayer, so the renderer can draw into it.
private final class MetalView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true  // after super.init, so makeBackingLayer() is what creates the layer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
}

/// A borderless window that keeps its full screen frame. AppKit otherwise shrinks it to the visible
/// frame, which leaves a strip under the menu bar undrawn.
private final class SceneWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// One display the scene is drawn on.
struct SceneDisplay {
    /// Stable id of the display, used to attach and detach the layer.
    let id: String
    let layer: CAMetalLayer
    /// Size of the drawable in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
}

/// One borderless window per screen, each with a CAMetalLayer in it.
@MainActor final class SceneWindowManager {
    private var windows: [(window: NSWindow, view: MetalView)] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// Creates the windows if needed and returns the layer of every screen.
    func displays() -> [SceneDisplay] {
        if windows.isEmpty { rebuildWindows() }
        return windows.compactMap { entry -> SceneDisplay? in
            guard let layer = entry.view.metalLayer else { return nil }
            let screen = entry.window.screen
            let scale = screen?.backingScaleFactor ?? 1
            layer.contentsScale = scale
            let size = entry.window.frame.size
            return SceneDisplay(
                id: Self.displayID(entry.window.screen),
                layer: layer,
                pixelWidth: Int((size.width * scale).rounded()),
                pixelHeight: Int((size.height * scale).rounded())
            )
        }
    }

    /// Tells the layers to stop drawing; the windows stay (the desktop keeps its last picture).
    func setVisible(_ visible: Bool) {
        for entry in windows {
            if visible { entry.window.orderFrontRegardless() } else { entry.window.orderOut(nil) }
        }
    }

    func close() {
        for entry in windows { entry.window.close() }
        windows.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    /// The screen's number, which is stable while the display is connected.
    private static func displayID(_ screen: NSScreen?) -> String {
        let number = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        return String(number)
    }

    private func rebuildWindows() {
        windows.forEach { $0.window.close() }
        windows = NSScreen.screens.map { screen in
            let view = MetalView(frame: .zero)
            let window = SceneWindow(contentRect: screen.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.canHide = false
            window.isExcludedFromWindowsMenu = true
            window.backgroundColor = .black
            window.contentView = view
            window.orderFrontRegardless()
            return (window, view)
        }
        installObservers()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildWindows() }
        }
        observers.append((center, token))
    }
}
