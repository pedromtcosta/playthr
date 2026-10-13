import AppKit
import AVKit
import PlaythrCore

/// Development-only visual check. It never connects capture devices or requests media access.
@MainActor
enum SmokeTest {
    static func runIfRequested(model: SessionModel) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-smoke-output"), arguments.count > index + 1 else { return }
        let output = URL(fileURLWithPath: arguments[index + 1])
        if let projectIndex = arguments.firstIndex(of: "--ui-smoke-project"), arguments.count > projectIndex + 1 {
            model.openProject(url: URL(fileURLWithPath: arguments[projectIndex + 1]))
        }
        Task {
            let originalProject = model.project
            if arguments.contains("--ui-smoke-test-count-in") {
                do { try await CountInPlayer().smokeCheck(outputID: model.outputID) }
                catch { print("Count-in check failed: \(error)"); exit(8) }
            }
            if arguments.contains("--ui-smoke-test-delete") {
                do { try checkDeletion(model: model) }
                catch { print("Track deletion check failed: \(error)"); exit(7) }
            }
            if arguments.contains("--ui-smoke-test-cuts") {
                do { try await checkCuts(model: model) }
                catch { print("Range editing check failed: \(error)"); exit(9) }
            }
            for _ in 0..<200 {
                if !model.isBuilding && model.player.currentItem?.status == .readyToPlay { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            model.player.currentItem?.add(videoOutput)
            model.seek(1)
            await model.player.seek(to: CMTime(seconds: 1, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            model.selectedTrackID = model.project.takes.last?.id
            model.player.isMuted = true
            model.togglePlay()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            model.pause()
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            do {
                guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
                try data.write(to: output)
                print("UI smoke screenshot: \(output.path)")
                print("Cameras: \(model.cameras.count); audio inputs: \(model.audioInputs.count); playback outputs: \(model.audioOutputs.count)")
                let previews = descendants(view).compactMap { $0 as? AVPlayerView }
                print("Preview frames ready: \(previews.map(\.isReadyForDisplay))")
                print("Player status: \(String(describing: model.player.currentItem?.status)); error: \(String(describing: model.player.currentItem?.error)); time: \(model.player.currentTime().seconds)")
                if let item = model.player.currentItem, let composition = item.videoComposition {
                    let duration = try await item.asset.load(.duration)
                    let valid = try await composition.isValid(for: item.asset, timeRange: CMTimeRange(start: .zero, duration: duration), validationDelegate: VideoValidationLog())
                    print("Video composition valid: \(valid); duration: \(duration.seconds); frame timing track: \(composition.sourceTrackIDForFrameTiming)")
                    guard valid else { exit(6) }
                    let generator = AVAssetImageGenerator(asset: item.asset)
                    generator.videoComposition = composition
                    do { let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 60000)); print("Composition image decoded: \(frame.image.width) × \(frame.image.height)") }
                    catch { print("Composition image error: \(error)") }
                }
                for preview in previews { print("Preview view bounds: \(preview.bounds); video bounds: \(preview.videoBounds); hidden: \(preview.isHidden)") }
                if let buffer = videoOutput.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil) {
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    if let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                        let row = CVPixelBufferGetBytesPerRow(buffer)
                        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                        var sum = 0, count = 0
                        for y in stride(from: 0, to: height, by: 8) { for x in stride(from: 0, to: width, by: 8) {
                            let index = y * row + x * 4
                            sum += Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]); count += 3
                        } }
                        print("Decoded preview mean RGB: \(Double(sum) / Double(max(1, count)))")
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                } else { print("No decoded preview pixel buffer") }
                if model.player.currentItem?.videoComposition != nil && !previews.contains(where: \.isReadyForDisplay) { exit(6) }
                if let error = model.error { print("UI error: \(error)"); exit(4) }
                if arguments.contains("--ui-smoke-test-cuts") {
                    model.undo()
                    guard model.project == originalProject, try model.store?.load() == originalProject else {
                        print("Could not restore the smoke-test project after its final cut."); exit(9)
                    }
                }
                NSApp.terminate(nil)
            } catch { print(error); exit(5) }
        }
        #endif
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    #if DEBUG
    private static func checkCuts(model: SessionModel) async throws {
        guard let store = model.store, let backing = model.project.tracks.first, let take = model.project.takes.first else {
            throw PlaythrError.message("The range test needs a backing track and a recorded take.")
        }
        let original = model.project
        let start = min(1, original.duration / 4)
        let end = min(start + 0.5, original.duration / 2)
        model.cutAllTracks = true
        model.selectRange(from: end, to: start, trackID: backing.id)
        guard model.selectedTrackID == backing.id, !model.cutAllTracks,
              model.selectedRange == TimelineRange(start: start, end: end) else {
            throw PlaythrError.message("Selecting a range on a track did not choose that track or normalize a reverse drag.")
        }
        for target in [Optional(backing.id), Optional(take.id), nil] {
            for closeGap in [false, true] {
                model.selectedTrackID = target
                model.cutAllTracks = target == nil
                model.selectRange(from: start, to: end)
                model.cutSelection(closeGap: closeGap)
                let cut = model.project
                guard model.error == nil, cut != original, try store.load() == cut else {
                    throw PlaythrError.message("Cut or autosave failed.")
                }
                for _ in 0..<200 {
                    if !model.isBuilding { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard !model.isBuilding, model.error == nil, let item = model.player.currentItem, let video = item.videoComposition else {
                    throw PlaythrError.message("The preview did not rebuild after cutting.")
                }
                let generator = AVAssetImageGenerator(asset: item.asset)
                generator.videoComposition = video
                _ = try await generator.image(at: CompositionBuilder.time(end + 0.2))
                model.undo()
                guard model.project == original, try store.load() == original else { throw PlaythrError.message("Cut undo failed.") }
                model.redo()
                guard model.project == cut, try store.load() == cut else { throw PlaythrError.message("Cut redo failed.") }
                model.undo()
                guard model.project == original else { throw PlaythrError.message("Cut restore failed.") }
            }
        }
        for file in original.tracks.map(\.file) + original.takes.map(\.file) {
            guard FileManager.default.fileExists(atPath: try store.mediaURL(file).path) else {
                throw PlaythrError.message("Cutting removed source media.")
            }
        }
        // Show the final cut and selected range in the screenshot, then the caller undoes it.
        model.selectedTrackID = take.id; model.cutAllTracks = true; model.isSelectingRange = true
        model.selectRange(from: start, to: end)
        model.cutSelection(closeGap: false)
        model.selectRange(from: start, to: end)
        print("Range edits verified: backing/take/all tracks × leave/close gap, saved edits, preview rebuilding, undo/redo, source preservation.")
    }

    /// Explicit opt-in for a disposable test project: exercises the same actions as
    /// the trash buttons, including persistence, linked take removal, and undo/redo.
    private static func checkDeletion(model: SessionModel) throws {
        guard let store = model.store else { throw PlaythrError.message("Open a test project first.") }
        let original = model.project
        let ids = original.tracks.map(\.id) + original.takes.map(\.id)
        let files = original.tracks.map(\.file) + original.takes.map(\.file)
        for id in ids {
            model.selectedTrackID = original.takes.first(where: { $0.id == id })?.id
            model.deleteTrack(id)
            let deleted = model.project
            guard !deleted.tracks.contains(where: { $0.id == id }), !deleted.takes.contains(where: { $0.id == id }),
                  deleted.tracks.count + deleted.takes.count == ids.count - 1,
                  model.selectedTrackID != id, try store.load() == deleted else {
                throw PlaythrError.message("Track removal or autosave failed.")
            }
            model.undo()
            guard model.project == original, try store.load() == original else { throw PlaythrError.message("Undo failed.") }
            model.redo()
            guard model.project == deleted, try store.load() == deleted else { throw PlaythrError.message("Redo failed.") }
            model.undo()
            guard model.project == original, try store.load() == original else { throw PlaythrError.message("Restore failed.") }
            for file in files {
                guard FileManager.default.fileExists(atPath: try store.mediaURL(file).path) else {
                    throw PlaythrError.message("Deleting a track removed its source file.")
                }
            }
        }
        print("Track deletion, autosave, undo/redo, and source preservation passed for \(ids.count) tracks.")
    }
    #endif
}

#if DEBUG
private final class VideoValidationLog: NSObject, AVVideoCompositionValidationHandling {
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
        print("Invalid video value: \(key)"); return true
    }
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
        print("Empty video range: \(timeRange)"); return true
    }
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn videoInstruction: AVVideoCompositionInstructionProtocol) -> Bool {
        print("Invalid video instruction range: \(videoInstruction.timeRange)"); return true
    }
    func videoComposition(_ videoComposition: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn videoInstruction: AVVideoCompositionInstructionProtocol, layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool {
        print("Invalid video track: \(layerInstruction.trackID); range: \(videoInstruction.timeRange)"); return true
    }
}
#endif
