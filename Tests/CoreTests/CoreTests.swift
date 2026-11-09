import XCTest
@testable import Core

// Pure checks only: nothing here may touch ~/Library/Application Support (these run on developers' Macs too).
// Owner: scaffold. Workers may ADD tests in new files.
final class CoreTests: XCTestCase {
    private func decode(_ json: String) throws -> LibraryState {
        try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
    }

    func testSchema1StateMigratesToSharedTargets() throws {
        let a = UUID(), b = UUID()
        let state = try decode("""
        {"schema":1,"revision":7,
         "videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"},{"id":"\(b.uuidString)","path":"/v/b.mov"}],
         "selectedID":"\(b.uuidString)","rotateEnabled":false,"intervalValue":7,"intervalUnit":"hours",
         "applyToDesktop":true,"applyToLockScreen":false}
        """)
        XCTAssertEqual(state.schema, 2)
        XCTAssertEqual(state.revision, 7)
        XCTAssertTrue(state.sameForBoth)
        XCTAssertTrue(state.muted)
        XCTAssertEqual(state.desktop.selectedID, b)
        XCTAssertFalse(state.desktop.rotateEnabled)
        XCTAssertEqual(state.desktop.intervalValue, 7)
        XCTAssertEqual(state.desktop.intervalUnit, .hours)
        XCTAssertTrue(state.desktop.enabled)
        XCTAssertFalse(state.lock.enabled)
        XCTAssertEqual(state.config(for: .lock).selectedID, b)
        XCTAssertEqual(state.videos.map(\.id), [a, b])
        XCTAssertFalse(state.canPlay(.lock))
        XCTAssertTrue(state.canPlay(.desktop))
    }

    func testPhase1RecordWithoutSchemaKeyDecodes() throws {
        let state = try decode(#"{"videos":[],"rotateEnabled":true,"intervalValue":0,"intervalUnit":"seconds"}"#)
        XCTAssertEqual(state.schema, 2)
        XCTAssertEqual(state.desktop.intervalValue, 1, "interval clamps to 1...999")
    }

    func testSchema2RoundTripKeepsEverything() throws {
        let item = VideoItem(path: "/L/1/scene.pkg", title: "T", workshopID: "1",
                             scene: SceneInfo(support: .partial, notes: ["Particles are not supported yet."]))
        var state = LibraryState(videos: [item], muted: false, sameForBoth: false,
                                 desktop: TargetConfig(enabled: true, selectedID: item.id),
                                 lock: TargetConfig(enabled: true, selectedID: nil, rotateEnabled: false))
        state.revision = 3
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(LibraryState.self, from: data)
        XCTAssertEqual(back, state)
        XCTAssertEqual(back.videos[0].kind, .scene)
        XCTAssertFalse(back.muted)
        XCTAssertFalse(back.lock.rotateEnabled)
    }

    func testAssignToOneTargetTurnsSameForBothOffAndKeepsTheOther() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var state = LibraryState(videos: [a, b], desktop: TargetConfig(selectedID: a.id))
        state.normalize()
        state.assign(b.id, to: [.lock])
        XCTAssertFalse(state.sameForBoth)
        XCTAssertEqual(state.config(for: .desktop).selectedID, a.id)
        XCTAssertEqual(state.config(for: .lock).selectedID, b.id)
        XCTAssertEqual(state.targets(of: b.id), [.lock])
        state.assign(b.id, to: [.desktop, .lock])
        XCTAssertEqual(state.targets(of: b.id), [.desktop, .lock])
        XCTAssertTrue(state.sameForBoth, "assigning to both makes the lock screen follow the desktop again")
    }

    func testScenesCanBeTheLockScreen() {
        let video = VideoItem(path: "/v.mp4"), other = VideoItem(path: "/w.mp4")
        let scene = VideoItem(path: "/s/scene.pkg", scene: SceneInfo(support: .partial))
        var state = LibraryState(videos: [video, other, scene], desktop: TargetConfig(selectedID: video.id))
        state.normalize()
        XCTAssertEqual(state.items(for: .lock).count, 3, "the service renders a scene into a lock screen loop")

        var both = state
        both.assign(scene.id, to: [.desktop, .lock])
        XCTAssertEqual(both.config(for: .lock).selectedID, scene.id)
        XCTAssertEqual(both.targets(of: scene.id), [.desktop, .lock])

        var lockOnly = state
        lockOnly.assign(scene.id, to: [.lock])
        XCTAssertEqual(lockOnly.config(for: .lock).selectedID, scene.id)
        XCTAssertEqual(lockOnly.config(for: .desktop).selectedID, video.id)
    }

