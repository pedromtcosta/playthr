import XCTest
@testable import PlaythrCore

final class SceneTests: XCTestCase {
    func testRecordingsOverlayScenesForAllSuggestedOverlapCases() throws {
        var base = Project()
        base.tracks = [BackingTrack(name: "Song", file: "Media/song.wav", duration: 300)]
        let first = take(0, 300, layer: 0)
        try base.addTake(first)
        assertRanges(base, [(0, 300)])
        let second = take(130, 185, layer: 1)
        try base.addTake(second)
        assertRanges(base, [(0, 130), (130, 185), (185, 300)])
        XCTAssertEqual(visible(base, at: 100), [first.id])
        XCTAssertEqual(visible(base, at: 150), [first.id, second.id])
        XCTAssertEqual(visible(base, at: 200), [first.id])

        for (start, end, expected) in [
            (140.0, 170.0, [(0.0, 130.0), (130, 140), (140, 170), (170, 185), (185, 300)]),
            (120.0, 200.0, [(0.0, 120.0), (120, 200), (200, 300)]),
            (170.0, 230.0, [(0.0, 130.0), (130, 170), (170, 230), (230, 300)]),
            (100.0, 150.0, [(0.0, 100.0), (100, 150), (150, 185), (185, 300)])
        ] {
            var project = base
            let third = take(start, end, layer: 2)
            try project.addTake(third)
            assertRanges(project, expected)
            XCTAssertEqual(visible(project, at: (start + end) / 2), [first.id, second.id, third.id])
            XCTAssertEqual(project.takes[0], first, "A Scene must never trim or move its media")
            XCTAssertEqual(project.takes[1], second)
            try project.validate()
        }
    }

    func testShrinkingAndExpandingPreservesNeighborLayoutsAndSceneIdentity() throws {
        var project = try fixture()
        let middle = try XCTUnwrap(project.scenes?[1].id)
        let left = try XCTUnwrap(project.scenes?[0].id)
        let right = try XCTUnwrap(project.scenes?[2].id)
        project.scenes?[1].applyLayout(.pictureInPicture)
        let videos = project.scenes?[1].videos
        try project.resizeScene(middle, to: range(135, 180))
        assertRanges(project, [(0, 135), (135, 180), (180, 300)])
        XCTAssertEqual(project.scenes?.map(\.id), [left, middle, right])
        XCTAssertEqual(project.scenes?[1].videos, videos)
        XCTAssertEqual(visible(project, at: 132), [project.takes[0].id], "Shrinking must not reveal the second camera in the neighboring Scene")
        XCTAssertEqual(visible(project, at: 183), [project.takes[0].id])
        try project.resizeScene(middle, to: range(120, 200))
        assertRanges(project, [(0, 120), (120, 200), (200, 300)])
        XCTAssertEqual(project.scenes?[1].videos, videos)
        try project.resizeScene(middle, to: range(0, 300))
        assertRanges(project, [(0, 300)])
        XCTAssertEqual(project.scenes?.first?.id, middle)
        try project.resizeScene(middle, to: range(100, 200))
        assertRanges(project, [(100, 200)])
        XCTAssertNil(project.scene(at: 50), "Shrinking without a neighbor leaves the released time without video")
        XCTAssertNil(project.scene(at: 250))
    }

