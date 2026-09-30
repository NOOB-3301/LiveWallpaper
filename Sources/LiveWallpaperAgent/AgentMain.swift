import AppKit
import Core

// SCAFFOLD STUB (owner: AGENT): entry point, IPC wiring and the status item skeleton. The command switch in
// handle(_:) is the contract with the Settings app; everything marked TODO(AGENT) is still to be written.
// The agent is AppKit only: never import SwiftUI, Combine or AVKit here (RAM plan, SPEC2.md section 7).

@main
enum AgentEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AgentDelegate()
        app.delegate = delegate  // NSApplication keeps its delegate weakly
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AgentDelegate: NSObject, NSApplicationDelegate {
    // Property defaults, not an `override init()`: on Swift 5.10 (Xcode 15.4) the override of NSObject.init()
    // is nonisolated, so it cannot call the main-actor Orchestrator init. Defaults run isolated on every compiler.
    private let orchestrator = Orchestrator()
    private let endpoint = AgentEndpoint()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let statusLine = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let nextItem = NSMenuItem()
    private var recentCommandIDs: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TODO(AGENT): single instance first (lowest pid wins; re-check for ~1.5 s so a quitting predecessor is
        // tolerated), then the legacy guard (a running app with bundle id IPC.settingsBundleID and no LWRole
        // Info.plist key is the phase-1 app: set orchestrator.blockedReason), then SIGTERM/SIGINT -> terminate.
        endpoint.onCommand = { [weak self] command in self?.handle(command) }
        endpoint.startListening()
        orchestrator.onChange = { [weak self] in self?.orchestratorChanged() }
        buildStatusItem()
        orchestrator.bootstrap()
        refreshMenu()
        postStatus(reply: nil, quitting: false)  // the "hello" that tells Settings the agent is up
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        orchestrator.shutdown(userQuit: false)
        return .terminateNow
    }

    // MARK: IPC

    private func handle(_ command: AgentCommand) {
        // A retransmitted command is answered but not executed twice.
        let duplicate = recentCommandIDs.contains(command.id)
        if !duplicate {
            recentCommandIDs.append(command.id)
            if recentCommandIDs.count > 16 { recentCommandIDs.removeFirst() }
            switch command.kind {
            case .ping: break
            case .start: orchestrator.start(at: command.videoID)
            case .stop: orchestrator.stop()
            case .pause: orchestrator.setPaused(true)
            case .resume: orchestrator.setPaused(false)
            case .next: orchestrator.next()
            case .play: if let id = command.videoID { orchestrator.play(id) }
            case .reload: orchestrator.reload(revision: command.revision)
            case .quit:
                quitWallpaper(replyTo: command.id)
                return
            }
        }
        postStatus(reply: command.id, quitting: false)
    }

    private func postStatus(reply: String?, quitting: Bool) {
        var status = orchestrator.status(reply: reply)
        status.quitting = quitting
        endpoint.post(status)
    }

    private func orchestratorChanged() {
        refreshMenu()
        postStatus(reply: nil, quitting: false)
    }

    private func quitWallpaper(replyTo id: String?) {
        orchestrator.shutdown(userQuit: true)
        postStatus(reply: id, quitting: true)
        NSApp.terminate(nil)
    }

    // MARK: Status item (menu spec: SPEC2.md section 5.2)

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        configure(toggleItem, title: "Start Wallpaper", action: #selector(toggleRunning))
        configure(pauseItem, title: "Pause Wallpaper", action: #selector(togglePause))
        configure(nextItem, title: "Next Video", action: #selector(nextVideo))
        let settings = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "Quit Wallpaper", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(pauseItem)
        menu.addItem(nextItem)
        menu.addItem(.separator())
        menu.addItem(quit)
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
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Live Wallpaper")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusLine.title = running
            ? (orchestrator.isPaused ? "Paused · " : "Playing ") + (orchestrator.currentItem?.name ?? "")
            : "Stopped"
        toggleItem.title = running ? "Stop Wallpaper" : "Start Wallpaper"
        toggleItem.isEnabled = running || orchestrator.canStart
        pauseItem.title = orchestrator.isPaused ? "Resume Wallpaper" : "Pause Wallpaper"
        pauseItem.isEnabled = running
        nextItem.isEnabled = running && orchestrator.canRotate
        // TODO(AGENT): orange message line (attributedTitle) when orchestrator.statusMessage is set.
    }

    @objc private func toggleRunning() {
        if orchestrator.isRunning { orchestrator.stop() } else { orchestrator.start(at: nil) }
    }

    @objc private func togglePause() { orchestrator.setPaused(!orchestrator.isPaused) }
    @objc private func nextVideo() { orchestrator.next() }
    @objc private func quitFromMenu() { quitWallpaper(replyTo: nil) }

    @objc private func openSettings() {
        // TODO(AGENT): the agent lives at <Settings.app>/Contents/Library/LoginItems/LiveWallpaperAgent.app,
        // so the Settings bundle is four path components up; verify its Info.plist LWRole is "settings",
        // else fall back to NSWorkspace.urlForApplication(withBundleIdentifier: IPC.settingsBundleID).
        let url = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