    func testSceneFrameRateDefaultsClampsAndRoundTrips() throws {
        XCTAssertEqual(LibraryState().sceneFPS, 30)
        XCTAssertEqual(LibraryState(sceneFPS: 1000).sceneFPS, 120)
        XCTAssertEqual(LibraryState(sceneFPS: 1).sceneFPS, 10)
        let back = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(LibraryState(sceneFPS: 45)))
        XCTAssertEqual(back.sceneFPS, 45)
        let old = try decode(#"{"schema":2,"revision":1,"videos":[],"sameForBoth":true}"#)
        XCTAssertEqual(old.sceneFPS, 30, "a state.json from before the setting exists defaults to 30")
    }

    func testSameForBothMirrorsEverythingButEnabled() {
        let a = VideoItem(path: "/a.mp4")
        var state = LibraryState(videos: [a], desktop: TargetConfig(selectedID: a.id, intervalValue: 9),
                                 lock: TargetConfig(enabled: false))
        state.normalize()
        XCTAssertEqual(state.lock.selectedID, a.id)
        XCTAssertEqual(state.lock.intervalValue, 9)
        XCTAssertFalse(state.lock.enabled)
        XCTAssertTrue(state.canStart)
        state.selectedID = nil   // phase-2 accessor writes both while sameForBoth
        XCTAssertNil(state.lock.selectedID)
    }

