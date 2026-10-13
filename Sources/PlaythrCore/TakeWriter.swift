import AVFoundation

/// All calls must run on the capture queue. Audio and video use the same capture clock.
public final class TakeWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    public let anchor: CMTime
    public private(set) var videoFrames = 0
    public private(set) var audioBuffers = 0
    public private(set) var droppedVideoFrames = 0
    public private(set) var droppedAudioBuffers = 0
    public private(set) var failure: Error?

    public init(url: URL, anchor: CMTime, width: Int, height: Int) throws {
        self.anchor = anchor
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000,
                                             AVVideoExpectedSourceFrameRateKey: 30,
                                             AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw PlaythrError.message("Cannot configure the recording encoders.") }
        writer.add(video); writer.add(audio)
        // Frequent movie fragments improve recoverability if the app or Mac stops unexpectedly.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard writer.startWriting() else { throw writer.error ?? PlaythrError.message("Cannot create the take file.") }
        writer.startSession(atSourceTime: anchor)
    }

    public func append(_ buffer: CMSampleBuffer, video isVideo: Bool) {
        guard failure == nil, CMSampleBufferDataIsReady(buffer) else { return }
        var sample = buffer
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if CMTimeCompare(pts, anchor) < 0 {
            // Trim a PCM buffer that crosses the punch-in point, instead of losing its first samples.
            guard !isVideo, let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
            let skip = Int(ceil(CMTimeSubtract(anchor, pts).seconds * asbd.mSampleRate))
            let count = CMSampleBufferGetNumSamples(sample)
            guard skip >= 0, skip < count else { return }
            var trimmed: CMSampleBuffer?
            let status = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                               sampleRange: CFRange(location: skip, length: count - skip), sampleBufferOut: &trimmed)
            guard status == noErr, let trimmed else { return }
            sample = trimmed
        }
        let input = isVideo ? video : audio
        guard input.isReadyForMoreMediaData else {
            if isVideo { droppedVideoFrames += 1 } else { droppedAudioBuffers += 1 }
            return
        }
        if input.append(sample) {
            if isVideo { videoFrames += 1 } else { audioBuffers += 1 }
        } else { failure = writer.error ?? PlaythrError.message("The recorder could not write media to disk.") }
    }

    /// Abandon a count-in before its capture anchor without creating an empty take.
    public func cancel() { writer.cancelWriting() }

    public func finish(at end: CMTime, completion: @escaping (Result<String?, Error>) -> Void) {
        guard writer.status == .writing else {
            completion(.failure(failure ?? writer.error ?? PlaythrError.message("The recording stopped before it could be finalized.")))
            return
        }
        guard videoFrames > 0, audioBuffers > 0 else {
            writer.cancelWriting()
            completion(.failure(PlaythrError.message("No complete take was captured. Check the camera and audio input, then record for at least a second.")))
            return
        }
        writer.endSession(atSourceTime: CMTimeMaximum(end, anchor))
        video.markAsFinished(); audio.markAsFinished()
        writer.finishWriting { [self] in
            if let failure = failure ?? writer.error { completion(.failure(failure)); return }
            guard writer.status == .completed else { completion(.failure(PlaythrError.message("The take could not be finalized."))); return }
            let warning = droppedVideoFrames + droppedAudioBuffers > 0
                ? "Saved with \(droppedVideoFrames) dropped video frames and \(droppedAudioBuffers) dropped audio buffers. Review this take before exporting."
                : nil
            completion(.success(warning))
        }
    }
}