    func testDeletingScenesPreservesMediaAndGapsThroughReloadAndReconciliation() throws {
        let base = try fixture()
        let scenes = try XCTUnwrap(base.scenes)
        for deleted in scenes {
            var project = base
            XCTAssertTrue(try project.deleteScene(deleted.id))
            XCTAssertFalse(try project.deleteScene(deleted.id))
            XCTAssertEqual(project.scenes, scenes.filter { $0.id != deleted.id })
            XCTAssertNil(project.scene(at: (deleted.start + deleted.end) / 2))
            XCTAssertEqual(project.takes, base.takes)
            XCTAssertEqual(project.tracks, base.tracks)
            XCTAssertEqual(project.duration, base.duration)
            var loaded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
            loaded.enableScenes(); loaded.reconcileScenes()
            XCTAssertEqual(loaded, project, "Opening or editing must preserve leading, middle, and trailing gaps")
            try loaded.validate()
        }
        var empty = base
        for scene in scenes { try empty.deleteScene(scene.id) }
        var loaded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(empty))
        loaded.enableScenes(); loaded.reconcileScenes()
        XCTAssertEqual(loaded, empty)
        XCTAssertEqual(loaded.scenes, [])
        XCTAssertFalse(loaded.takes.contains { loaded.showsVideo($0) })
        XCTAssertEqual(loaded.duration, 300)
        XCTAssertEqual(loaded.takes, base.takes)
        XCTAssertEqual(loaded.tracks, base.tracks)
        try loaded.validate()
    }

    func testSceneGapsSurviveBoundaryEditsNewScenesRecordingsAndRippleCuts() throws {
        var project = try fixture()
        let scenes = try XCTUnwrap(project.scenes)
        try project.deleteScene(scenes[1].id)
        try project.resizeScene(scenes[0].id, to: range(0, 120))
        try project.resizeScene(scenes[2].id, to: range(195, 300))
        assertRanges(project, [(0, 120), (195, 300)])
        try project.createScene(in: range(135, 170))
        assertRanges(project, [(0, 120), (135, 170), (195, 300)])
        try project.addTake(take(150, 180, layer: 2))
        assertRanges(project, [(0, 120), (135, 150), (150, 180), (195, 300)])
        project.tracks[0].volume = 0.4
        project.reconcileScenes()
        XCTAssertNil(project.scene(at: 125), "Unrelated edits must not fill deleted Scenes")
        XCTAssertNil(project.scene(at: 190))
        try project.cut(range(125, 155), trackID: nil, closeGap: true)
        assertRanges(project, [(0, 120), (125, 150), (165, 270)])
        XCTAssertNil(project.scene(at: 122))
        XCTAssertNil(project.scene(at: 160))
        try project.validate()
    }

    func testManualScenesKeepOutsideCustomLayoutsAndIndependentVisibility() throws {
        var project = try fixture()
        let takeID = project.takes[0].id
        let original = project.takes
        project.scenes?[1].name = "Solo"
        project.scenes?[1].applyLayout(.custom)
        project.scenes?[1].videos[0].placement = Placement(x: 0.15, y: 0.2, width: 0.4, height: 0.3)
        project.scenes?[1].videos[0].visible = false
        let retained = project.scenes?[1].videos
        try project.createScene(in: range(140, 170))
        assertRanges(project, [(0, 130), (130, 140), (140, 170), (170, 185), (185, 300)])
        XCTAssertEqual(project.scenes?[1].videos, retained)
        XCTAssertEqual(project.scenes?[3].videos, retained)
        XCTAssertNotEqual(project.scenes?[1].id, project.scenes?[3].id)
        XCTAssertFalse(visible(project, at: 135).contains(takeID))
        XCTAssertTrue(visible(project, at: 150).contains(takeID))
        XCTAssertEqual(project.takes, original)
        XCTAssertEqual(project.gain(volume: 1, muted: false, solo: false), 0.8)
        try project.validate()
    }

    func testRippleCutsMoveSceneBoundariesAndRetainTheirArrangements() throws {
        var project = try fixture()
        project.scenes?[1].applyLayout(.stacked)
        let middleID = project.scenes?[1].id
        let videos = project.scenes?[1].videos
        try project.cut(range(140, 160), trackID: nil, closeGap: true)
        assertRanges(project, [(0, 130), (130, 165), (165, 280)])
        XCTAssertEqual(project.scenes?[1].id, middleID)
        XCTAssertEqual(project.scenes?[1].videos, videos)
        try project.cut(range(125, 170), trackID: nil, closeGap: true)
        assertRanges(project, [(0, 125), (125, 235)])
        try project.cut(range(0, 235), trackID: nil, closeGap: false)
        XCTAssertEqual(project.scenes, [])
        XCTAssertEqual(project.duration, 0)
        XCTAssertEqual(project.schemaVersion, 3)
        try project.validate()
    }

    func testSingleTrackEditsKeepSceneTimingAndDeleteRemovesReferences() throws {
        var project = try fixture()
        let scenes = project.scenes
        try project.cut(range(140, 160), trackID: project.takes[1].id, closeGap: true)
        XCTAssertEqual(project.scenes, scenes)
        let deleted = project.takes.removeLast().id
        project.reconcileScenes()
        assertRanges(project, [(0, 130), (130, 185), (185, 300)])
        XCTAssertFalse(project.scenes!.contains { $0.videos.contains { $0.takeID == deleted } })
        project.takes.removeAll(); project.reconcileScenes()
        XCTAssertTrue(project.scenes!.allSatisfy { $0.videos.isEmpty })
        try project.validate()
    }

    func testLegacyMigrationPreservesLayoutAndRoundTrips() throws {
        var project = Project()
        var first = take(0, 300, layer: 0)
        first.placement = Placement(x: 0.1, y: 0.2, width: 0.4, height: 0.6)
        var second = take(130, 185, layer: 1); second.hidden = true
        project.takes = [first, second]; project.layout = .custom
        let legacy = try JSONEncoder().encode(project)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("scenes"))
        var loaded = try JSONDecoder().decode(Project.self, from: legacy)
        loaded.enableScenes()
        assertRanges(loaded, [(0, 130), (130, 185), (185, 300)])
        for scene in loaded.scenes! {
            XCTAssertEqual(scene.videos.first?.placement, first.placement)
            XCTAssertFalse(scene.videos.contains { $0.takeID == second.id && $0.visible })
        }
        let encoded = try JSONEncoder().encode(loaded)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: encoded), loaded)
        let snapshot = loaded; loaded.enableScenes(); XCTAssertEqual(snapshot, loaded, "Migration is idempotent")
        try loaded.validate()
    }

    func testSceneValidationRejectsOverlapMissingMediaAndNonfiniteGeometry() throws {
        let base = try fixture()
        var project = base; project.scenes?[1].start -= 1
        XCTAssertThrowsError(try project.validate())
        project = base; project.scenes?[1].videos.append(SceneVideo(takeID: UUID()))
        XCTAssertThrowsError(try project.validate())
        project = base; project.scenes?[1].videos[0].placement.x = .nan
        XCTAssertThrowsError(try project.validate())
        project = base; project.schemaVersion = 2
        XCTAssertThrowsError(try project.validate())
        project = base
        XCTAssertThrowsError(try project.createScene(in: range(290, 310)))
        XCTAssertEqual(project, base)
    }

    private func fixture() throws -> Project {
        var project = Project()
        project.tracks = [BackingTrack(name: "Song", file: "Media/song.wav", duration: 300)]
        try project.addTake(take(0, 300, layer: 0))
        try project.addTake(take(130, 185, layer: 1))
        return project
    }
    private func take(_ start: Double, _ end: Double, layer: Int) -> Take {
        Take(name: "Guitar \(layer + 1)", file: "Media/guitar-\(layer).mov", start: start, duration: end - start, layer: layer)
    }
    private func range(_ start: Double, _ end: Double) -> TimelineRange { TimelineRange(start: start, end: end)! }
    private func visible(_ project: Project, at time: Double) -> [UUID] { project.scene(at: time)?.videos.filter(\.visible).map(\.takeID) ?? [] }
    private func assertRanges(_ project: Project, _ expected: [(Double, Double)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(project.scenes?.count, expected.count, file: file, line: line)
        for (scene, interval) in zip(project.scenes ?? [], expected) {
            XCTAssertEqual(scene.start, interval.0, accuracy: 0.000001, file: file, line: line)
            XCTAssertEqual(scene.end, interval.1, accuracy: 0.000001, file: file, line: line)
        }
    }
}
