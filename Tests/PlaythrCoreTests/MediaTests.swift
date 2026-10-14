import XCTest
import AVFoundation
import CoreGraphics
@testable import PlaythrCore

final class MediaTests: XCTestCase {
    /// Real codecs and rendered pixels catch gaps, layout order and lost audio that model tests cannot.
    func testRecordingAndOverlappingVideoExport() async throws {
        let retained = ProcessInfo.processInfo.environment["PLAYTHR_TEST_ARTIFACTS"]
        let parent = retained.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrTests-" + UUID().uuidString)
        defer { if retained == nil { try? FileManager.default.removeItem(at: parent) } }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Session.playthr"), name: "Test session")
        let first = try store.mediaURL("Media/red.mov")
        let second = try store.mediaURL("Media/blue.mov")
        try await makeTake(url: first, red: true)
        try await makeTake(url: second, red: false)
        let recordedDuration = try await Media.inspectTake(first)
        XCTAssertEqual(recordedDuration, 1.2, accuracy: 0.07)
        let analysis = try await Media.inspectAudio(first)
        XCTAssertGreaterThan(analysis.peaks.max() ?? 0, 0.15)
        var project = Project(name: "Export test")
        project.masterVolume = 0.5
        project.takes = [Take(name: "Red", file: "Media/red.mov", start: 0.4, duration: 1.1, layer: 0),
                         Take(name: "Blue", file: "Media/blue.mov", start: 0.8, duration: 1.1, layer: 1)]
        for index in project.takes.indices {
            project.takes[index].sourceDuration = recordedDuration
            project.takes[index].peaks = analysis.peaks
        }
        // Initial gap, single take, overlapping takes, second single take, then a trailing audio-only area.
        let backing = try await makeBacking(url: store.mediaURL("Media/backing.wav"))
        project.tracks = [backing]
        project.tracks[0].peaks = (try await Media.inspectAudio(store.mediaURL(backing.file))).peaks
        try store.save(project)
        let built = try await CompositionBuilder.build(project: project, store: store)
        XCTAssertEqual(built.composition.duration.seconds, 2.4, accuracy: 0.02)
        let export = parent.appendingPathComponent("grid.mp4")
        do { try await CompositionBuilder.export(built, to: export) { _ in } }
        catch { throw PlaythrError.message("Grid export failed: \(error)") }
        let asset = AVURLAsset(url: export)
        let exportedDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(exportedDuration, 2.4, accuracy: 0.1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let initial = try generator.copyCGImage(at: CompositionBuilder.time(0.1), actualTime: nil)
        XCTAssertLessThan(pixel(initial, x: 0.5, y: 0.5).max() ?? 1, 0.08, "Initial gap must render black")
        let overlap = try generator.copyCGImage(at: CompositionBuilder.time(1.0), actualTime: nil)
        let left = pixel(overlap, x: 0.25, y: 0.5), right = pixel(overlap, x: 0.75, y: 0.5)
        XCTAssertGreaterThan(left[0], 0.8); XCTAssertLessThan(left[2], 0.1)
        XCTAssertGreaterThan(right[2], 0.8); XCTAssertLessThan(right[0], 0.1)
        let tail = try generator.copyCGImage(at: CompositionBuilder.time(2.1), actualTime: nil)
        XCTAssertLessThan(pixel(tail, x: 0.5, y: 0.5).max() ?? 1, 0.08, "Trailing audio-only section must render black")
        let mixed = try await Media.inspectAudio(export)
        XCTAssertGreaterThan(mixed.peaks.max() ?? 0, 0.15, "Backing and takes must survive export")

        project.layout = .pictureInPicture
        let pip = try await CompositionBuilder.build(project: project, store: store)
        let pipURL = parent.appendingPathComponent("pip.mp4")
        try await CompositionBuilder.export(pip, to: pipURL) { _ in }
        let pipGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: pipURL))
        let pipImage = try pipGenerator.copyCGImage(at: CompositionBuilder.time(1), actualTime: nil)
        XCTAssertGreaterThan(pixel(pipImage, x: 0.5, y: 0.5)[0], 0.8)
        XCTAssertGreaterThan(pixel(pipImage, x: 0.82, y: 0.8)[2], 0.8, "Upper layer should be the blue inset")

