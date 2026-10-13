import SwiftUI
import AVKit
import PlaythrCore

enum Theme {
    static let background = Color(red: 0.065, green: 0.073, blue: 0.085)
    static let panel = Color(red: 0.10, green: 0.115, blue: 0.13)
    static let raised = Color(red: 0.14, green: 0.155, blue: 0.175)
    static let accent = Color(red: 0.48, green: 0.91, blue: 0.72)
    static let video = Color(red: 0.64, green: 0.58, blue: 0.93)
    static let muted = Color(red: 0.53, green: 0.57, blue: 0.62)
    static let stroke = Color.white.opacity(0.085)
}

struct StudioView: View {
    @ObservedObject var model: SessionModel
    @State private var showRouting = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    previewHeader
                    ZStack {
                        Color.black
                        if model.isConnected && (model.isRecording || model.project.takes.isEmpty) {
                            CameraPreview(session: model.capture.session)
                        } else if !model.project.takes.isEmpty {
                            PlayerPreview(player: model.player)
                        } else { emptyPreview }
                        if model.isConnected && !model.isRecording && !model.project.takes.isEmpty {
                            VStack { Spacer(); HStack { Spacer();
                                CameraPreview(session: model.capture.session)
                                    .frame(width: 192, height: 108)
                                    .overlay(alignment: .topLeading) { Text("CAMERA").font(.system(size: 9, weight: .bold)).padding(5).background(.black.opacity(0.65)) }
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
                                    .padding(18)
                            } }
                        }
                        if model.isRecording {
                            VStack { HStack {
                                Label(model.isCountingIn ? "GET READY" : "RECORDING", systemImage: "record.circle.fill")
                                    .font(.system(size: 11, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Color.red.opacity(0.85), in: Capsule())
                                Spacer()
                            }; Spacer() }.padding(18)
                        }
                        if model.countdown > 0 {
                            VStack(spacing: 0) {
                                Text("\(model.countdown)").font(.system(size: 80, weight: .semibold, design: .rounded))
                                Text(model.countdown == 1 ? "BEAT TO RECORD" : "BEATS TO RECORD")
                                    .font(.system(size: 9, weight: .semibold)).tracking(1)
                            }.frame(width: 160, height: 160).background(.black.opacity(0.65), in: Circle())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    transport
                }
                Rectangle().fill(Theme.stroke).frame(width: 1)
                inspector.frame(width: 286)
            }.frame(minHeight: 360, maxHeight: .infinity)
            Divider().overlay(Theme.stroke)
            TimelineView(model: model).frame(height: 328)
            footer
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .alert("Playthr", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showRouting) { RoutingView() }
        .background(WindowGuard(model: model))
    }

