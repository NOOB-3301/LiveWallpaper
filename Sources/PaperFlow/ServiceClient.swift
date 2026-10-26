import AppKit
import ServiceManagement
import Core

// The UI's only link to the background service (PaperFlowService): one ServiceSocketClient connection to
// ServiceSocket.path. When nothing answers, the UI launches the nested service app itself (no launchd), sends
// ServiceCommands and publishes the ServiceStatus it reports.

struct ServiceError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@MainActor final class ServiceClient: ObservableObject {
    static let shared = ServiceClient()

    enum State: Equatable {
        case unknown          // not started
        case needsApproval    // unused since the socket transport (kept so the UI's switches stay unchanged)
        case connecting       // launching / waiting for the first answer
        case connected
        case unavailable      // the service could not be started or does not answer; see connectionError
    }

    @Published private(set) var status: ServiceStatus?
    @Published private(set) var connectionError: String?
    @Published private(set) var state: State = .unknown

    private var connection: ServiceSocketClient?
    private var connecting: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var loginItemTried = false
    private var quitRequested = false   // Quit Service: reconnect only if something else starts the service

    /// <PaperFlow.app>/Contents/Library/LoginItems/PaperFlowService.app
    private static let serviceApp = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/LoginItems/PaperFlowService.app", isDirectory: true)

    // MARK: Lifecycle

    /// Connects (launching the service if needed) and asks for the status. Idempotent while connecting.
    func start() {
        quitRequested = false
        begin(launch: true)
    }

    private func begin(launch: Bool) {
        retry?.cancel()
        guard connection == nil, connecting == nil else { return }
        if launch { state = .connecting }
        connecting = Task { @MainActor [weak self] in
            await self?.connect(launch: launch)
            if !Task.isCancelled { self?.connecting = nil }
        }
    }

    func stop() {
        retry?.cancel()
        connecting?.cancel()
        connecting = nil
        connection?.close()
        connection = nil
    }

    /// Quits the service, then connects again (which launches a fresh copy).
    func restart() async {
        _ = try? await perform(.quit)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        stop()
        status = nil
        start()
    }

    private func connect(launch: Bool) async {
        let path = ServiceSocket.path
        if !(await Self.isServing(path)) {
            guard launch else { return retryLater() }
            guard launchService() else { return }
            var waited = 0
            while !(await Self.isServing(path)) {
                waited += 1
                guard waited <= 20, !Task.isCancelled else {
                    return fail("The wallpaper service didn’t start. Try Connect to Service, or reinstall PaperFlow.")
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard !Task.isCancelled else { return }
        let client = ServiceSocketClient(
            onStatus: { data in
                guard let status = ServiceCoding.decode(ServiceStatus.self, from: data) else { return }
                Task { @MainActor in ServiceClient.shared.adopt(status) }
            },
            onDisconnect: {
                Task { @MainActor in ServiceClient.shared.lost() }
            })
        do {
            try await Self.offMain { try client.connect(path: path) }
        } catch {
            return fail("Couldn’t connect to the wallpaper service: \(error.localizedDescription)")
        }
        connection = client
        await refreshStatus()
        registerLoginItem()
    }

    /// False (and `.unavailable`) when the service app cannot be found or opened.
    private func launchService() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.serviceApp.path) else {
            fail("The wallpaper service is missing from this copy of the app.")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Self.serviceApp, configuration: configuration) { _, error in
            if let error { NSLog("PaperFlow: couldn’t launch the service: \(error.localizedDescription)") }
        }
        return true
    }

    /// Best effort: start the service at login. The UI launches it anyway, so a failure only gets logged.
    private func registerLoginItem() {
        guard !loginItemTried else { return }
        loginItemTried = true
        let item = SMAppService.loginItem(identifier: "com.noob3301.LiveWallpaper.service")
        // The bundle id survived the rename, the bundle path didn't. A registration made by an older copy
        // would keep pointing at it, so replace it with one from this copy instead of trusting it.
        if item.status != .notRegistered { try? item.unregister() }
        do { try item.register() } catch {
            NSLog("PaperFlow: couldn’t register the service as a login item: \(error.localizedDescription)")
        }
    }

    /// Blocking socket calls stay off the main thread.
    private static func offMain(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    private static func isServing(_ path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { ServiceSocket.isServing(at: path) }.value
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: ServiceCommand) async throws -> ServiceStatus {
        guard let connection else { throw ServiceError("The wallpaper service isn’t connected.") }
        if case .quit = command { quitRequested = true }
        let data = try await connection.send(command: ServiceCoding.encode(command))
        guard let result = ServiceCoding.decode(ServiceStatus.self, from: data) else {
            throw ServiceError("The wallpaper service sent an unreadable answer.")
        }
        adopt(result)
        return result
    }

    func refreshStatus() async {
        do { try await perform(.status) } catch { fail(error.localizedDescription) }
    }

    // MARK: Connection

    private func adopt(_ new: ServiceStatus) {
        guard connection != nil else { return }   // a push that raced stop()
        status = new
        state = .connected
        connectionError = nil
        retry?.cancel()
    }

    /// The service went away: relaunch it after a crash, only watch for it after Quit Service.
    private func lost() {
        connection = nil
        status = nil
        state = quitRequested ? .unknown : .connecting
        retryLater()
    }

    private func fail(_ message: String) {
        connection?.close()
        connection = nil
        connectionError = message
        state = .unavailable
        retryLater()
    }

    /// Tries again every 3 s until the service answers.
    private func retryLater() {
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.state != .connected else { return }
            self.begin(launch: !self.quitRequested)
        }
    }
}
