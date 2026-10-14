import XCTest
import Darwin
@testable import PlaythrCore

final class SecurityTests: XCTestCase {
    private func withProject(_ action: (ProjectStore, URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrSecurity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Session.playthr"), name: "Security test")
        try action(store, parent)
    }

    func testRejectsLinkedMediaDirectoryEvenInEmptyProject() throws {
        try withProject { store, parent in
            let outside = parent.appendingPathComponent("Private")
            try FileManager.default.moveItem(at: store.mediaDirectory, to: outside)
            try FileManager.default.createSymbolicLink(at: store.mediaDirectory, withDestinationURL: outside)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.unregisteredMovies(in: Project()))
            XCTAssertThrowsError(try store.newTakePath())
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    func testRecoverySkipsLinkedAndNonRegularMovies() throws {
        try withProject { store, parent in
            let outside = parent.appendingPathComponent("private.mov")
            try Data([1, 2, 3]).write(to: outside)
            let real = try store.mediaURL("Media/real.mov")
            try Data([4, 5, 6]).write(to: real)
            for (name, target) in [("linked.mov", outside), ("dangling.mov", parent.appendingPathComponent("missing.mov"))] {
                try FileManager.default.createSymbolicLink(at: store.mediaDirectory.appendingPathComponent(name), withDestinationURL: target)
            }
            try FileManager.default.createDirectory(at: store.mediaDirectory.appendingPathComponent("directory.mov"), withIntermediateDirectories: false)
            XCTAssertEqual(try store.unregisteredMovies(in: Project()).map(\.lastPathComponent), ["real.mov"])
            XCTAssertEqual(try Data(contentsOf: outside), Data([1, 2, 3]))
        }
    }

    func testRejectsLinkedManifestWithoutChangingItsTarget() throws {
        try withProject { store, parent in
            let outside = parent.appendingPathComponent("private.json")
            try FileManager.default.moveItem(at: store.manifest, to: outside)
            let original = try Data(contentsOf: outside)
            try FileManager.default.createSymbolicLink(at: store.manifest, withDestinationURL: outside)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(Project(name: "Edited")))
            XCTAssertEqual(try Data(contentsOf: outside), original)
        }
    }

    func testRejectsNULInMediaPaths() {
        XCTAssertThrowsError(try validateMediaPath("Media/take\u{0}.mov"))
    }

    func testRejectsSpecialFilesBeforeReading() throws {
        try withProject { store, _ in
            let fifo = store.mediaDirectory.appendingPathComponent("pipe.mov")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try store.mediaURL("Media/pipe.mov"))
            XCTAssertTrue(try store.unregisteredMovies(in: Project()).isEmpty)
            try FileManager.default.removeItem(at: store.manifest)
            XCTAssertEqual(mkfifo(store.manifest.path, 0o600), 0)
            XCTAssertThrowsError(try store.load())
        }
    }

    func testRejectsOversizedManifestBeforeDecoding() throws {
        try withProject { store, _ in
            let handle = try FileHandle(forWritingTo: store.manifest)
            try handle.truncate(atOffset: UInt64(ProjectStore.maximumManifestBytes + 1))
            try handle.close()
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertTrue(error.localizedDescription.contains("too large"))
            }
        }
    }

    func testCopyingSelectedSymlinkStoresIndependentMedia() throws {
        try withProject { store, parent in
            let original = parent.appendingPathComponent("original.wav")
            let link = parent.appendingPathComponent("selected.wav")
            try Data([1, 2, 3]).write(to: original)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let copied = try store.copyMedia(from: link)
            try FileManager.default.removeItem(at: original)
            XCTAssertEqual(try Data(contentsOf: store.mediaURL(copied)), Data([1, 2, 3]))
        }
    }

    func testSoundRazorRejectsLinkedAndOversizedMetadata() throws {
        try withProject { _, parent in
            let folder = parent.appendingPathComponent("Song")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data().write(to: folder.appendingPathComponent("guitar.wav"))
            let outside = parent.appendingPathComponent("private.json")
            try Data(#"{"title":"Private"}"#.utf8).write(to: outside)
            let metadata = folder.appendingPathComponent("metadata.json")
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
            XCTAssertThrowsError(try SoundRazorImport.inspect(folder))
            try FileManager.default.removeItem(at: metadata)
            try Data().write(to: metadata)
            let handle = try FileHandle(forWritingTo: metadata)
            try handle.truncate(atOffset: 1024 * 1024 + 1)
            try handle.close()
            XCTAssertThrowsError(try SoundRazorImport.inspect(folder)) { error in
                XCTAssertTrue(error.localizedDescription.contains("too large"))
            }
        }
    }

    func testRejectsUnboundedAndOverflowingTimelineValues() throws {
        var project = Project()
        for duration in [1e20, Double.greatestFiniteMagnitude] {
            project.tracks = [BackingTrack(name: "Untrusted", file: "Media/a.wav", duration: duration)]
            let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
            XCTAssertThrowsError(try decoded.validate())
        }
        project.tracks = []
        project.takes = [Take(name: "Overflow", file: "Media/a.mov", start: 1e308, duration: 1e308)]
        XCTAssertThrowsError(try project.validate())
        project.takes = [Take(name: "Layer overflow", file: "Media/a.mov", start: 0, duration: 1, layer: Int.max)]
        XCTAssertThrowsError(try project.validate())
        project.takes = []
        project.schemaVersion = 2
        var track = BackingTrack(name: "Far future", file: "Media/a.wav", duration: 1)
        track.regions = [TrackRegion(start: 1e20, sourceIn: 0, duration: 1)]
        project.tracks = [track]
        XCTAssertThrowsError(try project.validate())
    }
}
