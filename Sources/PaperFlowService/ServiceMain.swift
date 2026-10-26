import AppKit
import Core

// Entry point, socket server and status item of the background service.
// The UI launches it when nothing answers on ServiceSocket.path; it may also be registered as a login item.
// AppKit only: never import SwiftUI or Combine here.

@main
enum ServiceEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ServiceDelegate()
        app.delegate = delegate  // NSApplication keeps its delegate weakly
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class ServiceDelegate: NSObject, NSApplicationDelegate {
    private static let bundleID = "com.noob3301.LiveWallpaper.service"

    private let orchestrator = Orchestrator()
    private let server = SocketServer()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let statusLine = NSMenuItem()
    private let lockLine = NSMenuItem()
    private let messageItem = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let nextItem = NSMenuItem()
    private let nextLockItem = NSMenuItem()
    private let muteItem = NSMenuItem()
    private var signalSources: [DispatchSourceSignal] = []
    private var isActive = false
    private var handlingCommand = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignals()
        Task { @MainActor [weak self] in await self?.launch() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isActive else { return .terminateNow }
        orchestrator.shutdown(userQuit: false)
        server.push(orchestrator.status())
        server.stop()
        return .terminateNow
    }

    private func launch() async {
        // One copy at a time: a live service answering on the socket wins (a stale socket file has no listener
        // and is replaced by SocketServer.start). Two copies launched together: the younger waits for the older.
        var attempts = 0
        while hasLowerPidPeer(), !ServiceSocket.isServing(), attempts < 20 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !ServiceSocket.isServing(), !hasLowerPidPeer() else {
            NSLog("PaperFlowService: another copy is already running; exiting.")
            NSApp.terminate(nil)
            return
        }
        isActive = true
        buildStatusItem()
        orchestrator.bootstrap()
        orchestrator.onChange = { [weak self] in self?.orchestratorChanged() }
        server.perform = { [weak self] command in self?.perform(command) ?? (ServiceStatus(), nil) }
        do { try server.start() } catch {
            NSLog("PaperFlowService: can’t listen on \(ServiceSocket.path): \(error.localizedDescription)")
        }
        refreshMenu()
    }

    private func hasLowerPidPeer() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .contains { $0.processIdentifier < me && !$0.isTerminated }
    }

    // SIGTERM and SIGINT take the normal quit path, so Apple's wallpapers are restored.
    private func installTerminationSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Commands

    /// Runs one command; returns the status to reply with and an error message (nil = done).
    private func perform(_ command: ServiceCommand) -> (ServiceStatus, String?) {
        if case .status = command { return (orchestrator.status(), nil) }
        // The reply carries the result, so the changes the command causes are not pushed on their own.
        handlingCommand = true
        defer { handlingCommand = false }
        var error: String?
        switch command {
        case .commit(let state):
            if !orchestrator.commit(state) { error = "Couldn’t save your library." }
        case .start(let itemID, let target):
            if let itemID { orchestrator.play(itemID, target: target) } else { orchestrator.start(at: nil, target: target) }
        case .stop: orchestrator.stop()
        case .pause: orchestrator.setPaused(true)
        case .resume: orchestrator.setPaused(false)
        case .next(let target): orchestrator.next(target: target)
        case .setMuted(let muted): orchestrator.setMuted(muted)
        case .status: break
        case .quit:
            // After the reply has gone out.
            DispatchQueue.main.async { [weak self] in self?.quitWallpaper() }
        }
        let status = orchestrator.status()
        server.push(status)  // other connected windows learn about it too
        return (status, error)
    }

    private func orchestratorChanged() {
        refreshMenu()
        if !handlingCommand { server.push(orchestrator.status()) }
    }

    private func quitWallpaper() {
        orchestrator.shutdown(userQuit: true)
        NSApp.terminate(nil)
    }

    // MARK: Status item (menu spec: SPEC3.md section 6.5)

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        lockLine.isEnabled = false
        messageItem.isEnabled = false
        messageItem.isHidden = true
        configure(toggleItem, title: "Start Wallpaper", action: #selector(toggleRunning))
        configure(pauseItem, title: "Pause Wallpaper", action: #selector(togglePause))
        configure(nextItem, title: "Next Wallpaper", action: #selector(nextDesktopWallpaper))
        nextItem.keyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        configure(nextLockItem, title: "Next Lock Screen Wallpaper", action: #selector(nextLockWallpaper))
        configure(muteItem, title: "Mute Sound", action: #selector(toggleMute))
        let settings = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "Quit Wallpaper", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        quit.toolTip = "Stops the wallpaper, restores your original wallpapers and quits this helper."
        [statusLine, lockLine, messageItem, .separator(), settings, .separator(),
         toggleItem, pauseItem, nextItem, nextLockItem, muteItem, .separator(), quit].forEach(menu.addItem)
        item.menu = menu
    }

    private func configure(_ item: NSMenuItem, title: String, action: Selector) {
        item.title = title
        item.action = action
        item.target = self
    }

    private func refreshMenu() {
        let running = orchestrator.isRunning
        let symbol = running ? (orchestrator.isPaused ? "pause.rectangle.fill" : "play.rectangle.fill") : "play.rectangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PaperFlow")
        image?.isTemplate = true
        statusItem?.button?.image = image

        let together = showsOneWallpaper
        statusLine.title = together ? sharedStatusText : statusText(for: .desktop)
        lockLine.title = statusText(for: .lock)
        lockLine.isHidden = together
        let message = orchestrator.message
        messageItem.isHidden = message == nil
        messageItem.toolTip = message
        if let message {
            // Menu items do not wrap, and some messages are whole paragraphs; the tooltip has the full text.
            let shown = message.count > 64 ? String(message.prefix(63)) + "…" : message
            messageItem.attributedTitle = NSAttributedString(
                string: "⚠ " + shown, attributes: [.foregroundColor: NSColor.systemOrange])
        }

        toggleItem.title = running ? "Stop Wallpaper" : "Start Wallpaper"
        toggleItem.isEnabled = running || orchestrator.canStart
        toggleItem.toolTip = toggleItem.isEnabled ? nil
            : "Add a video and turn on Desktop or Lock Screen in Settings to start."
        pauseItem.title = orchestrator.isPaused ? "Resume Wallpaper" : "Pause Wallpaper"
        pauseItem.isEnabled = running
        nextItem.title = together ? "Next Wallpaper" : "Next Desktop Wallpaper"
        nextItem.isEnabled = orchestrator.canRotate(.desktop) || (together && orchestrator.canRotate(.lock))
        nextLockItem.isHidden = together
        nextLockItem.isEnabled = orchestrator.canRotate(.lock)
        muteItem.state = orchestrator.muted ? .on : .off
    }

    // One wallpaper for both targets and both on: one status line and one Next item.
    private var showsOneWallpaper: Bool {
        let state = orchestrator.state
        return state.sameForBoth && state.isEnabled(.desktop) && state.isEnabled(.lock)
    }

    private var sharedStatusText: String {
        guard orchestrator.isRunning else { return "Stopped" }
        let name = "“\(orchestrator.currentItem(for: .desktop)?.name ?? "")”"
        return orchestrator.isPaused ? "Paused · \(name)" : "Playing \(name) on desktop and lock screen"
    }

    private func statusText(for target: WallpaperTarget) -> String {
        let label = target.label
        guard orchestrator.state.isEnabled(target) else { return "\(label): Off" }
        guard orchestrator.isRunning else { return "\(label): Stopped" }
        guard let item = orchestrator.currentItem(for: target) else { return "\(label): Off" }
        let name = "“\(item.name)”"
        return target == .desktop && orchestrator.isPaused ? "\(label): Paused · \(name)" : "\(label): Playing \(name)"
    }

    @objc private func toggleRunning() {
        if orchestrator.isRunning { orchestrator.stop() } else { orchestrator.start(at: nil) }
    }

    @objc private func togglePause() { orchestrator.setPaused(!orchestrator.isPaused) }
    @objc private func nextDesktopWallpaper() { orchestrator.next(target: showsOneWallpaper ? nil : .desktop) }
    @objc private func nextLockWallpaper() { orchestrator.next(target: .lock) }
    @objc private func toggleMute() { orchestrator.setMuted(!orchestrator.muted) }
    @objc private func quitFromMenu() { quitWallpaper() }

    // The service lives at <PaperFlow.app>/Contents/Library/LoginItems/PaperFlowService.app.
    @objc private func openSettings() {
        let nested = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let isSettings = (Bundle(url: nested)?.object(forInfoDictionaryKey: AppIdentity.roleKey) as? String) == "settings"
        guard let url = isSettings ? nested : NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppIdentity.settingsBundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
