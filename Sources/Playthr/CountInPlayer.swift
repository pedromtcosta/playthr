import AVFoundation
import PlaythrCore

/// A separate output-only engine keeps the clicks out of the take and export mix.
@MainActor
final class CountInPlayer {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?

    func prepare(_ countIn: CountIn, outputID: String) throws {
        stop()
        guard let buffer = try countIn.makeBuffer() else { return }
        guard let device = Devices.outputDeviceID(uniqueID: outputID) else {
            throw PlaythrError.message("The count-in output is unavailable. Select a Playback output and try again.")
        }
        let engine = AVAudioEngine()
        try engine.outputNode.auAudioUnit.setDeviceID(device)
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PlaythrError.message("The selected Playback output cannot play the count-in.")
        }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        node.scheduleBuffer(buffer)
        node.prepare(withFrameCount: min(buffer.frameLength, 4096))
        engine.prepare()
        try engine.start()
        self.engine = engine; self.node = node
    }

    /// The caller uses the same host clock for the capture anchor and backing playback.
    func start(at hostTime: CMTime) throws {
        guard let engine, let node else { return } // Zero counts means no click output.
        let renderTime = CMTimeSubtract(hostTime, CompositionBuilder.time(node.outputPresentationLatency))
        guard engine.isRunning, CMTimeSubtract(renderTime, CMClockGetTime(CMClockGetHostTimeClock())).seconds > 0.02 else {
            throw PlaythrError.message("The count-in could not start on time. Press Record to try again.")
        }
        node.play(at: AVAudioTime(hostTime: CMClockConvertHostTimeToSystemUnits(renderTime)))
    }

    func stop() {
        node?.stop()
        engine?.stop()
        node = nil; engine = nil
    }

    #if DEBUG
    /// Opt-in hardware-output check. It never opens a camera or audio input.
    func smokeCheck(outputID: String) async throws {
        defer { stop() }
        let countIn = try CountIn(bpm: 120, counts: 4)
        try prepare(countIn, outputID: outputID)
        guard let engine, let node, engine.outputNode.auAudioUnit.deviceID == Devices.outputDeviceID(uniqueID: outputID) else {
            throw PlaythrError.message("The metronome did not use the selected playback device.")
        }
        let probe = CountInClickProbe()
        let latency = node.outputPresentationLatency
        node.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in probe.append(buffer, at: time) }
        let firstBeat = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CompositionBuilder.time(0.5))
        try start(at: firstBeat)
        try await Task.sleep(nanoseconds: 2_800_000_000)
        node.removeTap(onBus: 0)
        let onsets = probe.onsets
        guard onsets.count == 4 else { throw PlaythrError.message("Expected four rendered clicks; received \(onsets.count).") }
        for (index, onset) in onsets.enumerated() {
            let expected = firstBeat.seconds + Double(index) * 0.5
            guard abs(onset + latency - expected) < 0.03 else {
                throw PlaythrError.message("The rendered metronome click missed its scheduled beat.")
            }
        }
        stop()
        guard !node.isPlaying, !engine.isRunning else { throw PlaythrError.message("The metronome did not stop.") }

        try prepare(countIn, outputID: outputID)
        guard let cancelledNode = self.node, let cancelledEngine = self.engine else { throw PlaythrError.message("Could not rearm the metronome.") }
        let cancelledProbe = CountInClickProbe()
        cancelledNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in cancelledProbe.append(buffer, at: time) }
        try start(at: CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CompositionBuilder.time(0.5)))
        try await Task.sleep(nanoseconds: 750_000_000)
        stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        cancelledNode.removeTap(onBus: 0)
        guard !cancelledNode.isPlaying, !cancelledEngine.isRunning, cancelledProbe.onsets.count == 1 else {
            throw PlaythrError.message("Cancelling the count-in did not silence the remaining clicks.")
        }
        try prepare(CountIn(bpm: 120, counts: 0), outputID: outputID)
        guard self.node == nil, self.engine == nil else { throw PlaythrError.message("Zero counts should not start audio output.") }
        print("Metronome output verified: four clicks at 120 BPM, selected device \(engine.outputNode.auAudioUnit.deviceID), cancellation, and zero-count bypass.")
    }
    #endif
}

#if DEBUG
private final class CountInClickProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var clicks: [Double] = []
    private var lastLoudSample = -Double.infinity
    var onsets: [Double] { lock.lock(); defer { lock.unlock() }; return clicks }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard time.isHostTimeValid, let samples = buffer.floatChannelData?[0] else { return }
        let start = AVAudioTime.seconds(forHostTime: time.hostTime)
        lock.lock(); defer { lock.unlock() }
        for frame in 0..<Int(buffer.frameLength) where abs(samples[frame]) > 0.01 {
            let instant = start + Double(frame) / buffer.format.sampleRate
            if instant - lastLoudSample > 0.08 { clicks.append(instant) }
            lastLoudSample = instant
        }
    }
}
#endif
