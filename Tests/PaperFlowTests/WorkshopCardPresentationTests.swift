import Foundation
import Testing
@testable import PaperFlow

struct WorkshopCardPresentationTests {
    @Test func resolutionsCollapseToTheNumberPeopleSay() {
        #expect(WorkshopCardCopy.shortResolution("3840 x 2160") == "4K")
        #expect(WorkshopCardCopy.shortResolution("2560 x 1440") == "1440p")
        #expect(WorkshopCardCopy.shortResolution("1920 x 1080") == "1080p")
        #expect(WorkshopCardCopy.shortResolution("1366 x 768") == "720p")
        #expect(WorkshopCardCopy.shortResolution("1280 x 720") == "720p")
        #expect(WorkshopCardCopy.shortResolution("7680 x 4320") == "8K")
    }

    @Test func layoutsWithSeveralScreensOrPortraitGetOneWord() {
        #expect(WorkshopCardCopy.shortResolution("Ultrawide 3440 x 1440") == "Ultrawide")
        #expect(WorkshopCardCopy.shortResolution("Dual 3840 x 1080") == "Dual")
        #expect(WorkshopCardCopy.shortResolution("Triple 5760 x 1080") == "Triple")
        #expect(WorkshopCardCopy.shortResolution("Portrait 1080 x 1920") == "Portrait")
    }

    @Test func vagueResolutionsSayNothing() {
        #expect(WorkshopCardCopy.shortResolution("Other resolution") == nil)
        #expect(WorkshopCardCopy.shortResolution("Dynamic resolution") == nil)
        #expect(WorkshopCardCopy.shortResolution("Standard Definition") == nil)
        #expect(WorkshopCardCopy.shortResolution(nil) == nil)
        #expect(WorkshopCardCopy.shortResolution("640 x 480") == nil)
    }

    @Test func kindLabels() {
        #expect(WorkshopCardCopy.kindLabel("scene") == "Scene")
        #expect(WorkshopCardCopy.kindLabel("video") == "Video")
        #expect(WorkshopCardCopy.kindLabel("web") == "Web")
        #expect(WorkshopCardCopy.kindLabel("application") == "App")
        #expect(WorkshopCardCopy.kindLabel("unknown") == nil)
        #expect(WorkshopCardCopy.kindLabel(nil) == nil)
    }

    @Test func badgesAndSpokenLabel() {
        #expect(WorkshopCardCopy.badges(kind: "scene", resolutionTag: "3840 x 2160") == ["Scene", "4K"])
        #expect(WorkshopCardCopy.badges(kind: "video", resolutionTag: "Other resolution") == ["Video"])
        #expect(WorkshopCardCopy.badges(kind: nil, resolutionTag: nil).isEmpty)
        #expect(WorkshopCardCopy.accessibilityLabel(title: "KDA", kind: "scene", resolutionTag: "1920 x 1080") == "KDA, Scene, 1080p")
        #expect(WorkshopCardCopy.accessibilityLabel(title: "KDA", kind: nil, resolutionTag: nil) == "KDA")
    }
}
