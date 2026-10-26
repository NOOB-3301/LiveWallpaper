import Foundation
import Core

// Serves the UI over ServiceSocket (a Unix socket in Application Support). Commands arrive on socket threads and run
// on the main actor; every connected UI receives status pushes.

@MainActor final class SocketServer {
    var perform: (@MainActor (ServiceCommand) -> (ServiceStatus, String?))?

    private var server: ServiceSocketServer?

    func start() throws {
        // Strong capture: the server lives as long as the process.
        let server = ServiceSocketServer { [self] data in await handle(data) }
        try server.start()
        self.server = server
    }

    func stop() { server?.stop() }

    func push(_ status: ServiceStatus) {
        server?.broadcast(status: ServiceCoding.encode(status))
    }

    private func handle(_ data: Data) -> Result<Data, ServiceSocketError> {
        guard let command = ServiceCoding.decode(ServiceCommand.self, from: data) else {
            return .failure(ServiceSocketError("The wallpaper service didn’t understand that request. Update PaperFlow."))
        }
        guard let perform else { return .failure(ServiceSocketError("The wallpaper service is still starting.")) }
        let (status, error) = perform(command)
        if let error { return .failure(ServiceSocketError(error)) }
        return .success(ServiceCoding.encode(status))
    }
}
