import Foundation

/// A scene is an editorial interval. Its video list is ordered from back to front.
/// Media timing and audio remain on the original tracks.
public struct VideoScene: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var start: Double
    public var end: Double
    public var layout: VideoLayout
    public var videos: [SceneVideo]
    public var duration: Double { end - start }
    public init(id: UUID = UUID(), name: String = "", start: Double, end: Double,
                layout: VideoLayout = .grid, videos: [SceneVideo] = []) {
        self.id = id; self.name = name; self.start = start; self.end = end
        self.layout = layout; self.videos = videos
    }
    public func contains(_ time: Double) -> Bool { start <= time && time < end }
    public func title(number: Int) -> String { name.isEmpty ? "Scene \(number)" : name }

    public mutating func applyLayout(_ layout: VideoLayout) {
        self.layout = layout
        guard layout != .custom else { return }
        let indices = videos.indices.filter { videos[$0].visible }
        let positions = layout.placements(count: indices.count)
        for (index, position) in zip(indices, positions) { videos[index].placement = position }
    }
}

public struct SceneVideo: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID { takeID }
    public var takeID: UUID
    public var visible: Bool
    public var placement: Placement
    public init(takeID: UUID, visible: Bool = true, placement: Placement = Placement()) {
        self.takeID = takeID; self.visible = visible; self.placement = placement
    }
}

extension Project {
    public func takes(in range: TimelineRange) -> [Take] {
        takes.filter { take in take.playbackRegions.contains { $0.start < range.end && $0.end > range.start } }
            .sorted { $0.layer == $1.layer ? $0.id.uuidString < $1.id.uuidString : $0.layer < $1.layer }
    }

    public func scene(at time: Double) -> VideoScene? { scenes?.first { $0.contains(time) } }

    public func showsVideo(_ take: Take) -> Bool {
        guard let scenes else { return !take.hidden && !take.playbackRegions.isEmpty }
        return scenes.contains { scene in
            scene.videos.contains { $0.takeID == take.id && $0.visible } &&
            take.playbackRegions.contains { $0.start < scene.end && $0.end > scene.start }
        }
    }

