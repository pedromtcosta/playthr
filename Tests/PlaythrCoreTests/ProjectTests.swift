import XCTest
@testable import PlaythrCore

final class ProjectTests: XCTestCase {
    func testAudioOffsetPreservesVideoAndClampsAudioToClip() throws {
        var take = Take(name: "Harmony", file: "Media/take.mov", start: 12, duration: 4)
        take.sourceDuration = 8; take.sourceIn = 2; take.audioOffset = -0.1
        let audio = try XCTUnwrap(ClipSegment(take: take, audio: true))
        XCTAssertEqual(audio.timelineStart, 12)
        XCTAssertEqual(audio.sourceStart, 2.1, accuracy: 0.0001)
        XCTAssertEqual(audio.duration, 3.9, accuracy: 0.0001)
        XCTAssertEqual(ClipSegment(take: take, audio: false)?.duration, 4)
        take.audioOffset = 0.2
        XCTAssertEqual(ClipSegment(take: take, audio: true)?.timelineStart, 12.2)
    }

    func testSoloAndMuteApplyToBothBackingAndTakes() {
        var project = Project()
        project.tracks = [BackingTrack(name: "Drums", file: "Media/drums.wav", duration: 10)]
        var take = Take(name: "Lead", file: "Media/lead.mov", start: 2, duration: 4)
        take.solo = true; project.takes = [take]
        XCTAssertEqual(project.gain(volume: 1, muted: false, solo: false), 0)
        XCTAssertEqual(project.gain(volume: 1, muted: true, solo: true), 0)
        XCTAssertEqual(project.gain(volume: 1, muted: false, solo: true), 0.8)
    }

    func testRejectsUnsafePathsAndInvalidTrim() throws {
        for path in ["../outside.mov", "/tmp/file.mov", "Media/../file.mov", "Media/", "Media/..", "Media/a/b.mov"] {
            XCTAssertThrowsError(try validateMediaPath(path))
        }
        var project = Project()
        var take = Take(name: "Lead", file: "Media/a.mov", start: 0, duration: 3)
        take.sourceIn = 1; project.takes = [take]
        XCTAssertThrowsError(try project.validate())
    }

    func testPortableProjectRoundTripAndMissingMediaError() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Song.playthr"), name: "Song")
        let media = try store.mediaURL("Media/test.wav")
        try Data([0, 1, 2]).write(to: media)
        var project = Project(name: "Song")
        project.tracks = [BackingTrack(name: "Drums", file: "Media/test.wav", duration: 10)]
        try store.save(project)
        XCTAssertEqual(try store.load(), project)
        let moved = parent.appendingPathComponent("Moved.playthr")
        try FileManager.default.moveItem(at: store.root, to: moved)
        let relocated = ProjectStore(root: moved)
        XCTAssertEqual(try relocated.load(), project)
        try FileManager.default.removeItem(at: relocated.mediaURL("Media/test.wav"))
        XCTAssertThrowsError(try relocated.load())
    }

    func testSoundRazorUsesSplitPartsAndLabelsWithoutDoublingGuitar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stems = root.appendingPathComponent("stems")
        try FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)
        for name in ["guitar", "lead", "rhythm", "drums"] { try Data().write(to: stems.appendingPathComponent(name + ".wav")) }
        try Data(#"{"lead_rhythm_split":{"model":"listra92"}}"#.utf8).write(to: stems.appendingPathComponent("separation.json"))
        try Data(#"{"title":"My song"}"#.utf8).write(to: root.appendingPathComponent("metadata.json"))
        let result = try SoundRazorImport.inspect(root)
        XCTAssertEqual(result.title, "My song")
        XCTAssertEqual(try SoundRazorImport.inspect(stems).title, "My song")
        XCTAssertEqual(Set(result.stems.map(\.name)), Set(["Lead", "Rhythm", "Drums"]))
        try Data().write(to: stems.appendingPathComponent("guitar-target-1.wav"))
        try Data(#"{"guitar_split":[{"title":"Harmony"}]}"#.utf8).write(to: stems.appendingPathComponent("separation.json"))
        let targets = try SoundRazorImport.inspect(root)
        XCTAssertTrue(targets.stems.contains { $0.name == "Harmony" })
        XCTAssertFalse(targets.stems.contains { $0.url.lastPathComponent == "guitar.wav" })
    }

    func testLayoutsAndTimelineSupportOverlappingTakes() throws {
        var project = Project()
        project.takes = [Take(name: "One", file: "Media/a.mov", start: 10, duration: 5),
                         Take(name: "Two", file: "Media/b.mov", start: 12, duration: 4)]
        try project.validate()
        XCTAssertEqual(project.duration, 16)
        for count in 1...12 {
            for layout in VideoLayout.allCases {
                let placements = layout.placements(count: count)
                XCTAssertEqual(placements.count, count)
                XCTAssertTrue(placements.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 1.001 && $0.y + $0.height <= 1.001 })
            }
        }
    }
}
