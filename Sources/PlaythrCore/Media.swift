@preconcurrency import AVFoundation

public enum Media {
    public static func inspectAudio(_ url: URL) async throws -> (duration: Double, peaks: [Float]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PlaythrError.message("\(url.lastPathComponent) does not contain readable audio.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PlaythrError.message("Invalid media duration.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? PlaythrError.message("Could not read audio.") }
        var peaks = [Float](repeating: 0, count: 1200)
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            let size = CMBlockBufferGetDataLength(data)
            var values = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard status == noErr, let description = CMSampleBufferGetFormatDescription(sample),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
            let channels = max(1, Int(format.mChannelsPerFrame))
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Decimation is only for the display waveform; original audio stays intact.
            for frame in stride(from: 0, to: values.count / channels, by: 32) {
                let index = min(peaks.count - 1, max(0, Int((time + Double(frame) / format.mSampleRate) / duration * Double(peaks.count))))
                for channel in 0..<channels { peaks[index] = max(peaks[index], min(1, abs(values[frame * channels + channel]))) }
            }
        }
        if reader.status == .failed { throw reader.error ?? PlaythrError.message("Could not decode audio.") }
        return (duration, peaks)
    }

    public static func inspectTake(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard !video.isEmpty, !audio.isEmpty, duration.isFinite, duration > 0 else {
            throw PlaythrError.message("This take does not contain both video and audio. Its original file was kept in Media.")
        }
        return duration
    }
}

public struct BuiltComposition {
    public let composition: AVMutableComposition
    public let audioMix: AVMutableAudioMix
    public let videoComposition: AVMutableVideoComposition?
    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        item.videoComposition = videoComposition
        return item
    }
}

