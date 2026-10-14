import Foundation

public struct TimelineRange: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public var duration: Double { end - start }
    public init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        self.start = start; self.end = end
    }
}

/// A surviving piece of one track's original media. Several pieces share the track's mix/layout.
public struct TrackRegion: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var sourceIn: Double
    public var duration: Double
    public var end: Double { start + duration }
    public init(id: UUID = UUID(), start: Double, sourceIn: Double, duration: Double) {
        self.id = id; self.start = start; self.sourceIn = sourceIn; self.duration = duration
    }

    func cutting(_ range: TimelineRange, closeGap: Bool) -> [TrackRegion] {
        if end <= range.start { return [self] }
        if start >= range.end {
            var shifted = self
            if closeGap { shifted.start -= range.duration }
            return [shifted]
        }
        var pieces: [TrackRegion] = []
        if start < range.start {
            var left = self
            left.duration = range.start - start
            pieces.append(left)
        }
        if end > range.end {
            var right = self
            if !pieces.isEmpty { right.id = UUID() }
            right.sourceIn += range.end - start
            right.duration = end - range.end
            right.start = closeGap ? range.start : range.end
            pieces.append(right)
        }
        return pieces
    }
}

extension Project {
    /// A nil track ID cuts all tracks. Ripple shifts each affected track by the same full range.
    @discardableResult
    public mutating func cut(_ range: TimelineRange, trackID: UUID?, closeGap: Bool) throws -> Bool {
        try validate()
        if let trackID, !tracks.contains(where: { $0.id == trackID }), !takes.contains(where: { $0.id == trackID }) {
            throw PlaythrError.message("Select a track to cut.")
        }
        guard let range = TimelineRange(start: range.start, end: min(range.end, duration)) else { return false }
        var changed = false
        for index in tracks.indices where trackID == nil || tracks[index].id == trackID {
            let before = tracks[index].playbackRegions
            let after = before.flatMap { $0.cutting(range, closeGap: closeGap) }
            if before != after { tracks[index].regions = after; changed = true }
        }
        for index in takes.indices where trackID == nil || takes[index].id == trackID {
            let before = takes[index].playbackRegions
            let after = before.flatMap { $0.cutting(range, closeGap: closeGap) }
            if before != after {
                takes[index].regions = after
                if let first = after.first { takes[index].start = first.start }
                changed = true
            }
        }
        // Older builds must not silently ignore the pieces and play deleted material.
        if changed {
            schemaVersion = max(schemaVersion, 2)
            if trackID == nil && closeGap { rippleScenes(range) }
            reconcileScenes()
        }
        try validate()
        return changed
    }
}

func validateRegions(_ regions: [TrackRegion]?, sourceIn: Double, duration: Double) throws {
    guard let regions else { return }
    guard Set(regions.map(\.id)).count == regions.count else { throw PlaythrError.message("A track contains duplicate part IDs.") }
    var previousEnd = 0.0
    for region in regions {
        guard [region.start, region.sourceIn, region.duration, region.end].allSatisfy(\.isFinite),
              region.start >= 0, region.duration > 0, region.start >= previousEnd - 0.000001,
              region.sourceIn >= sourceIn - 0.000001, region.sourceIn + region.duration <= sourceIn + duration + 0.001 else {
            throw PlaythrError.message("A track contains an invalid cut or overlapping parts.")
        }
        previousEnd = region.end
    }
}