    /// Upgrade without changing the old render: every change in active takes gets
    /// a scene, with the same layout, stacking order, and hidden-video settings.
    public mutating func enableScenes() {
        guard scenes == nil else { return }
        scenes = []; schemaVersion = max(3, schemaVersion)
        guard duration > 0, takes.contains(where: { !$0.playbackRegions.isEmpty }) else { return }
        let boundaries = Set([0, duration] + takes.flatMap { $0.playbackRegions.flatMap { [$0.start, $0.end] } }).sorted()
        scenes = zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard let range = TimelineRange(start: start, end: end) else { return nil }
            return makeScene(in: range)
        }
    }

    private func makeScene(in range: TimelineRange) -> VideoScene {
        var scene = VideoScene(start: range.start, end: range.end, layout: layout,
            videos: takes(in: range).map { SceneVideo(takeID: $0.id, visible: !$0.hidden, placement: $0.placement) })
        scene.applyLayout(layout)
        return scene
    }

    /// The same interval overlay handles nesting, partial overlaps, and a range
    /// spanning several scenes. Only the overlapped portion is replaced.
    @discardableResult
    public mutating func createScene(in range: TimelineRange) throws -> UUID {
        guard range.end <= duration + 0.000001 else { throw PlaythrError.message("Keep the Scene inside the timeline.") }
        enableScenes()
        let scene = makeScene(in: range)
        scenes = overlay(scene, on: scenes ?? [])
        reconcileScenes()
        try validate()
        return scene.id
    }

    @discardableResult
    public mutating func addTake(_ take: Take) throws -> UUID? {
        enableScenes()
        takes.append(take)
        guard let first = take.playbackRegions.first,
              let range = TimelineRange(start: first.start, end: take.end) else { return nil }
        return try createScene(in: range)
    }

    /// Remove only the arrangement. The uncovered interval has no picture;
    /// media, audio, and other scene boundaries stay in place.
    @discardableResult
    public mutating func deleteScene(_ id: UUID) throws -> Bool {
        guard let index = scenes?.firstIndex(where: { $0.id == id }) else { return false }
        scenes?.remove(at: index)
        try validate()
        return true
    }

    /// Shrinking returns the released time to adjacent scenes, preserving their
    /// layouts, or leaves a gap if there is no neighbor. Expanding uses the same
    /// overlay operation as scene creation.
    public mutating func resizeScene(_ id: UUID, to range: TimelineRange) throws {
        guard range.end <= duration + 0.000001, let index = scenes?.firstIndex(where: { $0.id == id }),
              var current = scenes?[index] else { throw PlaythrError.message("Select a Scene and keep its boundaries inside the timeline.") }
        let old = current
        var others = scenes ?? []
        others.remove(at: index)
        if range.start > old.start {
            let releasedEnd = min(range.start, old.end)
            if let left = others.lastIndex(where: { abs($0.end - old.start) < 0.000001 }) {
                others[left].end = releasedEnd
            }
        }
        if range.end < old.end {
            let releasedStart = max(range.end, old.start)
            if let right = others.firstIndex(where: { abs($0.start - old.end) < 0.000001 }) {
                others[right].start = releasedStart
            }
        }
        current.start = range.start; current.end = range.end
        scenes = overlay(current, on: others)
        reconcileScenes()
        try validate()
    }

    private func overlay(_ scene: VideoScene, on existing: [VideoScene]) -> [VideoScene] {
        var result: [VideoScene] = []
        for old in existing {
            if old.end <= scene.start || old.start >= scene.end { result.append(old); continue }
            if old.start < scene.start {
                var left = old; left.end = scene.start; result.append(left)
            }
            if old.end > scene.end {
                var right = old; right.start = scene.end
                if old.start < scene.start { right.id = UUID() }
                result.append(right)
            }
        }
        result.append(scene)
        return result.sorted { $0.start < $1.start }
    }

    /// Keep editorial choices when media is moved/cut/deleted, including gaps.
    /// Only explicit scene creation or a new recording adds an arrangement.
    public mutating func reconcileScenes() {
        guard let existing = scenes else { return }
        schemaVersion = max(3, schemaVersion)
        guard duration > 0 else { scenes = []; return }
        let takeIDs = Set(takes.map(\.id))
        var result: [VideoScene] = []
        for var scene in existing.sorted(by: { $0.start < $1.start }) {
            scene.end = min(scene.end, duration)
            guard scene.start < scene.end else { continue }
            scene.videos.removeAll { !takeIDs.contains($0.takeID) }
            result.append(scene)
        }
        scenes = result
    }

    mutating func rippleScenes(_ range: TimelineRange) {
        guard let scenes else { return }
        func shifted(_ time: Double) -> Double {
            if time <= range.start { return time }
            if time >= range.end { return time - range.duration }
            return range.start
        }
        self.scenes = scenes.compactMap { scene in
            var result = scene; result.start = shifted(scene.start); result.end = shifted(scene.end)
            return result.end > result.start ? result : nil
        }
    }

    func validateScenes() throws {
        guard let scenes else { return }
        guard schemaVersion >= 3, Set(scenes.map(\.id)).count == scenes.count else {
            throw PlaythrError.message("Scenes require project format version 3 and unique IDs.")
        }
        let takeIDs = Set(takes.map(\.id))
        var end = 0.0
        for scene in scenes {
            guard scene.start.isFinite, scene.end.isFinite, scene.start >= 0, scene.end > scene.start,
                  scene.start >= end - 0.000001, scene.end <= duration + 0.000001,
                  Set(scene.videos.map(\.takeID)).count == scene.videos.count else {
                throw PlaythrError.message("Scenes must be ordered, non-overlapping ranges inside the timeline.")
            }
            for video in scene.videos {
                let p = video.placement
                guard takeIDs.contains(video.takeID), [p.x, p.y, p.width, p.height].allSatisfy(\.isFinite),
                      (0...1).contains(p.x), (0...1).contains(p.y),
                      (0.01...1).contains(p.width), (0.01...1).contains(p.height) else {
                    throw PlaythrError.message("A Scene contains an invalid video or position.")
                }
            }
            end = scene.end
        }
    }
}
