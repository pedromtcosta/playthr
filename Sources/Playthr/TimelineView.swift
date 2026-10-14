import SwiftUI
import PlaythrCore

struct TimelineView: View {
    @ObservedObject var model: SessionModel
    @State private var zoom = 1.0
    private let labelWidth: CGFloat = 252
    private let rowHeight: CGFloat = 52
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                sectionLabel("TIMELINE")
                Text("\(model.project.tracks.count) backing  /  \(model.project.takes.count) takes")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                Toggle(isOn: $model.isSelectingRange) { Label("Range tool", systemImage: "rectangle.dashed") }
                    .toggleStyle(.button).controlSize(.small).disabled(model.locked || !model.hasProject)
                    .help("Drag on a track to select a range. Turn off to move takes. You can always drag on the ruler to select.")
                Button { model.createSceneFromSelection() } label: { Label("Create Scene", systemImage: "rectangle.split.3x1") }
                    .controlSize(.small).disabled(!model.canCreateScene)
                    .help("Create a Scene from the selected time range. Its video arrangement is independent of other Scenes.")
                Spacer()
                Text("Go to").font(.system(size: 10)).foregroundStyle(Theme.muted)
                CommitNumber(value: model.playhead, set: model.seek).frame(width: 76).disabled(model.locked)
                Text("sec").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Divider().frame(height: 14)
                Image(systemName: "speaker.wave.2").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Slider(value: Binding(get: { model.project.masterVolume }, set: { value in model.edit { $0.masterVolume = value } }), in: 0...1)
                    .frame(width: 76).disabled(model.locked || !model.hasProject).help("Master volume (included in export)")
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Slider(value: $zoom, in: 1...8).frame(width: 72)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(.horizontal, 18).frame(height: 40)
            rangeControls
            GeometryReader { geometry in
                let width: CGFloat = max(CGFloat(400), geometry.size.width - labelWidth - CGFloat(20)) * CGFloat(zoom)
                let scale: CGFloat = width / CGFloat(model.timelineDuration)
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            HStack { Text("TRACK / MIX"); Spacer() }.font(.system(size: 9, weight: .medium)).tracking(1)
                                .foregroundStyle(Theme.muted).padding(.horizontal, 16).frame(height: 28)
                            HStack { sectionLabel("SCENES"); Spacer(); Text("\(model.project.scenes?.count ?? 0)").font(.system(size: 10)).foregroundStyle(.cyan) }
                                .padding(.horizontal, 16).frame(height: 38)
                            ForEach(model.project.tracks) { track in
                                trackHeader(name: track.name, icon: "waveform", color: Theme.accent, volume: track.volume,
                                            muted: track.muted, solo: track.solo, selected: model.selectedTrackID == track.id,
                                            mute: { model.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].muted.toggle() } } },
                                            soloAction: { model.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].solo.toggle() } } },
                                            gain: { value in model.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].volume = value } } },
                                            delete: { model.deleteTrack(track.id) })
                                    .contentShape(Rectangle()).onTapGesture { model.selectTrack(track.id) }
                                    .contextMenu {
                                        Button("Delete track", role: .destructive) { model.deleteTrack(track.id) }
                                    }
                            }
                            ForEach(model.project.takes) { take in
                                trackHeader(name: take.name, icon: "video", color: Theme.video, volume: take.volume,
                                            muted: take.muted, solo: take.solo, selected: model.selectedTrackID == take.id,
                                            mute: { model.editTake(take.id) { $0.muted.toggle() } },
                                            soloAction: { model.editTake(take.id) { $0.solo.toggle() } },
                                            gain: { value in model.editTake(take.id) { $0.volume = value } },
                                            delete: { model.deleteTrack(take.id) })
                                    .contentShape(Rectangle()).onTapGesture { model.selectTrack(take.id) }
                                    .contextMenu { Button("Delete track", role: .destructive) { model.deleteTrack(take.id) } }
                            }
                            if model.isRecording {
                                HStack { Circle().fill(.red).frame(width: 7, height: 7); Text("New guitar take").font(.system(size: 11)); Spacer() }
                                    .padding(.horizontal, 16).frame(height: rowHeight)
                            }
                        }.frame(width: labelWidth).background(Theme.panel.opacity(0.7))
                        ScrollView(.horizontal) {
                            VStack(spacing: 0) {
                                ruler(width: width, scale: scale)
                                ZStack(alignment: .leading) {
                                    Theme.panel
                                    ForEach(Array((model.project.scenes ?? []).enumerated()), id: \.element.id) { index, scene in
                                        SceneBlock(model: model, scene: scene, number: index + 1, scale: scale)
                                    }
                                    if (model.project.scenes ?? []).isEmpty {
                                        Text("No Scenes · audio only. Record a take, or select a range and create a Scene.")
                                            .font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.leading, 8)
                                    }
                                }.frame(width: width, height: 38).coordinateSpace(name: "sceneTimeline").clipped()
                                ForEach(model.project.tracks) { track in
                                    lane(width: width) {
                                        ForEach(track.playbackRegions) { region in
                                            WaveformClip(name: track.name, peaks: cropPeaks(track.peaks, region: region, sourceDuration: track.duration), color: Theme.accent,
                                                         muted: track.muted || (model.project.hasSolo && !track.solo), selected: model.selectedTrackID == track.id)
                                                .frame(width: max(2, region.duration * scale), height: rowHeight - 10)
                                                .offset(x: region.start * scale)
                                        }
                                    }.onTapGesture { location in
                                        guard !model.locked else { return }
                                        model.selectTrack(track.id); model.seek(location.x / scale)
                                    }
                                    .overlay { rangeDragOverlay(scale: scale, trackID: track.id) }
                                }
                                ForEach(model.project.takes) { take in
                                    lane(width: width) {
                                        TakeClip(model: model, take: take, scale: scale, rowHeight: rowHeight)
                                    }
                                    .overlay { rangeDragOverlay(scale: scale, trackID: take.id) }
                                }
                                if model.isRecording {
                                    lane(width: width) {
                                        Text("●  Recording…").font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                                            .frame(width: max(120, (model.playhead - model.activeRecordingStart) * scale), height: rowHeight - 10, alignment: .leading)
                                            .background(Color.red.opacity(0.12)).offset(x: model.activeRecordingStart * scale)
                                    }
                                }
                                if model.project.tracks.isEmpty && model.project.takes.isEmpty {
                                    Text("Your backing tracks and guitar takes will appear here.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                        .frame(width: width, height: 115).contentShape(Rectangle())
                                        .onTapGesture { location in model.seek(location.x / scale) }
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if let range = model.selectedRange {
                                    Rectangle().fill(Color.yellow.opacity(0.12))
                                        .overlay(alignment: .leading) { Rectangle().fill(Color.yellow.opacity(0.8)).frame(width: 1) }
                                        .overlay(alignment: .trailing) { Rectangle().fill(Color.yellow.opacity(0.8)).frame(width: 1) }
                                        .frame(width: max(1, range.duration * scale))
                                        .offset(x: range.start * scale).allowsHitTesting(false)
                                }
                                Rectangle().fill(model.isRecording ? Color.red : Theme.accent).frame(width: 1.5)
                                    .overlay(alignment: .top) { Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(model.isRecording ? .red : Theme.accent) }
                                    .offset(x: model.playhead * scale).allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
        }.background(Theme.background)
    }

    private var rangeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors").foregroundStyle(Theme.accent)
            Text("From")
            CommitNumber(value: model.selectedRange?.start ?? min(model.playhead, model.project.duration), set: model.setRangeStart, updatesWhileEditing: true)
                .frame(width: 70).accessibilityLabel("Range start in seconds")
            Text("to")
            CommitNumber(value: model.selectedRange?.end ?? min(model.playhead + 1, model.project.duration), set: model.setRangeEnd, updatesWhileEditing: true)
                .frame(width: 70).accessibilityLabel("Range end in seconds")
            Text("sec").foregroundStyle(Theme.muted)
            if let range = model.selectedRange {
                Text(String(format: "%.3f sec selected", range.duration)).foregroundStyle(Theme.muted)
            } else {
                Text("Drag ruler to select").foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Picker("Apply to", selection: $model.cutAllTracks) {
                Text(model.selectedTrackName ?? "Select a track").tag(false)
                Text("All tracks").tag(true)
            }.frame(width: 220)
            Button("Leave gap") { model.cutSelection(closeGap: false) }
                .disabled(!model.canCutRange).help("Cut the selected time range and keep later material in place.")
            Button("Close gap") { model.cutSelection(closeGap: true) }
                .disabled(!model.canCutRange).help("Cut the selected time range and shift later material left on the affected track(s).")
            Button { model.selectedRange = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Clear the time selection").disabled(model.selectedRange == nil)
        }.font(.system(size: 10)).controlSize(.small)
            .padding(.horizontal, 18).frame(height: 38).background(Theme.panel)
            .disabled(model.locked || !model.hasProject || model.project.duration == 0)
    }

    @ViewBuilder
    private func rangeDragOverlay(scale: CGFloat, trackID: UUID) -> some View {
        if model.isSelectingRange {
            Color.clear.contentShape(Rectangle()).gesture(rangeGesture(scale: scale, trackID: trackID))
        }
    }

    private func rangeGesture(scale: CGFloat, trackID: UUID? = nil) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard abs(value.translation.width) >= 3 else { return }
                model.selectRange(from: value.startLocation.x / scale, to: value.location.x / scale, trackID: trackID)
            }
            .onEnded { value in
                guard !model.locked else { return }
                if let trackID { model.selectTrack(trackID) }
                if abs(value.translation.width) < 3 {
                    model.selectedRange = nil; model.seek(value.location.x / scale)
                } else {
                    model.selectRange(from: value.startLocation.x / scale, to: value.location.x / scale, trackID: trackID)
                    if let range = model.selectedRange { model.seek(range.start) }
                }
            }
    }

    private func lane<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            Theme.background
            content()
        }.frame(width: width, height: rowHeight).clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
            .contentShape(Rectangle())
    }

    private func ruler(width: CGFloat, scale: CGFloat) -> some View {
        let step = niceStep(80 / scale)
        return Canvas { context, size in
            for second in stride(from: 0.0, through: model.timelineDuration, by: step) {
                let x = second * scale
                var tick = Path(); tick.move(to: CGPoint(x: x, y: size.height - 5)); tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(Theme.muted), lineWidth: 1)
                context.draw(Text(String(format: "%d:%02d", Int(second) / 60, Int(second) % 60)).font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.muted), at: CGPoint(x: x + 5, y: 10), anchor: .leading)
            }
        }.frame(width: width, height: 28).background(Theme.panel)
            .contentShape(Rectangle())
            .gesture(rangeGesture(scale: scale))
            .help("Click to seek; drag to select a time range for cutting or creating a Scene.")
    }

    private func trackHeader(name: String, icon: String, color: Color, volume: Double, muted: Bool, solo: Bool,
                             selected: Bool, mute: @escaping () -> Void, soloAction: @escaping () -> Void,
                             gain: @escaping (Double) -> Void, delete: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color)
                    Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                Slider(value: Binding(get: { volume }, set: gain), in: 0...2).controlSize(.mini)
            }
            Button("M", action: mute).foregroundStyle(muted ? Theme.background : Theme.muted)
                .frame(width: 21, height: 22).background(muted ? Theme.accent : Theme.raised, in: RoundedRectangle(cornerRadius: 4)).help("Mute audio")
            Button("S", action: soloAction).foregroundStyle(solo ? Theme.background : Theme.muted)
                .frame(width: 21, height: 22).background(solo ? Color.yellow : Theme.raised, in: RoundedRectangle(cornerRadius: 4)).help("Solo audio")
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash").frame(width: 21, height: 22).contentShape(Rectangle())
            }
            .foregroundStyle(Theme.muted)
            .accessibilityLabel("Delete \(name)")
            .help("Delete this track from the timeline (⌘Z to undo). Original media is kept.")
        }.buttonStyle(.plain).font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 12).frame(height: rowHeight)
            .background(selected ? color.opacity(0.12) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
            .disabled(model.locked)
    }

    private func niceStep(_ target: Double) -> Double {
        [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 >= target } ?? 1200
    }
}