    func testPlaylistFiltersMissingIDs() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        let state = LibraryState(videos: [a, b], desktop: TargetConfig(playlist: [b.id, UUID()]))
        XCTAssertEqual(state.items(for: .desktop).map(\.id), [b.id])
        XCTAssertFalse(state.hasMultipleItems(.desktop))
    }

    func testSavedPlaylistApplySaveDelete() throws {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4"), c = VideoItem(path: "/c.mp4")
        var state = LibraryState(videos: [a, b, c], desktop: TargetConfig(selectedID: a.id))
        let list = SavedPlaylist(name: "Mix", itemIDs: [c.id, b.id, UUID()])
        state.savePlaylist(list)
        XCTAssertEqual(state.playlists.first?.itemIDs, [c.id, b.id], "unknown ids dropped")

        state.applyPlaylist(list.id, to: [.lock])         // one target separates it from the other
        XCTAssertFalse(state.sameForBoth)
        XCTAssertEqual(state.items(for: .lock).map(\.id), [c.id, b.id])
        XCTAssertEqual(state.lock.selectedID, c.id, "selection moves into the playlist")
        XCTAssertNil(state.desktop.playlistID)

        state.savePlaylist(SavedPlaylist(id: list.id, name: "Mix", itemIDs: [b.id]))   // edit follows the screen
        XCTAssertEqual(state.items(for: .lock).map(\.id), [b.id])

        state.applyPlaylist(list.id, to: [.desktop, .lock])
        XCTAssertTrue(state.sameForBoth)
        XCTAssertEqual(state.items(for: .desktop).map(\.id), [b.id])

        state.deletePlaylist(list.id)
        XCTAssertTrue(state.playlists.isEmpty)
        XCTAssertNil(state.desktop.playlist)
        XCTAssertEqual(state.items(for: .lock).count, 3)

        // playlists + playlistID survive the file
        state.savePlaylist(list); state.applyPlaylist(list.id, to: [.desktop, .lock])
        let round = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(round.playlists, state.playlists)
        XCTAssertEqual(round.desktop.playlistID, list.id)
    }

    func testPlaylistRulesFollowThePlaylist() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var state = LibraryState(videos: [a, b])
        var list = SavedPlaylist(name: "Mix", itemIDs: [a.id, b.id],
                                 rules: PlaylistRules(shuffle: true, rotateEnabled: true, intervalValue: 7,
                                                      intervalUnit: .hours, changeOnWake: true))
        state.savePlaylist(list)
        state.applyPlaylist(list.id, to: [.desktop, .lock])
        XCTAssertTrue(state.shuffles(.desktop))
        XCTAssertTrue(state.rotates(.lock))
        XCTAssertTrue(state.advancesOnWake(.desktop))
        XCTAssertEqual(state.desktop.intervalValue, 7)
        XCTAssertEqual(state.desktop.intervalUnit, .hours)

        list.rules.shuffle = false                       // editing the playlist reaches the screen
        list.rules.intervalValue = 2
        state.savePlaylist(list)
        XCTAssertFalse(state.shuffles(.desktop))
        XCTAssertEqual(state.lock.intervalValue, 2)

        state.applyPlaylist(nil, to: [.desktop, .lock])  // the whole library: no shuffle, no rotation
        XCTAssertFalse(state.shuffles(.desktop))
        XCTAssertFalse(state.rotates(.desktop))
    }

    func testOlderStateFilesDecode() throws {
        let a = UUID(), b = UUID()
        // v7.0.0: playlists without rules, targets without shuffle / changeOnWake.
        let v7 = """
        {"schema":2,"revision":4,"videos":[],"sameForBoth":true,
         "desktop":{"enabled":true,"intervalValue":5,"intervalUnit":"minutes","rotateEnabled":false,"playlistID":"\(a.uuidString)"},
         "lock":{"enabled":true,"intervalValue":5,"intervalUnit":"minutes","rotateEnabled":false},
         "playlists":[{"id":"\(a.uuidString)","name":"Mix","itemIDs":["\(b.uuidString)"]}]}
        """
        let decoded = try JSONDecoder().decode(LibraryState.self, from: Data(v7.utf8))
        XCTAssertEqual(decoded.playlists.first?.name, "Mix")
        XCTAssertEqual(decoded.playlists.first?.rules, PlaylistRules())
        XCTAssertFalse(decoded.desktop.shuffle)

        // v6: a curated list with no name becomes a saved playlist carrying that screen's rotation settings.
        let v6 = """
        {"schema":2,"revision":1,"videos":[],"sameForBoth":true,
         "desktop":{"enabled":true,"intervalValue":9,"intervalUnit":"seconds","rotateEnabled":true,"playlist":["\(b.uuidString)"]},
         "lock":{"enabled":true,"intervalValue":5,"intervalUnit":"minutes","rotateEnabled":false}}
        """
        let migrated = try JSONDecoder().decode(LibraryState.self, from: Data(v6.utf8))
        XCTAssertEqual(migrated.playlists.count, 1)
        XCTAssertEqual(migrated.desktop.playlistID, migrated.playlists.first?.id)
        XCTAssertEqual(migrated.playlists.first?.rules.intervalValue, 9)
        XCTAssertEqual(migrated.lock.playlistID, migrated.desktop.playlistID, "lock mirrors the desktop")
    }

    func testLockRenderCacheValidity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pkg = folder.appendingPathComponent("scene.pkg")
        try Data("pkg".utf8).write(to: pkg)
        let item = VideoItem(path: pkg.path, workshopID: "9", scene: SceneInfo(support: .full))
        XCTAssertFalse(LockRenderCache.isValid(for: item, width: 3024, height: 1964))
        try Data("mov".utf8).write(to: LockRenderCache.videoURL(for: item, width: 3024, height: 1964))
        XCTAssertFalse(LockRenderCache.isValid(for: item, width: 3024, height: 1964), "no metadata yet")
        let meta = LockRenderCache.Meta(width: 3024, height: 1964, fps: 30, loopSeconds: 20,
                                        sourceStamp: LockRenderCache.sourceStamp(for: item))
        try LockRenderCache.writeMeta(meta, for: item)
        XCTAssertTrue(LockRenderCache.isValid(for: item, width: 3024, height: 1964))
        XCTAssertFalse(LockRenderCache.isValid(for: item, width: 1920, height: 1080), "other size")
        var stale = meta
        stale.engineRevision = LockRenderCache.engineRevision + 1
        try LockRenderCache.writeMeta(stale, for: item)
        XCTAssertFalse(LockRenderCache.isValid(for: item, width: 3024, height: 1964), "engine revision changed")
        LockRenderCache.removeStale(for: item, keepingWidth: 1920, height: 1080)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LockRenderCache.videoURL(for: item, width: 3024, height: 1964).path))
    }
}