        let contents = try Data(contentsOf: export)
        do { try await CompositionBuilder.export(built, to: export) { _ in }; XCTFail("Must not overwrite an existing export") }
        catch { XCTAssertEqual(try Data(contentsOf: export), contents) }
    }

    func testRotatedVideoFitsItsRectangle() {
        let transform = CGAffineTransform(rotationAngle: .pi / 2)
        let rect = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let fitted = CompositionBuilder.fitTransform(size: CGSize(width: 1920, height: 1080), preferred: transform, into: rect)
        let result = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(fitted)
        XCTAssertEqual(result.midX, rect.midX, accuracy: 0.001)
        XCTAssertEqual(result.midY, rect.midY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(result.width, rect.width + 0.001)
        XCTAssertLessThanOrEqual(result.height, rect.height + 0.001)
    }

    func testCancellingCountInDiscardsPrerollAndLeavesNoEmptyTake() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrCountIn-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let countIn = try CountIn(bpm: 120, counts: 4)
        let writer = try TakeWriter(url: url, anchor: CompositionBuilder.time(100 + countIn.duration), width: 320, height: 180)
        for beat in 0..<countIn.counts {
            let time = 100 + Double(beat) * countIn.beatDuration
            writer.append(try audioSample(at: time, frames: 1600), video: false)
            writer.append(try videoSample(at: time, red: true), video: true)
        }
        XCTAssertEqual(writer.audioBuffers, 0)
        XCTAssertEqual(writer.videoFrames, 0)
        writer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // A subsequent recording can use the path without a dangling writer or movie.
        let next = try TakeWriter(url: url, anchor: CompositionBuilder.time(110), width: 320, height: 180)
        next.cancel()
    }

    func testVideoPlaybackCoversUnroundedBackingDuration() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrCameraTiming-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Session.playthr"), name: "Camera timing")
        let url = try store.mediaURL("Media/camera.mov")
        try await makeTake(url: url, red: true, videoDelay: 0.023333333)
        let duration = try await Media.inspectTake(url)
        var project = Project()
        project.takes = [Take(name: "Camera", file: "Media/camera.mov", start: 0.64008544, duration: duration)]
        // A 44.1 kHz sample boundary cannot always be represented at the timeline's
        // 60 kHz edit precision. Even a microsecond of uncovered audio rejects video playback.
        project.tracks = [try await makeBacking(url: store.mediaURL("Media/backing.wav"), sampleRate: 44100, count: 105841)]
        let built = try await CompositionBuilder.build(project: project, store: store)
        let video = try XCTUnwrap(built.videoComposition)
        let valid = try await video.isValid(for: built.composition, timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), validationDelegate: nil)
        XCTAssertTrue(valid)
        XCTAssertEqual(video.instructions.last?.timeRange.end, built.composition.duration)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = video
        let frame = try await generator.image(at: CompositionBuilder.time(1))
        XCTAssertGreaterThan(pixel(frame.image, x: 0.5, y: 0.5)[0], 0.8)
    }

    func testRangeCutsRenderTheCorrectVideoAndAudioInPreviewAndExport() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrCutExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Session.playthr"), name: "Cuts")
        let source = try store.mediaURL("Media/camera.mov")
        try await makeTake(url: source, red: true, switchColorAt: 0.6)
        let duration = try await Media.inspectTake(source)
        var original = Project()
        original.tracks = [try await makeBacking(url: store.mediaURL("Media/backing.wav"))]
        original.takes = [Take(name: "Guitar", file: "Media/camera.mov", start: 0.2, duration: duration)]
        let range = try XCTUnwrap(TimelineRange(start: 0.4, end: 0.8))

        for (name, onlyTake, closeGap) in [("one-track-gap", true, false), ("all-gap", false, false), ("all-ripple", false, true)] {
            var project = original
            try project.cut(range, trackID: onlyTake ? project.takes[0].id : nil, closeGap: closeGap)
            let built = try await CompositionBuilder.build(project: project, store: store)
            let video = try XCTUnwrap(built.videoComposition)
            let valid = try await video.isValid(for: built.composition, timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), validationDelegate: nil)
            XCTAssertTrue(valid, name)
            let preview = AVAssetImageGenerator(asset: built.composition)
            preview.videoComposition = video
            let atCut = try await preview.image(at: CompositionBuilder.time(0.6))
            if closeGap { XCTAssertGreaterThan(pixel(atCut.image, x: 0.5, y: 0.5)[2], 0.8, "After closing the gap, the later blue source must move left") }
            else { XCTAssertLessThan(pixel(atCut.image, x: 0.5, y: 0.5).max() ?? 1, 0.05, "Cut video must be absent") }

            let output = parent.appendingPathComponent(name + ".mp4")
            try await CompositionBuilder.export(built, to: output) { _ in }
            let asset = AVURLAsset(url: output)
            let outputDuration = try await asset.load(.duration).seconds
            XCTAssertEqual(outputDuration, closeGap ? 2.0 : 2.4, accuracy: 0.04)
            let exported = AVAssetImageGenerator(asset: asset)
            exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero
            let before = try await exported.image(at: CompositionBuilder.time(0.3))
            XCTAssertGreaterThan(pixel(before.image, x: 0.5, y: 0.5)[0], 0.8)
            let later = try await exported.image(at: CompositionBuilder.time(closeGap ? 0.6 : 1.0))
            XCTAssertGreaterThan(pixel(later.image, x: 0.5, y: 0.5)[2], 0.8, "Surviving source must remain blue")
            let atCutExport = try await exported.image(at: CompositionBuilder.time(0.6))
            if !closeGap { XCTAssertLessThan(pixel(atCutExport.image, x: 0.5, y: 0.5).max() ?? 1, 0.05) }

            let analysis = try await Media.inspectAudio(output)
            let start = Int(0.52 / analysis.duration * Double(analysis.peaks.count))
            let end = Int(0.68 / analysis.duration * Double(analysis.peaks.count))
            let peak = analysis.peaks[start..<end].max() ?? 0
            if !onlyTake && !closeGap { XCTAssertLessThan(peak, 0.003, "All-track cut must be silent") }
            else { XCTAssertGreaterThan(peak, 0.04, "Uncut or shifted audio must survive") }
            if onlyTake { XCTAssertLessThan(peak, 0.11, "Only the quieter backing should remain in the cut") }
        }
    }

    func testScenesRenderIndependentLayoutsVisibilityAndLayerOrderInPreviewAndExport() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrSceneExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Session.playthr"), name: "Scenes")
        try await makeTake(url: store.mediaURL("Media/red.mov"), red: true)
        try await makeTake(url: store.mediaURL("Media/blue.mov"), red: false)
        var project = Project()
        project.tracks = [try await makeBacking(url: store.mediaURL("Media/backing.wav"))]
        let red = Take(name: "Red", file: "Media/red.mov", start: 0.2, duration: 1.2, layer: 0)
        let blue = Take(name: "Blue", file: "Media/blue.mov", start: 0.2, duration: 1.2, layer: 1)
        try project.addTake(red); try project.addTake(blue)
        for (start, end, layout) in [(0.2, 0.5, VideoLayout.grid), (0.5, 0.8, .stacked), (0.8, 1.1, .pictureInPicture), (1.1, 1.4, .custom)] {
            let id = try project.createScene(in: XCTUnwrap(TimelineRange(start: start, end: end)))
            let index = try XCTUnwrap(project.scenes?.firstIndex { $0.id == id })
            project.scenes?[index].applyLayout(layout)
            if layout == .custom {
                project.scenes?[index].videos[0].visible = false
                project.scenes?[index].videos[1].placement = Placement(x: 0.15, y: 0.2, width: 0.25, height: 0.25)
            }
        }
        try store.save(project)
        XCTAssertEqual(try store.load(), project)
        let built = try await CompositionBuilder.build(project: project, store: store)
        let preview = AVAssetImageGenerator(asset: built.composition)
        preview.videoComposition = try XCTUnwrap(built.videoComposition)
        let output = parent.appendingPathComponent("scenes.mp4")
        try await CompositionBuilder.export(built, to: output) { _ in }
        let export = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for generator in [preview, export] {
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let grid = try await generator.image(at: CompositionBuilder.time(0.3)).image
            XCTAssertGreaterThan(pixel(grid, x: 0.25, y: 0.5)[0], 0.8)
            XCTAssertGreaterThan(pixel(grid, x: 0.75, y: 0.5)[2], 0.8)
            let stacked = try await generator.image(at: CompositionBuilder.time(0.6)).image
            XCTAssertGreaterThan(pixel(stacked, x: 0.5, y: 0.25)[0], 0.8)
            XCTAssertGreaterThan(pixel(stacked, x: 0.5, y: 0.75)[2], 0.8)
            let pip = try await generator.image(at: CompositionBuilder.time(0.9)).image
            XCTAssertGreaterThan(pixel(pip, x: 0.5, y: 0.5)[0], 0.8)
            XCTAssertGreaterThan(pixel(pip, x: 0.82, y: 0.8)[2], 0.8)
            let custom = try await generator.image(at: CompositionBuilder.time(1.2)).image
            XCTAssertGreaterThan(pixel(custom, x: 0.25, y: 0.3)[2], 0.8, "Arbitrary position and size must be rendered")
            XCTAssertLessThan(pixel(custom, x: 0.8, y: 0.8).max() ?? 1, 0.05, "Omitted red video must disappear only in its Scene")
        }
        let audio = try await Media.inspectAudio(output)
        let from = Int(1.15 / audio.duration * Double(audio.peaks.count))
        let to = Int(1.3 / audio.duration * Double(audio.peaks.count))
        XCTAssertGreaterThan(audio.peaks[from..<to].max() ?? 0, 0.25, "Hiding a video must keep both guitars audible")

        // A Scene can outlast one of its videos without stretching it or rearranging other videos.
        try project.createScene(in: XCTUnwrap(TimelineRange(start: 0.2, end: 1.4)))
        project.takes[1].duration = 0.7
        let fixed = try await CompositionBuilder.build(project: project, store: store)
        let fixedPreview = AVAssetImageGenerator(asset: fixed.composition); fixedPreview.videoComposition = fixed.videoComposition
        let afterBlue = try await fixedPreview.image(at: CompositionBuilder.time(1.1)).image
        XCTAssertGreaterThan(pixel(afterBlue, x: 0.25, y: 0.5)[0], 0.8)
        XCTAssertLessThan(pixel(afterBlue, x: 0.75, y: 0.5).max() ?? 1, 0.05)

        // Back-to-front ordering is scene-local even when rectangles overlap completely.
        let index = try XCTUnwrap(project.scenes?.firstIndex { $0.contains(0.6) })
        project.scenes?[index].applyLayout(.custom)
        project.scenes?[index].videos[0].placement = Placement()
        project.scenes?[index].videos[1].placement = Placement()
        project.scenes?[index].videos.reverse()
        let reordered = try await CompositionBuilder.build(project: project, store: store)
        let frontPreview = AVAssetImageGenerator(asset: reordered.composition); frontPreview.videoComposition = reordered.videoComposition
        let front = try await frontPreview.image(at: CompositionBuilder.time(0.6)).image
        XCTAssertGreaterThan(pixel(front, x: 0.5, y: 0.5)[0], 0.8, "Red moved to the front must cover blue")
    }

    func testDeletedScenesRenderBlackAndPreserveAudioInPreviewAndExport() async throws {
        let retained = ProcessInfo.processInfo.environment["PLAYTHR_TEST_ARTIFACTS"]
        let parent = (retained.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("PlaythrSceneDeletion-\(UUID().uuidString)")
        defer { if retained == nil { try? FileManager.default.removeItem(at: parent) } }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Session.playthr"), name: "Deleted Scenes")
        let source = try store.mediaURL("Media/red.mov")
        try await makeTake(url: source, red: true)
        let originalMedia = try Data(contentsOf: source)
        var project = Project()
        project.tracks = [try await makeBacking(url: store.mediaURL("Media/backing.wav"))]
        try project.addTake(Take(name: "Red", file: "Media/red.mov", start: 0, duration: 1.2, layer: 0))
        let middle = try project.createScene(in: XCTUnwrap(TimelineRange(start: 0.4, end: 0.8)))
        try project.deleteScene(middle)
        for deleteAll in [false, true] {
            if deleteAll { for scene in project.scenes ?? [] { try project.deleteScene(scene.id) } }
            try store.save(project)
            var loaded = try store.load(); loaded.enableScenes(); loaded.reconcileScenes()
            XCTAssertEqual(loaded, project, "Saving and reopening must preserve missing Scenes, including no Scenes")
            let built = try await CompositionBuilder.build(project: loaded, store: store)
            XCTAssertEqual(built.audioMix.inputParameters.count, 2, "Both backing and guitar audio must remain in the preview")
            XCTAssertEqual(built.composition.duration.seconds, 2.4, accuracy: 0.02)
            let preview = AVAssetImageGenerator(asset: built.composition)
            preview.videoComposition = try XCTUnwrap(built.videoComposition)
            let output = parent.appendingPathComponent(deleteAll ? "no-scenes.mp4" : "gap.mp4")
            try await CompositionBuilder.export(built, to: output) { _ in }
            let asset = AVURLAsset(url: output)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let videoTrack = try XCTUnwrap(videoTracks.first)
            let outputSize = try await videoTrack.load(.naturalSize)
            XCTAssertEqual(outputSize, CGSize(width: 1920, height: 1080))
            let videoRange = try await videoTrack.load(.timeRange)
            XCTAssertEqual(videoRange.end.seconds, 2.4, accuracy: 1.0 / 30, "Black video must last as long as the audio")
            if retained != nil { print("Scene deletion export: \(output.path)") }
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, 2.4, accuracy: 0.1)
            let export = AVAssetImageGenerator(asset: asset)
            for (label, generator) in [("preview", preview), ("export", export)] {
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                for time in [0.2, 0.6, 1.0, 2.0] {
                    let frame: CGImage
                    do { frame = try await generator.image(at: CompositionBuilder.time(time)).image }
                    catch { throw PlaythrError.message("Scene deletion \(label), all deleted: \(deleteAll), time \(time): \(error)") }
                    if deleteAll || time == 0.6 || time == 2.0 {
                        XCTAssertLessThan(pixel(frame, x: 0.5, y: 0.5).max() ?? 1, 0.05, "No Scene must render black even when footage exists")
                    } else {
                        XCTAssertGreaterThan(pixel(frame, x: 0.5, y: 0.5)[0], 0.8, "Neighboring Scenes must keep their picture")
                    }
                }
            }
            let audio = try await Media.inspectAudio(output)
            let from = Int(0.55 / audio.duration * Double(audio.peaks.count))
            let to = Int(0.65 / audio.duration * Double(audio.peaks.count))
            XCTAssertGreaterThan(audio.peaks[from..<to].max() ?? 0, 0.19, "The deleted Scene's range must still mix guitar and backing")
        }
        XCTAssertEqual(try Data(contentsOf: source), originalMedia)
    }

    func testSecurityRejectsBackgroundLinkedOutsideProject() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrBackground-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Session.playthr"), name: "Linked background")
        let outside = parent.appendingPathComponent("private.mov")
        try await makeTake(url: outside, red: true)
        try FileManager.default.createSymbolicLink(at: store.mediaDirectory.appendingPathComponent(".background-30fps.mov"), withDestinationURL: outside)
        var project = Project()
        project.tracks = [try await makeBacking(url: store.mediaURL("Media/backing.wav"))]
        project.enableScenes()
        do {
            _ = try await CompositionBuilder.build(project: project, store: store)
            XCTFail("A linked background must not expose a movie outside the project")
        } catch { }
    }

    func testSecurityRejectsExternalMediaReferences() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PlaythrReferences-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try ProjectStore.create(at: parent.appendingPathComponent("Session.playthr"), name: "Reference movie")
        let outside = parent.appendingPathComponent("private.mov")
        try await makeTake(url: outside, red: true)
        let reference = try store.mediaURL("Media/reference.mov")
        let movie = AVMovie(url: outside)
        try movie.writeHeader(to: reference, fileType: .mov, options: .truncateDestinationToMovieHeaderOnly)
        // This fixture is a real reference movie, readable with AVFoundation's default policy.
        let unrestricted = AVURLAsset(url: reference)
        let duration = try await unrestricted.load(.duration).seconds
        XCTAssertGreaterThan(duration, 1)
        let referenceTracks = try await unrestricted.load(.tracks)
        XCTAssertFalse(referenceTracks.isEmpty)
        for track in referenceTracks {
            let contained = try await track.load(.isSelfContained)
            XCTAssertFalse(contained, "The fixture must reference the separate source movie")
        }
        XCTAssertLessThan(try Data(contentsOf: reference).count, try Data(contentsOf: outside).count)
        do {
            _ = try await Media.inspectTake(reference)
            XCTFail("Inspection must reject media data stored outside the container")
        } catch { }
        do {
            _ = try await Media.inspectAudio(reference)
            XCTFail("Waveform analysis must reject external media references")
        } catch { }
        var project = Project()
        project.takes = [Take(name: "Reference", file: "Media/reference.mov", start: 0, duration: duration)]
        do {
            _ = try await CompositionBuilder.build(project: project, store: store)
            XCTFail("Preview and export must reject external media references")
        } catch { }
    }

    private func makeTake(url: URL, red: Bool, videoDelay: Double = 0, switchColorAt: Double? = nil) async throws {
        let anchor = CMTime(seconds: 100, preferredTimescale: 48000)
        let writer = try TakeWriter(url: url, anchor: anchor, width: 320, height: 180)
        // Audio crossing the capture anchor exercises sample-level punch-in trimming.
        writer.append(try audioSample(at: 99.99, frames: 960), video: false)
        for frame in 0..<36 {
            let timestamp = 100 + Double(frame) / 30
            if videoDelay == 0 || frame < 35 {
                let color = switchColorAt.map { Double(frame) / 30 < $0 ? red : !red } ?? red
                writer.append(try videoSample(at: timestamp + videoDelay, red: color), video: true)
            }
            writer.append(try audioSample(at: timestamp + (frame == 0 ? 0.01 : 0), frames: frame == 0 ? 1120 : 1600), video: false)
            try await Task.sleep(nanoseconds: 34_000_000)
        }
        XCTAssertNil(writer.failure)
        XCTAssertEqual(writer.droppedAudioBuffers, 0)
        XCTAssertEqual(writer.audioBuffers, 37)
        let warning = try await withCheckedThrowingContinuation { continuation in
            writer.finish(at: CMTime(seconds: 101.2, preferredTimescale: 48000)) { continuation.resume(with: $0) }
        }
        XCTAssertNil(warning)
    }

    private func videoSample(at time: Double, red: Bool) throws -> CMSampleBuffer {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optional), kCVReturnSuccess)
        let pixel = try XCTUnwrap(optional)
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<180 { for x in 0..<320 {
            let offset = y * rowBytes + x * 4
            base[offset] = red ? 0 : 255; base[offset + 1] = 0; base[offset + 2] = red ? 255 : 0; base[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func audioSample(at time: Double, frames: Int) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        let bytes = frames * 2 * MemoryLayout<Float>.size
        var data: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                        blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                        flags: 0, blockBufferOut: &data), noErr)
        let block = try XCTUnwrap(data)
        let values = (0..<(frames * 2)).map { Float(0.2 * sin(Double($0 / 2) * 2 * .pi * 440 / 48000)) }
        let status = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        XCTAssertEqual(status, noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sampleSize = 8
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                               formatDescription: format.formatDescription, sampleCount: frames,
                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func makeBacking(url: URL, sampleRate: Double = 48000, count: AVAudioFrameCount = 115200) async throws -> BackingTrack {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for channel in 0..<2 { for frame in 0..<Int(count) { buffer.floatChannelData![channel][frame] = Float(0.1 * sin(Double(frame) * 2 * .pi * 220 / sampleRate)) } }
        try file.write(from: buffer)
        return BackingTrack(name: "Backing", file: "Media/backing.wav", duration: Double(count) / sampleRate)
    }

    private func pixel(_ image: CGImage, x: Double, y: Double) -> [Double] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress!, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (Int(y * Double(image.height)) * image.width + Int(x * Double(image.width))) * 4
        return (0..<3).map { Double(bytes[offset + $0]) / 255 }
    }
}
