import XCTest
@testable import PlaythrCore

final class RangeEditingTests: XCTestCase {
    func testOneTrackCutLeavesGapAndOtherTracksUntouched() throws {
        var project = fixture()
        let original = project
        XCTAssertTrue(try project.cut(range(4, 6), trackID: project.tracks[0].id, closeGap: false))
        XCTAssertEqual(project.takes, original.takes)
        XCTAssertEqual(project.tracks.count, 1)
        XCTAssertEqual(project.tracks[0].id, original.tracks[0].id)
        XCTAssertEqual(project.tracks[0].file, original.tracks[0].file)
        assertParts(project.tracks[0].playbackRegions, [(0, 0, 4), (6, 6, 6)])
        XCTAssertEqual(project.duration, original.duration)
    }

    func testClosingGapAcrossAllTracksKeepsTheRemainingPartsAligned() throws {
        var project = fixture()
        let oldDuration = project.duration
        let oldTake = project.takes[0]
        try project.cut(range(4, 6), trackID: nil, closeGap: true)
        assertParts(project.tracks[0].playbackRegions, [(0, 0, 4), (4, 6, 6)])
        assertParts(project.takes[0].playbackRegions, [(2, 1, 2), (4, 5, 4)])
        assertParts(project.takes[1].playbackRegions, [(12, 0, 3)])
        XCTAssertEqual(project.duration, oldDuration - 2)
        XCTAssertEqual(project.takes[0].volume, oldTake.volume)
        XCTAssertEqual(project.takes[0].placement, oldTake.placement)
        XCTAssertEqual(project.takes[0].layer, oldTake.layer)
        XCTAssertEqual(project.takes[0].id, oldTake.id)
    }

    func testRepeatedCutsRetainTheCorrectOriginalSourcePositions() throws {
        var project = fixture()
        let id = project.tracks[0].id
        try project.cut(range(2, 4), trackID: id, closeGap: true)
        try project.cut(range(3, 5), trackID: id, closeGap: true)
        assertParts(project.tracks[0].playbackRegions, [(0, 0, 2), (2, 4, 1), (3, 7, 5)])
        try project.cut(range(0, 1), trackID: id, closeGap: false)
        assertParts(project.tracks[0].playbackRegions, [(1, 1, 1), (2, 4, 1), (3, 7, 5)])
        try project.validate()
    }

    func testCutSeamsDoNotRestartTheAudioTimingCorrection() throws {
        for offset in [0.1, -0.1] {
            var project = fixture()
            project.takes[0].audioOffset = offset
            let id = project.takes[0].id
            let unchanged = project.tracks
            try project.cut(range(4, 6), trackID: id, closeGap: true)
            XCTAssertEqual(project.tracks, unchanged)
            let take = project.takes[0]
            let right = try XCTUnwrap(take.playbackRegions.last)
            let video = try XCTUnwrap(ClipSegment(region: right, take: take, audio: false))
            let audio = try XCTUnwrap(ClipSegment(region: right, take: take, audio: true))
            XCTAssertEqual(video.timelineStart, 4)
            XCTAssertEqual(audio.timelineStart, 4, accuracy: 0.000001)
            XCTAssertEqual(audio.sourceStart, video.sourceStart - offset, accuracy: 0.000001)
            XCTAssertEqual(audio.duration, offset < 0 ? 3.9 : 4, accuracy: 0.000001)
        }
    }

    func testCuttingSilenceCanRippleLaterMaterialAndWholeCutsKeepEmptyTracks() throws {
        var project = fixture()
        let id = project.takes[1].id
        let before = project
        XCTAssertFalse(try project.cut(range(0, 1), trackID: id, closeGap: false))
        XCTAssertEqual(project, before)
        try project.cut(range(0, 1), trackID: id, closeGap: true)
        XCTAssertEqual(project.takes[1].start, 13)
        try project.cut(range(0, project.duration), trackID: nil, closeGap: false)
        XCTAssertEqual(project.duration, 0)
        XCTAssertEqual(project.tracks.count, 1)
        XCTAssertEqual(project.takes.count, 2)
        XCTAssertTrue(project.tracks[0].playbackRegions.isEmpty)
        XCTAssertTrue(project.takes.allSatisfy { $0.playbackRegions.isEmpty })
        try project.validate()
    }

    func testLegacyProjectsLoadAndCutProjectsRoundTripWithoutModifyingMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrCuts-\(UUID().uuidString).playthr")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore.create(at: root, name: "Cuts")
        let original = fixture()
        let files = original.tracks.map(\.file) + original.takes.map(\.file)
        for file in files { try Data([1, 2, 3]).write(to: store.mediaURL(file)) }
        try store.save(original)
        let legacyData = try Data(contentsOf: store.manifest)
        XCTAssertFalse(String(decoding: legacyData, as: UTF8.self).contains("regions"))
        var loaded = try store.load()
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.tracks[0].playbackRegions.count, 1)
        try loaded.cut(range(4, 6), trackID: nil, closeGap: true)
        try store.save(loaded)
        XCTAssertEqual(try store.load(), loaded)
        XCTAssertEqual(loaded.schemaVersion, 2)
        for file in files { XCTAssertEqual(try Data(contentsOf: store.mediaURL(file)), Data([1, 2, 3])) }
    }

    func testRejectsInvalidRangesAndOverlappingOrOutOfBoundsPieces() throws {
        XCTAssertNil(TimelineRange(start: 4, end: 2))
        XCTAssertNil(TimelineRange(start: 0, end: .infinity))
        var project = fixture()
        XCTAssertThrowsError(try project.cut(range(1, 2), trackID: UUID(), closeGap: false))
        project.schemaVersion = 2
        project.tracks[0].regions = [TrackRegion(start: 0, sourceIn: 0, duration: 5), TrackRegion(start: 4, sourceIn: 5, duration: 3)]
        XCTAssertThrowsError(try project.validate())
        project.tracks[0].regions = [TrackRegion(start: 0, sourceIn: 11, duration: 2)]
        XCTAssertThrowsError(try project.validate())
    }

    private func fixture() -> Project {
        var project = Project(name: "Range edits")
        project.tracks = [BackingTrack(name: "Backing", file: "Media/backing.wav", duration: 12)]
        var take = Take(name: "Guitar", file: "Media/guitar.mov", start: 2, duration: 8, layer: 3)
        take.sourceIn = 1; take.sourceDuration = 10; take.volume = 0.7
        take.placement = Placement(x: 0.5, width: 0.5)
        project.takes = [take, Take(name: "Later", file: "Media/later.mov", start: 14, duration: 3)]
        return project
    }

    private func range(_ start: Double, _ end: Double) -> TimelineRange { TimelineRange(start: start, end: end)! }
    private func assertParts(_ parts: [TrackRegion], _ expected: [(Double, Double, Double)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parts.count, expected.count, file: file, line: line)
        for (part, values) in zip(parts, expected) {
            XCTAssertEqual(part.start, values.0, accuracy: 0.000001, file: file, line: line)
            XCTAssertEqual(part.sourceIn, values.1, accuracy: 0.000001, file: file, line: line)
            XCTAssertEqual(part.duration, values.2, accuracy: 0.000001, file: file, line: line)
        }
    }
}