    private var header: some View {
        HStack(spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 23, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("playthr").font(.system(size: 23, weight: .bold, design: .rounded)).tracking(-0.8)
            }
            Rectangle().fill(Theme.stroke).frame(width: 1, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.hasProject ? model.project.name : "Your guitar. Every layer.").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(model.hasProject ? "LOCAL PROJECT  ·  AUTOSAVED" : "PLAYTHROUGH STUDIO").font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(Theme.muted)
            }
            Spacer()
            Menu {
                Button("New project…", action: model.newProject)
                Button("Open project…") { model.openProject() }
                Divider()
                Button("Recover takes", action: model.recoverTakes).disabled(!model.hasProject)
                if let store = model.store {
                    Button("Show project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.root]) }
                }
            } label: { Label("Project", systemImage: "folder") }.menuStyle(.borderlessButton).fixedSize().disabled(model.locked)
            Menu {
                Button("Sound Razor song / stems folder…") { model.importAudio(soundRazor: true) }
                Button("Audio files…") { model.importAudio(soundRazor: false) }
            } label: { Label("Import backing", systemImage: "plus") }.fixedSize().disabled(!model.hasProject || model.locked)
            Button(action: model.exportVideo) { Label("Export video", systemImage: "square.and.arrow.up").padding(.horizontal, 8).padding(.vertical, 4) }
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                .disabled(!model.hasVisibleVideo || model.locked || model.isBuilding)
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var previewHeader: some View {
        HStack {
            Label(model.isConnected && (model.isRecording || model.project.takes.isEmpty) ? "CAMERA" : "PROGRAM", systemImage: "rectangle.inset.filled")
                .font(.system(size: 10, weight: .semibold)).tracking(1.3)
            Spacer()
            Text("1920 × 1080  /  30 FPS EXPORT").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
        }.padding(.horizontal, 18).padding(.vertical, 10).background(Theme.panel)
    }

    private var emptyPreview: some View {
        VStack(spacing: 16) {
            Image(systemName: "guitars").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Theme.accent)
            Text(model.hasProject ? "Ready when you are." : "A space for your playthroughs.")
                .font(.system(size: 25, weight: .medium, design: .rounded))
            Text(model.hasProject ? "Import your backing tracks. Connect your camera and guitar.\nChoose a moment on the timeline, then press Record." : "Bring your backing tracks, record each guitar part,\nand put the whole performance together.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(5)
            if !model.hasProject {
                HStack(spacing: 12) {
                    Button("Create project", action: model.newProject).buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                    Button("Open project") { model.openProject() }.buttonStyle(.bordered)
                }.padding(.top, 6)
            }
        }.padding(30)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timecode(model.playhead)).font(.system(size: 23, weight: .medium, design: .monospaced)).foregroundStyle(Theme.accent)
                Text("OF \(timecode(model.project.duration))").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
            }.frame(width: 152, alignment: .leading)
            Spacer(minLength: 0)
            Button { model.seek(0) } label: { Image(systemName: "backward.end.fill") }.buttonStyle(.plain).help("Return to start").disabled(model.locked)
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying || model.isRecording ? "stop.fill" : "play.fill")
                    .font(.system(size: 19)).frame(width: 42, height: 42).background(Theme.raised, in: Circle())
            }.buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])
                .disabled(!model.isRecording && (model.locked || model.isBuilding || model.project.duration == 0))
            Button(action: model.record) {
                HStack(spacing: 8) {
                    Image(systemName: model.isRecording ? "stop.fill" : "circle.fill")
                    Text(model.isCountingIn ? "Cancel count-in" : model.isRecording ? "Stop & save" : "Record").fontWeight(.semibold)
                }.padding(.horizontal, 18).frame(height: 38)
                    .background(model.isRecording ? Color.red : Color.red.opacity(0.13), in: Capsule())
                    .foregroundStyle(model.isRecording ? .white : Color(red: 1, green: 0.43, blue: 0.42))
            }.buttonStyle(.plain).keyboardShortcut("r", modifiers: [])
                .disabled(!model.isRecording && (!model.hasProject || model.locked || model.isBuilding || !model.isConnected))
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Label("COUNT-IN", systemImage: "metronome").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
                HStack(spacing: 5) {
                    CommitNumber(value: model.countInBPM, set: model.setCountInBPM, fractionDigits: 1, updatesWhileEditing: true)
                        .frame(width: 58).accessibilityLabel("Count-in BPM")
                        .help("Metronome tempo, 20–400 beats per minute.")
                    Text("BPM").font(.system(size: 9)).foregroundStyle(Theme.muted)
                    CommitNumber(value: Double(model.countInCounts), set: model.setCountInCounts, fractionDigits: 0, updatesWhileEditing: true)
                        .frame(width: 38).padding(.leading, 5).accessibilityLabel("Count-in beats")
                        .help("Number of clicks before recording, 0–64. Set 0 to skip the count-in.")
                    Text("counts").font(.system(size: 9)).foregroundStyle(Theme.muted)
                }.disabled(model.locked)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14).background(Theme.panel)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    sectionLabel("RECORDING SETUP")
                    Spacer()
                    Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh devices").disabled(model.locked)
                }
                inputControls
                levelMeter
                outputControls
                Button { showRouting = true } label: { Label("Neural DSP + BlackHole setup", systemImage: "info.circle").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                Divider()
                layoutControls
                if let take = model.selectedTake {
                    Divider()
                    TakeInspector(model: model, take: take)
                } else {
                    Divider()
                    correctionControls
                }
            }.padding(20)
        }.background(Theme.panel.opacity(0.65))
    }

    private var inputControls: some View {
        Group {
            devicePicker("Camera", selection: $model.cameraID, choices: model.cameras, icon: "video")
                .onChange(of: model.cameraID) { _, _ in model.devicesChanged() }
            devicePicker("Guitar input", selection: $model.audioID, choices: model.audioInputs, icon: "waveform")
                .onChange(of: model.audioID) { _, _ in model.devicesChanged() }
        }
    }
    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("INPUT LEVEL").font(.system(size: 9, weight: .semibold))
                Spacer()
                Text(model.level > 0.98 ? "CLIPPING" : model.level > 0.002 ? "SIGNAL" : "NO SIGNAL")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(model.level > 0.98 ? Color.red : Theme.muted)
            }
            GeometryReader { geometry in
                let fraction = CGFloat(max(Float(0), (20 * log10(max(model.level, 0.001)) + 60) / 60))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(model.level > 0.98 ? Color.red : Theme.accent).frame(width: geometry.size.width * fraction)
                }
            }.frame(height: 5)
        }
    }
    private var outputControls: some View {
        Group {
            devicePicker("Playback output", selection: $model.outputID, choices: model.audioOutputs, icon: "speaker.wave.2")
            Button {
                if model.isConnected { model.disconnect() } else { model.connect() }
            } label: {
                Label(model.isConnected ? "Disconnect devices" : "Connect devices", systemImage: model.isConnected ? "checkmark.circle.fill" : "cable.connector")
                    .frame(maxWidth: .infinity).padding(.vertical, 3)
            }.buttonStyle(.bordered).disabled(model.locked || model.cameraID.isEmpty || model.audioID.isEmpty)
        }
    }
    private var layoutControls: some View {
        Group {
            sectionLabel("VIDEO ARRANGEMENT")
            Picker("Layout", selection: Binding(get: { model.project.layout }, set: { value in model.edit { $0.layout = value } })) {
                ForEach(VideoLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().disabled(!model.hasProject || model.locked)
            Text("Overlapping takes appear together. Solo sections use the full frame.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
        }
    }
    private var correctionControls: some View {
        Group {
            sectionLabel("TIMING")
            HStack {
                Text("Audio correction").font(.system(size: 11)); Spacer()
                CommitNumber(value: model.defaultAudioOffsetMS) { model.defaultAudioOffsetMS = min(2000, max(-2000, $0)) }
                    .frame(width: 58)
                Text("ms").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.disabled(model.locked)
            Text("Applies to new takes. Negative values bring the guitar audio earlier. Select a take to adjust it after recording.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
        }
    }

    private func devicePicker(_ title: String, selection: Binding<String>, choices: [DeviceChoice], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Picker(title, selection: selection) {
                if choices.isEmpty { Text("No devices found").tag("") }
                ForEach(choices) { Text($0.name).tag($0.id) }
            }.labelsHidden().disabled(model.locked)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle().fill(model.isRecording ? Color.red : Theme.accent).frame(width: 5, height: 5)
            Text(model.busy ?? (model.isBuilding ? "Updating preview…" : model.message)).font(.system(size: 10)).lineLimit(1)
            if model.busy?.hasPrefix("Exporting") == true {
                ProgressView(value: model.exportProgress).frame(width: 90)
                Button("Cancel", action: model.cancelExport).buttonStyle(.plain)
            }
            Spacer()
            Text("SPACE  PLAY / STOP     R  RECORD").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
        }.foregroundStyle(Theme.muted).padding(.horizontal, 20).frame(height: 30).background(Theme.panel)
    }
}

func sectionLabel(_ text: String) -> some View {
    Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Theme.muted)
}

func timecode(_ value: Double) -> String {
    let milliseconds = Int(max(0, value.isFinite ? value : 0) * 1000)
    return String(format: "%02d:%02d.%03d", milliseconds / 60000, (milliseconds / 1000) % 60, milliseconds % 1000)
}

struct PlayerPreview: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.videoGravity = .resizeAspect; view.player = player
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { nsView.player = player }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraView { CameraView(session: session) }
    func updateNSView(_ nsView: CameraView, context: Context) { }
}

final class CameraView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero); wantsLayer = true
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
}

struct WindowGuard: NSViewRepresentable {
    let model: SessionModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = context.coordinator }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { }
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: SessionModel
        init(model: SessionModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if model.locked { model.error = "Stop recording and wait for saving, or cancel the export, before closing the studio."; return false }
            return true
        }
    }
}
