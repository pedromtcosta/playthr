import AVFoundation

/// The first click is at zero; recording starts one beat after the final click.
public struct CountIn: Equatable, Sendable {
    public static let bpmRange = 20.0...400.0
    public static let countRange = 0...64
    public let bpm: Double
    public let counts: Int
    public var beatDuration: Double { 60 / bpm }
    public var duration: Double { Double(counts) * beatDuration }

    public init(bpm: Double, counts: Int) throws {
        guard bpm.isFinite, Self.bpmRange.contains(bpm), Self.countRange.contains(counts) else {
            throw PlaythrError.message("Choose a tempo from 20 to 400 BPM and a count-in from 0 to 64 beats.")
        }
        self.bpm = bpm; self.counts = counts
    }

    public func remainingBeats(elapsed: Double) -> Int {
        guard counts > 0, elapsed < duration else { return 0 }
        guard elapsed > 0 else { return counts }
        return counts - Int(floor(elapsed / beatDuration))
    }

    /// Render the entire count-in ahead of time. Click timing never depends on a UI timer.
    /// Each beat is rounded from its absolute position so fractional tempos do not drift.
    public func makeBuffer(sampleRate: Double = 48000) throws -> AVAudioPCMBuffer? {
        guard counts > 0 else { return nil }
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(duration * sampleRate))),
              let samples = buffer.floatChannelData?[0] else {
            throw PlaythrError.message("Could not prepare the metronome audio.")
        }
        buffer.frameLength = buffer.frameCapacity
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        let clickFrames = Int(0.035 * sampleRate)
        for beat in 0..<counts {
            let start = Int((Double(beat) * beatDuration * sampleRate).rounded())
            let frequency = beat == 0 ? 2000.0 : 1500.0
            let gain = beat == 0 ? 0.5 : 0.4
            for frame in 0..<min(clickFrames, Int(buffer.frameLength) - start) {
                let t = Double(frame) / sampleRate
                let attack = min(1, t / 0.0005)
                let release = min(1, max(0, (0.035 - t) / 0.005))
                samples[start + frame] = Float(gain * attack * release * exp(-t / 0.009) * sin(2 * .pi * frequency * t))
            }
        }
        return buffer
    }
}
