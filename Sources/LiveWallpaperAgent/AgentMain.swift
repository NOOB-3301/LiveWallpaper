import AppKit
import Core

// Entry point, IPC wiring and the status item of the wallpaper agent. The command switch in run(_:) is the
// contract with the Settings app (SPEC2.md section 3.2). The agent is AppKit only: never import SwiftUI,
// Combine or AVKit here (RAM plan, SPEC2.md section 7).

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
    private let messageItem = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let nextItem = NSMenuItem()
    private var recentCommandIDs: [String] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// False until this process has won the single-instance check; a losing copy must not touch anything.
    private var isActive = false
    private var handlingCommand = false
    private var quitReplyID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignals()
        Task { @MainActor [weak self] in await self?.launch() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isActive else { return .terminateNow }
        orchestrator.shutdown(userQuit: false)
        // Also sent for SIGTERM and logout, so Settings never mistakes those for a crash.
        postStatus(reply: quitReplyID, quitting: true)
        return .terminateNow
    }

    // Order matters (SPEC2.md 3.6.2): commands are listened for before the state is loaded, and the hello
    // goes out only after bootstrap, so Settings never sees a half-started agent.
    private func launch() async {
        var attempts = 0
        while hasLowerPidPeer(), attempts < 6 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !hasLowerPidPeer() else {
            NSApp.terminate(nil)
            return
        }
        isActive = true
        refreshLegacyGuard()
        observeLegacyApp()
        endpoint.onCommand = { [weak self] command in self?.handle(command) }
        endpoint.startListening()
        buildStatusItem()
        orchestrator.bootstrap()
        orchestrator.onChange = { [weak self] in self?.orchestratorChanged() }
        refreshMenu()
        postStatus(reply: nil, quitting: false)
    }

    // MARK: Single instance and the phase-1 app

    /// Lowest pid wins. A predecessor that is still quitting gets a moment to disappear (see launch()).
    private func hasLowerPidPeer() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: IPC.agentBundleID)
            .contains { $0.processIdentifier < me && !$0.isTerminated }
    }

    /// The phase-1 app has the Settings bundle id but no LWRole key in its Info.plist.
    private func refreshLegacyGuard() {
        let legacyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: IPC.settingsBundleID)
            .contains { app in
                guard !app.isTerminated, let url = app.bundleURL, let bundle = Bundle(url: url) else { return false }
                return bundle.object(forInfoDictionaryKey: IPC.roleKey) == nil
            }
        orchestrator.blockedReason = legacyRunning ? "An older copy of Live Wallpaper is running. Quit it first." : nil
    }

    private func observeLegacyApp() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshLegacyGuard() }
            })
        }
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

    // MARK: IPC

    private func handle(_ command: AgentCommand) {
        // A retransmitted command is answered but not executed twice.
        if !recentCommandIDs.contains(command.id) {
            recentCommandIDs.append(command.id)
            if recentCommandIDs.count > 16 { recentCommandIDs.removeFirst() }
            if command.kind == .quit {
                quitWallpaper(replyTo: command.id)
                return
            }
            // The reply below carries the result, so the changes it causes are not posted on their own.
            handlingCommand = true
            run(command)
            handlingCommand = false
        }
        postStatus(reply: command.id, quitting: false)
    }

    private func run(_ command: AgentCommand) {
        switch command.kind {
        case .ping, .quit: break
        case .start: orchestrator.start(at: command.videoID)
        case .stop: orchestrator.stop()
        case .pause: orchestrator.setPaused(true)
        case .resume: orchestrator.setPaused(false)
        case .next: orchestrator.next()
        case .play: if let id = command.videoID { orchestrator.play(id) }
        case .reload: orchestrator.reload(revision: command.revision)
        }
    }

    private func postStatus(reply: String?, quitting: Bool) {
        var status = orchestrator.status(reply: reply)
        status.quitting = quitting
        endpoint.post(status)
    }

    private func orchestratorChanged() {
        refreshMenu()
        if !handlingCommand { postStatus(reply: nil, quitting: false) }
    }

    // The final status, with the reply, is posted by applicationShouldTerminate.
    private func quitWallpaper(replyTo id: String?) {
        quitReplyID = id
        orchestrator.shutdown(userQuit: true)
        NSApp.terminate(nil)
    }

    // MARK: Status item (menu spec: SPEC2.md section 5.2)

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        messageItem.isEnabled = false
        messageItem.isHidden = true
        configure(toggleItem, title: "Start Wallpaper", action: #selector(toggleRunning))
        configure(pauseItem, title: "Pause Wallpaper", action: #selector(togglePause))
        configure(nextItem, title: "Next Video", action: #selector(nextVideo))
        nextItem.keyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let settings = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "Quit Wallpaper", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        quit.toolTip = "Stops the wallpaper, restores your original wallpapers and quits this helper."
        menu.addItem(statusLine)
        menu.addItem(messageItem)
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

        if running {
            let name = "“\(orchestrator.currentItem?.name ?? "")”"
            statusLine.title = orchestrator.isPaused ? "Paused · \(name)" : "Playing \(name)"
        } else {
            statusLine.title = "Stopped"
        }
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
            : orchestrator.blockedReason ?? "Add a video and turn on Desktop or Lock Screen in Settings to start."
        pauseItem.title = orchestrator.isPaused ? "Resume Wallpaper" : "Pause Wallpaper"
        pauseItem.isEnabled = running
        nextItem.isEnabled = running && orchestrator.canRotate
    }

    @objc private func toggleRunning() {
        if orchestrator.isRunning { orchestrator.stop() } else { orchestrator.start(at: nil) }
    }

    @objc private func togglePause() { orchestrator.setPaused(!orchestrator.isPaused) }
    @objc private func nextVideo() { orchestrator.next() }
    @objc private func quitFromMenu() { quitWallpaper(replyTo: nil) }

    // The agent lives at <Settings.app>/Contents/Library/LoginItems/LiveWallpaperAgent.app.
    @objc private func openSettings() {
        let nested = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let isSettings = (Bundle(url: nested)?.object(forInfoDictionaryKey: IPC.roleKey) as? String) == "settings"
        guard let url = isSettings ? nested : NSWorkspace.shared.urlForApplication(withBundleIdentifier: IPC.settingsBundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