public enum CompositionBuilder {
    private struct VideoSource {
        let take: Take
        let regions: [TrackRegion]
        let track: AVMutableCompositionTrack
        let size: CGSize
        let transform: CGAffineTransform
    }
    public static func build(project: Project, store: ProjectStore) async throws -> BuiltComposition {
        try project.validate()
        let composition = AVMutableComposition()
        var mixes: [AVMutableAudioMixInputParameters] = []
        var videos: [VideoSource] = []
        for backing in project.tracks {
            guard !backing.playbackRegions.isEmpty else { continue }
            let asset = AVURLAsset(url: try store.mediaURL(backing.file))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw PlaythrError.message("Cannot load backing track \(backing.name).")
            }
            if backing.regions == nil {
                let sourceRange = try await source.load(.timeRange)
                try destination.insertTimeRange(sourceRange, of: source, at: .zero)
            } else {
                for region in backing.playbackRegions {
                    try await insert(ClipSegment(region: region), source: source, destination: destination)
                }
            }
            let mix = AVMutableAudioMixInputParameters(track: destination)
            mix.setVolume(project.gain(volume: backing.volume, muted: backing.muted, solo: backing.solo), at: .zero)
            mixes.append(mix)
        }
        for take in project.takes {
            let regions = take.playbackRegions
            guard !regions.isEmpty else { continue }
            let asset = AVURLAsset(url: try store.mediaURL(take.file))
            let audioSegments = regions.compactMap { ClipSegment(region: $0, take: take, audio: true) }
            if !audioSegments.isEmpty {
                guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                      let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw PlaythrError.message("Cannot load audio for \(take.name).")
                }
                for segment in audioSegments { try await insert(segment, source: source, destination: destination) }
                let mix = AVMutableAudioMixInputParameters(track: destination)
                mix.setVolume(project.gain(volume: take.volume, muted: take.muted, solo: take.solo), at: .zero)
                mixes.append(mix)
            }
            if project.showsVideo(take) {
                guard let source = try await asset.loadTracks(withMediaType: .video).first,
                      let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw PlaythrError.message("Cannot load video for \(take.name).")
                }
                var visible: [TrackRegion] = []
                for region in regions {
                    if let segment = ClipSegment(region: region, take: take, audio: false),
                       try await insert(segment, source: source, destination: destination) { visible.append(region) }
                }
                let size = try await source.load(.naturalSize)
                let transform = try await source.load(.preferredTransform)
                if !visible.isEmpty { videos.append(VideoSource(take: take, regions: visible, track: destination, size: size, transform: transform)) }
            }
        }
        // Keep the media's exact duration. Rounding a 44.1 kHz backing track to our
        // edit timescale can leave a tiny uncovered tail that prevents video playback.
        let timelineDuration = CMTimeMaximum(composition.duration, time(project.duration))
        // Extend through muted/hidden material and any trailing silence.
        if CMTimeCompare(composition.duration, timelineDuration) < 0 {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: timelineDuration))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixes
        // Explicitly empty Scenes still export the full audio timeline with a black picture.
        guard !videos.isEmpty || (project.scenes != nil && project.duration > 0) else {
            return BuiltComposition(composition: composition, audioMix: mix, videoComposition: nil)
        }
        let canvas = CGSize(width: 1920, height: 1080)
        // A real, continuous black video source is required. Empty layer instructions alone
        // cannot reliably render the audio-only gaps before, between, or after camera takes.
        let backgroundURL = try await BlackBackground.ensure(in: store.mediaDirectory)
        let backgroundAsset = AVURLAsset(url: backgroundURL)
        guard let backgroundSource = try await backgroundAsset.loadTracks(withMediaType: .video).first,
              let backgroundTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PlaythrError.message("Cannot create the video background.")
        }
        let backgroundRange = try await backgroundSource.load(.timeRange)
        // Supply actual frames across the whole timeline. A stretched still can
        // preview correctly but export only its first few frames when no takes are visible.
        var backgroundCursor = CMTime.zero
        while CMTimeCompare(backgroundCursor, timelineDuration) < 0 {
            let remaining = CMTimeSubtract(timelineDuration, backgroundCursor)
            let length = CMTimeMinimum(backgroundRange.duration, remaining)
            try backgroundTrack.insertTimeRange(CMTimeRange(start: backgroundRange.start, duration: length), of: backgroundSource, at: backgroundCursor)
            backgroundCursor = CMTimeAdd(backgroundCursor, length)
        }
        let video = AVMutableVideoComposition()
        video.renderSize = canvas
        video.frameDuration = CMTime(value: 1, timescale: 30)
        var boundaries = [CMTime.zero, timelineDuration] +
            ((project.scenes ?? []).flatMap { [time($0.start), time($0.end)] } +
             videos.flatMap { $0.regions.flatMap { [time($0.start), time($0.end)] } })
            .filter { CMTimeCompare($0, .zero) > 0 && CMTimeCompare($0, timelineDuration) < 0 }
        boundaries.sort { CMTimeCompare($0, $1) < 0 }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where CMTimeCompare(end, start) > 0 {
            let midpoint = (start.seconds + end.seconds) / 2
            var active = videos.filter { $0.regions.contains { $0.start <= midpoint && $0.end > midpoint } }
                .sorted { $0.take.layer == $1.take.layer ? $0.take.id.uuidString < $1.take.id.uuidString : $0.take.layer < $1.take.layer }
            var positions: [Placement]
            if project.scenes != nil {
                let sceneVideos = project.scene(at: midpoint)?.videos.filter(\.visible) ?? []
                let sources = Dictionary(uniqueKeysWithValues: active.map { ($0.take.id, $0) })
                active = sceneVideos.compactMap { sources[$0.takeID] }
                positions = sceneVideos.filter { sources[$0.takeID] != nil }.map(\.placement)
            } else {
                positions = project.layout == .custom ? active.map { $0.take.placement } : project.layout.placements(count: active.count)
            }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: start, end: end)
            instruction.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            let foregrounds: [AVMutableVideoCompositionLayerInstruction] = active.enumerated().map { index, source in
                let placement = positions[index]
                let rect = CGRect(x: placement.x * canvas.width, y: placement.y * canvas.height,
                                  width: placement.width * canvas.width, height: placement.height * canvas.height)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: source.track)
                layer.setTransform(fitTransform(size: source.size, preferred: source.transform, into: rect), at: start)
                return layer
            }
            let backgroundLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: backgroundTrack)
            backgroundLayer.setTransform(CGAffineTransform(scaleX: 60, y: 60), at: .zero)
            instruction.layerInstructions = Array(foregrounds.reversed()) + [backgroundLayer]
            instructions.append(instruction)
        }
        video.instructions = instructions
        guard try await video.isValid(for: composition, timeRange: CMTimeRange(start: .zero, duration: composition.duration), validationDelegate: nil) else {
            throw PlaythrError.message("Could not prepare a valid video timeline. Your recorded files are still saved in the project.")
        }
        return BuiltComposition(composition: composition, audioMix: mix, videoComposition: video)
    }

    @discardableResult
    private static func insert(_ segment: ClipSegment, source: AVAssetTrack, destination: AVMutableCompositionTrack) async throws -> Bool {
        let available = try await source.load(.timeRange)
        let requested = CMTimeRange(start: time(segment.sourceStart), duration: time(segment.duration))
        let range = CMTimeRangeGetIntersection(available, otherRange: requested)
        // A tiny surviving piece can fall before the first camera frame or after the last one.
        guard range.duration.seconds > 0 else { return false }
        let gap = range.start.seconds - segment.sourceStart
        try destination.insertTimeRange(range, of: source, at: time(segment.timelineStart + gap))
        return true
    }

    public static func fitTransform(size: CGSize, preferred: CGAffineTransform, into rect: CGRect) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: size).applying(preferred)
        let scale = min(rect.width / oriented.width, rect.height / oriented.height)
        return preferred.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.minX + (rect.width - oriented.width * scale) / 2,
                                           y: rect.minY + (rect.height - oriented.height * scale) / 2))
    }
    public static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60000) }

    public static func export(_ built: BuiltComposition, to url: URL, progress: @escaping (Float) -> Void) async throws {
        guard built.videoComposition != nil else { throw PlaythrError.message("Add media to the timeline before exporting video.") }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PlaythrError.message("Choose a new export filename; an existing file will not be overwritten.") }
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPreset1920x1080) else {
            throw PlaythrError.message("The video exporter is unavailable.")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".playthr-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        session.outputURL = temporary
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.audioMix = built.audioMix
        session.videoComposition = built.videoComposition
        let monitor = Task {
            while !Task.isCancelled { progress(session.progress); try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        defer { monitor.cancel() }
        let cancellation = ExportCancellation(session)
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: { cancellation.cancel() }
        guard session.status == .completed else { throw session.error ?? PlaythrError.message("Export was cancelled.") }
        try FileManager.default.moveItem(at: temporary, to: url)
        progress(1)
    }
}

/// AVAssetExportSession explicitly supports cancellation while its asynchronous export runs.
private final class ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

private enum BlackBackground {
    static func ensure(in directory: URL) async throws -> URL {
        // Use a new cache name so older two-frame backgrounds are not reused.
        let url = directory.appendingPathComponent(".background-30fps.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let temporary = directory.appendingPathComponent(".background-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 18])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 18,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PlaythrError.message("Cannot prepare black background.") }
        writer.startSession(atSourceTime: .zero)
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 32, 18, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optional)
        guard status == kCVReturnSuccess, let pixel = optional else { throw PlaythrError.message("Cannot allocate background frame.") }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) { memset(address, 0, CVPixelBufferGetBytesPerRow(pixel) * 18) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for index in 0..<30 {
            var attempts = 0
            while !input.isReadyForMoreMediaData && attempts < 200 {
                try await Task.sleep(nanoseconds: 10_000_000); attempts += 1
            }
            guard input.isReadyForMoreMediaData, adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? PlaythrError.message("Cannot encode background frame.")
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? PlaythrError.message("Cannot finalize background frame.") }
        do { try FileManager.default.moveItem(at: temporary, to: url) }
        catch { if !FileManager.default.fileExists(atPath: url.path) { throw error } }
        return url
    }
}
