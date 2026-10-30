import Testing
@testable import PaperFlow

@MainActor
struct UpdateCheckerTests {
    @Test func newerTagIsAnUpdate() {
        #expect(UpdateChecker.isNewer("v6.10.0", than: "6.9.1"))  // numeric, not string, order
        #expect(UpdateChecker.isNewer("v7", than: "6.9.1"))
        #expect(UpdateChecker.isNewer("v6.9.1", than: "6.9"))
    }

    @Test func sameOrOlderTagIsNot() {
        #expect(!UpdateChecker.isNewer("v6.9.1", than: "6.9.1"))
        #expect(!UpdateChecker.isNewer("v6.9", than: "6.9.0"))
        #expect(!UpdateChecker.isNewer("v6.8.0", than: "6.9.1"))
    }
}
