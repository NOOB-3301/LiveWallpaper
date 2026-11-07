import Foundation
import Testing
@testable import PaperFlow

@MainActor
struct WorkshopDownloadTests {
    private func run(_ event: WorkshopKit.Output.Event? = nil, timedOut: Bool = false,
                     cancelled: Bool = false) -> WorkshopKit.Run {
        var run = WorkshopKit.Run()
        run.decisive = event
        run.timedOut = timedOut
        run.cancelled = cancelled
        return run
    }

    @Test func timeoutsAndLostConnectionsResume() {
        #expect(WorkshopKit.Output.shouldResume(run(timedOut: true)))
        #expect(WorkshopKit.Output.shouldResume(run(.failure(.timedOut))))
        #expect(WorkshopKit.Output.shouldResume(run(.failure(.network("lost")))))
        let line = "ERROR! Timeout downloading item 3637446898"
        #expect(WorkshopKit.Output.classify(line) == .failure(.timedOut))
    }

    @Test func finalOutcomesDoNotResume() {
        #expect(!WorkshopKit.Output.shouldResume(run(.success(nil))))
        #expect(!WorkshopKit.Output.shouldResume(run(.failure(.notOwned))))
        #expect(!WorkshopKit.Output.shouldResume(run(.failure(.needsLogin))))
        #expect(!WorkshopKit.Output.shouldResume(run(.failure(.timedOut), cancelled: true)))
    }

    /// The log is the only thing that moves during a transfer, so a line added to it has to register.
    @Test func logGrowthIsVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorkshopKit.Locate.logBytes(in: root) == 0)

        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let line = Data("Current download rate: 2.989 Mbps\n".utf8)
        try line.write(to: logs.appendingPathComponent("content_log.txt"))
        #expect(WorkshopKit.Locate.logBytes(in: root) == Int64(line.count))
    }
}