struct TakeClip: View {
    @ObservedObject var model: SessionModel
    let take: Take
    let scale: CGFloat
    let rowHeight: CGFloat
    @GestureState private var drag: CGFloat = 0
    var body: some View {
        ZStack(alignment: .leading) {
          ForEach(take.playbackRegions) { region in
            WaveformClip(name: take.name, peaks: cropPeaks(take.peaks, region: region, sourceDuration: take.sourceDuration), color: Theme.video,
                     muted: take.muted || (model.project.hasSolo && !take.solo), selected: model.selectedTrackID == take.id)
            .frame(width: max(2, region.duration * scale), height: rowHeight - 10)
            .offset(x: region.start * scale + max(-take.start * scale, drag))
            .gesture(DragGesture(minimumDistance: 3)
                .updating($drag) { value, state, _ in if !model.locked && !model.isSelectingRange { state = value.translation.width } }
                .onEnded { value in
                    guard !model.locked && !model.isSelectingRange else { return }
                    model.selectTrack(take.id)
                    model.editTake(take.id) { $0.start = max(0, take.start + value.translation.width / scale) }
                })
            .onTapGesture { if !model.locked { model.selectTrack(take.id); model.seek(region.start) } }
            .help("Click to inspect; drag to move all parts of this take. Audio and video stay linked.")
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private func cropPeaks(_ peaks: [Float], region: TrackRegion, sourceDuration: Double) -> [Float] {
    guard !peaks.isEmpty, sourceDuration > 0 else { return [] }
    let start = max(0, min(peaks.count - 1, Int(region.sourceIn / sourceDuration * Double(peaks.count))))
    let end = min(peaks.count, Int((region.sourceIn + region.duration) / sourceDuration * Double(peaks.count)))
    return Array(peaks[start..<max(start + 1, end)])
}

struct WaveformClip: View {
    let name: String
    let peaks: [Float]
    let color: Color
    let muted: Bool
    let selected: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(muted ? 0.05 : 0.13))
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                var bars = Path()
                let count = max(1, Int(size.width / 2))
                for index in 0..<count {
                    let lower = min(peaks.count - 1, index * peaks.count / count)
                    let upper = min(peaks.count, max(lower + 1, (index + 1) * peaks.count / count))
                    let peak = CGFloat(peaks[lower..<upper].max() ?? 0)
                    let height = max(1, peak * (size.height - 15))
                    let x = CGFloat(index) * 2
                    bars.move(to: CGPoint(x: x, y: 15 + (size.height - 15 - height) / 2))
                    bars.addLine(to: CGPoint(x: x, y: 15 + (size.height - 15 + height) / 2))
                }
                context.stroke(bars, with: .color(color.opacity(muted ? 0.16 : 0.65)), lineWidth: 1)
            }.padding(.horizontal, 4)
            Text(name).font(.system(size: 9, weight: .medium)).foregroundStyle(color.opacity(muted ? 0.4 : 1)).lineLimit(1).padding(.horizontal, 7).padding(.top, 4)
        }.overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(selected ? 1 : 0.28), lineWidth: selected ? 1.5 : 1))
            .clipped()
    }
}
