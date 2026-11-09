import Foundation
import Testing
@testable import PaperFlow

struct LibraryPresentationTests {
    @Test func stageLayoutFollowsTheWidth() {
        #expect(LibraryStageLayout.forWidth(900) == .wide)
        #expect(LibraryStageLayout.forWidth(720) == .wide)
        #expect(LibraryStageLayout.forWidth(719) == .medium)
        #expect(LibraryStageLayout.forWidth(480) == .medium)
        #expect(LibraryStageLayout.forWidth(479) == .stacked)
    }

    @Test func previewNeverTakesMoreThanTheCap() {
        #expect(LibraryStageLayout.wide.previewWidth(contentWidth: 2000) == 410)
        #expect(LibraryStageLayout.wide.previewWidth(contentWidth: 720) == 331)   // 46 %
        #expect(LibraryStageLayout.medium.previewWidth(contentWidth: 600) == 240)
        #expect(LibraryStageLayout.stacked.previewWidth(contentWidth: 386) == 356)
        #expect(LibraryStageLayout.stacked.previewWidth(contentWidth: 300) == 300)
    }

    @Test func previewHeightStaysUnderTheStageCap() {
        for width in stride(from: 300.0, through: 2400.0, by: 50) {
            let layout = LibraryStageLayout.forWidth(width)
            let height = layout.previewWidth(contentWidth: width) * 9 / 16
            #expect(height <= 231.25)
        }
    }

    @Test func countTitleByScope() {
        func title(_ count: Int, _ scope: LibraryCountScope, selected: Int = 0, selecting: Bool = false, search: String = "") -> String {
            LibraryCopy.countTitle(count: count, scope: scope, selected: selected, selecting: selecting, search: search)
        }
        #expect(title(1, .all) == "1 wallpaper")
        #expect(title(12, .all) == "12 wallpapers")
        #expect(title(3, .desktop) == "3 set for your desktop")
        #expect(title(2, .lock) == "2 set for the lock screen")
        #expect(title(1, .scenes) == "1 Wallpaper Engine scene")
        #expect(title(4, .scenes) == "4 Wallpaper Engine scenes")
    }

    @Test func selectionAndSearchWinOverTheScope() {
        func title(_ count: Int, selected: Int, selecting: Bool, search: String) -> String {
            LibraryCopy.countTitle(count: count, scope: .all, selected: selected, selecting: selecting, search: search)
        }
        #expect(title(12, selected: 3, selecting: false, search: "") == "3 selected")
        #expect(title(12, selected: 0, selecting: true, search: "") == "Select wallpapers")
        #expect(title(12, selected: 1, selecting: true, search: "") == "1 selected")
        #expect(title(2, selected: 1, selecting: false, search: "neon") == "2 results for “neon”")
        #expect(title(1, selected: 1, selecting: false, search: "neon") == "1 result for “neon”")
    }

    @Test func rotationSummary() {
        #expect(LibraryCopy.rotationSummary(desktop: false, lock: false) == "Rotation is off.")
        #expect(LibraryCopy.rotationSummary(desktop: true, lock: false) == "Rotation is on for the desktop.")
        #expect(LibraryCopy.rotationSummary(desktop: false, lock: true) == "Rotation is on for the lock screen.")
        #expect(LibraryCopy.rotationSummary(desktop: true, lock: true) == "Rotation is on for both screens.")
    }
}
