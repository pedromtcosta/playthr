import XCTest
import AVFoundation
@testable import PlaythrCore

final class CountInTests: XCTestCase {
    func testFourCountsAt120StartRecordingOnTheFollowingBeat() throws {
        let countIn = try CountIn(bpm: 120, counts: 4)
        XCTAssertEqual(countIn.duration, 2)
        for (elapsed, remaining) in [(-0.5, 4), (0, 4), (0.499, 4), (0.5, 3), (1, 2), (1.5, 1), (1.999, 1), (2, 0), (3, 0)] {
            XCTAssertEqual(countIn.remainingBeats(elapsed: elapsed), remaining)
        }
        let buffer = try XCTUnwrap(countIn.makeBuffer())
        let onsets = pulseOnsets(buffer)
        XCTAssertEqual(onsets.count, 4)
        for (actual, expected) in zip(onsets, [0.0, 0.5, 1, 1.5]) { XCTAssertEqual(actual, expected, accuracy: 0.001) }
        XCTAssertEqual(Double(buffer.frameLength) / buffer.format.sampleRate, 2)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in Int(1.54 * buffer.format.sampleRate)..<Int(buffer.frameLength) {
            XCTAssertEqual(samples[frame], 0, "The last click must end before recording starts")
        }
    }

    func testFractionalTempoHasTheRequestedNumberOfClicksWithoutAccumulatedDrift() throws {
        let countIn = try CountIn(bpm: 137.3, counts: 13)
        for sampleRate in [44100.0, 48000.0] {
            let buffer = try XCTUnwrap(countIn.makeBuffer(sampleRate: sampleRate))
            let onsets = pulseOnsets(buffer)
            XCTAssertEqual(onsets.count, 13)
            for (beat, onset) in onsets.enumerated() {
                XCTAssertEqual(onset, Double(beat) * 60 / 137.3, accuracy: 0.001)
            }
            XCTAssertEqual(Double(buffer.frameLength) / sampleRate, 13 * 60 / 137.3, accuracy: 1 / sampleRate)
        }
    }

    func testZeroCountsAndInvalidSettings() throws {
        let off = try CountIn(bpm: 120, counts: 0)
        XCTAssertNil(try off.makeBuffer())
        XCTAssertEqual(off.duration, 0)
        XCTAssertEqual(off.remainingBeats(elapsed: -1), 0)
        for bpm in [0.0, -120, 401, .nan, .infinity] { XCTAssertThrowsError(try CountIn(bpm: bpm, counts: 4)) }
        for counts in [-1, 65] { XCTAssertThrowsError(try CountIn(bpm: 120, counts: counts)) }
    }

    /// Measure the actual samples, including oscillator crossings and the quiet gaps.
    private func pulseOnsets(_ buffer: AVAudioPCMBuffer) -> [Double] {
        let samples = buffer.floatChannelData![0]
        let gap = Int(buffer.format.sampleRate * 0.08)
        var previous = -gap - 1
        var onsets: [Double] = []
        for frame in 0..<Int(buffer.frameLength) where abs(samples[frame]) > 0.01 {
            if frame - previous > gap { onsets.append(Double(frame) / buffer.format.sampleRate) }
            previous = frame
        }
        return onsets
    }
}
