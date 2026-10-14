import Foundation

public struct Placement: Codable, Equatable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    public var width: Double = 1
    public var height: Double = 1
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum VideoLayout: String, Codable, CaseIterable, Sendable {
    case grid, stacked, pictureInPicture, custom
    public var title: String {
        switch self {
        case .grid: return "Side by side"
        case .stacked: return "Top & bottom"
        case .pictureInPicture: return "Picture in picture"
        case .custom: return "Custom positions"
        }
    }
    /// Rectangles are normalized, with their origin at the top left.
    public func placements(count: Int) -> [Placement] {
        guard count > 0 else { return [] }
        if count == 1 { return [Placement()] }
        switch self {
        case .pictureInPicture:
            let smallHeight = min(0.30, 0.90 / Double(count - 1))
            return [Placement()] + (1..<count).map {
                Placement(x: 0.67, y: 0.96 - Double($0) * smallHeight,
                          width: 0.30, height: smallHeight - 0.02)
            }
        case .stacked:
            return (0..<count).map { Placement(y: Double($0) / Double(count), height: 1 / Double(count)) }
        case .grid, .custom:
            let columns = Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(columns)))
            return (0..<count).map {
                Placement(x: Double($0 % columns) / Double(columns), y: Double($0 / columns) / Double(rows),
                          width: 1 / Double(columns), height: 1 / Double(rows))
            }
        }
    }
}

public struct BackingTrack: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var file: String
    public var duration: Double
    public var volume: Double = 1
    public var muted = false
    public var solo = false
    public var peaks: [Float] = []
    /// Nil is the original, continuous track (including projects saved before range editing).
    public var regions: [TrackRegion]?
    public var playbackRegions: [TrackRegion] { regions ?? [TrackRegion(id: id, start: 0, sourceIn: 0, duration: duration)] }
    public var end: Double { playbackRegions.map(\.end).max() ?? 0 }
    public init(name: String, file: String, duration: Double, peaks: [Float] = []) {
        self.name = name; self.file = file; self.duration = duration; self.peaks = peaks
    }
}

public struct Take: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var file: String
    public var start: Double
    public var sourceIn: Double = 0
    public var duration: Double
    public var sourceDuration: Double
    public var volume: Double = 1
    public var muted = false
    public var solo = false
    public var hidden = false
    /// Positive values delay the recorded audio; negative values advance it.
    public var audioOffset: Double = 0
    public var placement = Placement()
    public var layer: Int = 0
    public var peaks: [Float] = []
    public var createdAt = Date()
    public var regions: [TrackRegion]?
    public var playbackRegions: [TrackRegion] { regions ?? [TrackRegion(id: id, start: start, sourceIn: sourceIn, duration: duration)] }
    public var end: Double { playbackRegions.map(\.end).max() ?? 0 }
    public init(name: String, file: String, start: Double, duration: Double, layer: Int = 0) {
        self.name = name; self.file = file; self.start = start
        self.duration = duration; self.sourceDuration = duration; self.layer = layer
    }
}

public struct Project: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var name: String
    public var tracks: [BackingTrack] = []
    public var takes: [Take] = []
    public var layout = VideoLayout.grid
    /// Nil loads legacy projects with their original global arrangement.
    public var scenes: [VideoScene]?
    public var masterVolume: Double = 0.8
    public var duration: Double { max(tracks.map(\.end).max() ?? 0, takes.map(\.end).max() ?? 0) }
    public var hasSolo: Bool { tracks.contains(where: \.solo) || takes.contains(where: \.solo) }
    public init(name: String = "Untitled playthrough") { self.name = name }
    public func gain(volume: Double, muted: Bool, solo: Bool) -> Float {
        muted || (hasSolo && !solo) ? 0 : Float(volume * masterVolume)
    }

    public func validate() throws {
        guard (1...3).contains(schemaVersion) else { throw PlaythrError.message("This project uses an unsupported version (\(schemaVersion)).") }
        guard schemaVersion >= 2 || (!tracks.contains { $0.regions != nil } && !takes.contains { $0.regions != nil }) else {
            throw PlaythrError.message("Range edits require project format version 2.")
        }
        guard !name.isEmpty, masterVolume.isFinite, (0...1).contains(masterVolume),
              Set(tracks.map(\.id) + takes.map(\.id)).count == tracks.count + takes.count else {
            throw PlaythrError.message("The project contains invalid settings or duplicate clip IDs.")
        }
        for track in tracks {
            try validateMediaPath(track.file)
            try validateRegions(track.regions, sourceIn: 0, duration: track.duration)
            guard track.duration.isFinite, track.duration > 0, track.volume.isFinite, (0...2).contains(track.volume),
                  track.peaks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
                throw PlaythrError.message("Invalid backing track: \(track.name).")
            }
        }
        for take in takes {
            try validateMediaPath(take.file)
            try validateRegions(take.regions, sourceIn: take.sourceIn, duration: take.duration)
            let numbers = [take.start, take.sourceIn, take.duration, take.sourceDuration, take.audioOffset,
                           take.volume, take.placement.x, take.placement.y, take.placement.width, take.placement.height]
            guard numbers.allSatisfy(\.isFinite), take.start >= 0, take.sourceIn >= 0, take.duration > 0,
                  take.sourceIn + take.duration <= take.sourceDuration + 0.001,
                  (0...2).contains(take.volume), abs(take.audioOffset) <= 2,
                  (0...1).contains(take.placement.x), (0...1).contains(take.placement.y),
                  (0.05...1).contains(take.placement.width), (0.05...1).contains(take.placement.height),
                  take.peaks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
                throw PlaythrError.message("Invalid timing or layout for take: \(take.name).")
            }
        }
        try validateScenes()
    }
}

public enum PlaythrError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

public func validateMediaPath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2, components[0] == "Media", !components[1].isEmpty,
          components[1] != ".", components[1] != "..", !path.contains("\\") else {
        throw PlaythrError.message("Invalid project media path: \(path).")
    }
}

public struct ClipSegment: Equatable {
    public let timelineStart: Double
    public let sourceStart: Double
    public let duration: Double
    public init?(take: Take, audio: Bool) {
        let offset = audio ? take.audioOffset : 0
        timelineStart = take.start + max(0, offset)
        sourceStart = take.sourceIn + max(0, -offset)
        duration = take.duration - abs(offset)
        if duration <= 0 { return nil }
    }

    public init(region: TrackRegion) {
        timelineStart = region.start; sourceStart = region.sourceIn; duration = region.duration
    }

    public init?(region: TrackRegion, take: Take, audio: Bool) {
        guard let original = ClipSegment(take: take, audio: audio) else { return nil }
        let requestedSource = region.sourceIn - (audio ? take.audioOffset : 0)
        sourceStart = max(requestedSource, original.sourceStart)
        let sourceEnd = min(requestedSource + region.duration, original.sourceStart + original.duration)
        duration = sourceEnd - sourceStart
        timelineStart = region.start + sourceStart - requestedSource
        if duration <= 0 { return nil }
    }
}
