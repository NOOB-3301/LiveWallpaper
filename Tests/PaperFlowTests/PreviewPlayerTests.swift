import Foundation
import Testing
@testable import PaperFlow

@MainActor
struct PreviewPlayerTests {
    // AVQueuePlayer doesn't open the file until it plays, so any path will do.
    private let url = URL(fileURLWithPath: "/tmp/preview-test.mov")

    // A paused player keeps its decoder (~230 MB for 4K), so a hidden preview must drop the player.
    @Test func hidingReleasesThePlayer() {
        let preview = PreviewPlayer()
        preview.load(url)
        #expect(preview.player != nil)
        preview.setActive(false)
        #expect(preview.player == nil)
    }

    @Test func showingAgainRebuildsThePlayer() {
        let preview = PreviewPlayer()
        preview.load(url)
        preview.setActive(false)
        preview.setActive(true)
        #expect(preview.player != nil)
    }

    @Test func loadingWhileHiddenWaitsUntilShown() {
        let preview = PreviewPlayer()
        preview.setActive(false)
        preview.load(url)
        #expect(preview.player == nil)
        preview.setActive(true)
        #expect(preview.player != nil)
    }

    @Test func loadingNothingClearsThePlayer() {
        let preview = PreviewPlayer()
        preview.load(url)
        preview.load(nil)
        #expect(preview.player == nil)
    }
}
