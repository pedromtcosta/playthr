import SwiftUI
import PlaythrCore

struct SceneInspector: View {
    @ObservedObject var model: SessionModel
    let scene: VideoScene
    private var available: [Take] {
        guard let range = TimelineRange(start: scene.start, end: scene.end) else { return [] }
        let candidates = Set(model.project.takes(in: range).map(\.id) + scene.videos.map(\.takeID))
        return model.project.takes.filter { candidates.contains($0.id) }.sorted { a, b in
            let ai = scene.videos.firstIndex { $0.takeID == a.id } ?? -1
            let bi = scene.videos.firstIndex { $0.takeID == b.id } ?? -1
            return ai == bi ? a.layer < b.layer : ai > bi
        }
    }
    private var selected: SceneVideo? { scene.videos.first { $0.takeID == model.selectedSceneVideoID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Scene name (optional)", text: Binding(get: { scene.name }, set: { name in model.editScene(scene.id) { $0.name = name } }))
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) { model.deleteScene(scene.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("Delete Scene")
                    .help("Delete this Scene, leaving its range without video. Audio keeps playing. ⌘Z to undo.")
            }
            HStack(spacing: 6) {
                Text("From")
                CommitNumber(value: scene.start, set: { model.resizeScene(scene.id, start: min($0, scene.end - 0.001), end: scene.end) })
                    .frame(width: 68).accessibilityLabel("Scene start in seconds")
                Text("to")
                CommitNumber(value: scene.end, set: { model.resizeScene(scene.id, start: scene.start, end: max($0, scene.start + 0.001)) })
                    .frame(width: 68).accessibilityLabel("Scene end in seconds")
                Text("sec").foregroundStyle(Theme.muted)
            }.font(.system(size: 10))
            Text("\(timecode(scene.start)) – \(timecode(scene.end))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            Divider()
            sectionLabel("ARRANGEMENT")
            Picker("Scene layout", selection: Binding(get: { scene.layout }, set: { layout in model.editScene(scene.id) { $0.applyLayout(layout) } })) {
                ForEach(VideoLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden()
            Text("Drag frames to move; drag the corner to resize. Videos keep their aspect ratio.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            if !scene.contains(model.playhead) {
                Button("Go to this Scene") { model.seek(scene.start) }.buttonStyle(.bordered)
            }
            Divider()
            sectionLabel("VIDEOS · FRONT TO BACK")
            if available.isEmpty {
                Text("No recordings overlap this Scene yet.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            ForEach(available) { take in
                let visible = scene.videos.first { $0.takeID == take.id }?.visible ?? false
                HStack(spacing: 8) {
                    Toggle("Show \(take.name) in this Scene", isOn: Binding(get: { visible }, set: { model.setSceneVideoVisible(take.id, sceneID: scene.id, visible: $0) }))
                        .labelsHidden().toggleStyle(.checkbox)
                    Button { model.selectedSceneVideoID = take.id } label: {
                        HStack {
                            Text(take.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if !take.playbackRegions.contains(where: { $0.start <= model.playhead && $0.end > model.playhead }) {
                                Image(systemName: "clock").help("This video has no footage at the current playhead.")
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.font(.system(size: 11)).padding(8)
                    .background(model.selectedSceneVideoID == take.id ? Theme.video.opacity(0.18) : Theme.raised, in: RoundedRectangle(cornerRadius: 5))
            }
            Text("Visibility applies only to this Scene. Audio keeps playing from its track.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
            if let video = selected, available.contains(where: { $0.id == video.takeID }) {
                Divider()
                sectionLabel("SELECTED VIDEO")
                Text(model.project.takes.first { $0.id == video.takeID }?.name ?? "Video").font(.system(size: 12, weight: .medium))
                HStack {
                    Button("Back") { model.reorderSceneVideo(video.takeID, sceneID: scene.id, forward: false) }
                        .disabled(scene.videos.first?.takeID == video.takeID)
                    Button("Forward") { model.reorderSceneVideo(video.takeID, sceneID: scene.id, forward: true) }
                        .disabled(scene.videos.last?.takeID == video.takeID)
                }.buttonStyle(.bordered).controlSize(.small)
                positionField("Left", video: video, key: \.x)
                positionField("Top", video: video, key: \.y)
                positionField("Width", video: video, key: \.width)
                positionField("Height", video: video, key: \.height)
                Button("Full frame") { model.setScenePlacement(Placement(), takeID: video.takeID, sceneID: scene.id) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }.disabled(model.locked)
    }
    private func positionField(_ title: String, video: SceneVideo, key: WritableKeyPath<Placement, Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)); Spacer()
            CommitNumber(value: video.placement[keyPath: key] * 100, set: { value in
                var p = video.placement; p[keyPath: key] = value / 100
                model.setScenePlacement(p, takeID: video.takeID, sceneID: scene.id)
            }, fractionDigits: 1).frame(width: 64)
            Text("%").font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }
}

/// Selection frames use the same 16:9 canvas and normalized coordinates as export.
/// One gesture commits one undoable edit; rebuilding never interrupts a drag.
struct SceneCanvas: View {
    @ObservedObject var model: SessionModel
    let scene: VideoScene
    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, geometry.size.height * 16 / 9)
            let height = width * 9 / 16
            ZStack(alignment: .topLeading) {
                ForEach(scene.videos.filter(\.visible)) { video in
                    if let take = model.project.takes.first(where: { $0.id == video.takeID }),
                       take.playbackRegions.contains(where: { $0.start <= model.playhead && $0.end > model.playhead }) {
                        SceneVideoFrame(model: model, sceneID: scene.id, video: video, name: take.name,
                                        canvas: CGSize(width: width, height: height))
                    }
                }
            }.frame(width: width, height: height).coordinateSpace(name: "sceneCanvas").clipped()
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

private struct SceneVideoFrame: View {
    @ObservedObject var model: SessionModel
    let sceneID: UUID
    let video: SceneVideo
    let name: String
    let canvas: CGSize
    private struct FrameDrag {
        var translation = CGSize.zero
        var resizing = false
    }
    @GestureState private var drag = FrameDrag()
    private var selected: Bool { model.selectedSceneVideoID == video.takeID }
    private func placement(translation: CGSize, resizing: Bool) -> Placement {
        var p = video.placement
        if resizing {
            p.width = min(1 - p.x, max(0.01, p.width + translation.width / canvas.width))
            p.height = min(1 - p.y, max(0.01, p.height + translation.height / canvas.height))
        } else {
            p.x = min(1 - p.width, max(0, p.x + translation.width / canvas.width))
            p.y = min(1 - p.height, max(0, p.y + translation.height / canvas.height))
        }
        return p
    }
    private func isResize(_ value: DragGesture.Value) -> Bool {
        let right = (video.placement.x + video.placement.width) * canvas.width
        let bottom = (video.placement.y + video.placement.height) * canvas.height
        return value.startLocation.x >= right - 22 && value.startLocation.x <= right &&
            value.startLocation.y >= bottom - 22 && value.startLocation.y <= bottom
    }
    var body: some View {
        let p = placement(translation: drag.translation, resizing: drag.resizing)
        Rectangle().fill(selected ? Theme.video.opacity(0.05) : .clear)
            .overlay { Rectangle().stroke(selected ? Theme.accent : Theme.video.opacity(0.7), lineWidth: selected ? 2 : 1) }
            .overlay(alignment: .topLeading) {
                Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1).padding(5)
                    .background(.black.opacity(0.65)).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("sceneCanvas"))
                .updating($drag) { value, state, _ in state.translation = value.translation; state.resizing = isResize(value) }
                .onChanged { _ in model.selectedSceneVideoID = video.takeID }
                .onEnded { value in
                    model.setScenePlacement(placement(translation: value.translation, resizing: isResize(value)), takeID: video.takeID, sceneID: sceneID)
                })
            .onTapGesture { model.selectedSceneVideoID = video.takeID }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.background).frame(width: 22, height: 22)
                    .background(selected ? Theme.accent : Theme.video.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                    .allowsHitTesting(false)
            }
            .frame(width: max(1, p.width * canvas.width), height: max(1, p.height * canvas.height))
            .offset(x: p.x * canvas.width, y: p.y * canvas.height)
            .help("Drag to move this video. Select it and drag its lower-right handle to resize.")
    }
}

struct SceneBlock: View {
    @ObservedObject var model: SessionModel
    let scene: VideoScene
    let number: Int
    let scale: CGFloat
    @GestureState private var startDrag: CGFloat = 0
    @GestureState private var endDrag: CGFloat = 0
    private var selected: Bool { model.selectedSceneID == scene.id }
    var body: some View {
        let start = max(0, min(scene.end - 0.001, scene.start + startDrag / scale))
        let end = min(model.project.duration, max(start + 0.001, scene.end + endDrag / scale))
        HStack(spacing: 0) {
            if selected { boundary(isStart: true) }
            Button { model.selectScene(scene.id) } label: {
                Text(scene.title(number: number)).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if selected { boundary(isStart: false) }
        }.foregroundStyle(selected ? Theme.background : Color.cyan)
            .frame(width: max(2, (end - start) * scale), height: 28)
            .background(selected ? Color.cyan : Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.cyan.opacity(selected ? 1 : 0.4)) }
            .clipped().offset(x: start * scale)
            .contextMenu {
                Button(role: .destructive) { model.deleteScene(scene.id) } label: { Label("Delete Scene", systemImage: "trash") }
                    .disabled(model.locked)
            }
            .help("\(scene.title(number: number)) · \(timecode(scene.start)) – \(timecode(scene.end)). Select to arrange; drag its edges to adjust the range.")
            .disabled(model.locked)
    }
    private func boundary(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(Theme.background.opacity(0.6)).frame(width: 2, height: 14)
            .frame(width: 7, height: 28).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("sceneTimeline"))
                .updating(isStart ? $startDrag : $endDrag) { value, state, _ in state = value.translation.width }
                .onEnded { value in
                    let offset = value.translation.width / scale
                    let start = isStart ? max(0, min(scene.end - 0.001, scene.start + offset)) : scene.start
                    let end = isStart ? scene.end : min(model.project.duration, max(scene.start + 0.001, scene.end + offset))
                    model.resizeScene(scene.id, start: start, end: end)
                })
    }
}
