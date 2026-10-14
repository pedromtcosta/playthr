import SwiftUI
import PlaythrCore

struct TakeInspector: View {
    @ObservedObject var model: SessionModel
    let take: Take
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("SELECTED TAKE")
                Spacer()
                Button { model.selectedTrackID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            TextField("Take name", text: Binding(get: { take.name }, set: { value in model.editTake(take.id) { $0.name = value } }))
                .textFieldStyle(.roundedBorder)
            numberField("Timeline start", value: take.start, suffix: "sec") { value in model.editTake(take.id) { $0.start = max(0, value) } }
            if let regions = take.regions {
                Text("\(regions.count) remaining part(s). Use the timeline range controls to trim or cut these parts.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else {
            numberField("Trim in", value: take.sourceIn, suffix: "sec") { value in
                model.editTake(take.id) {
                    $0.sourceIn = max(0, min(value, $0.sourceDuration - 0.05))
                    $0.duration = min($0.duration, $0.sourceDuration - $0.sourceIn)
                }
            }
            numberField("Length", value: take.duration, suffix: "sec") { value in
                model.editTake(take.id) { $0.duration = max(0.05, min(value, $0.sourceDuration - $0.sourceIn)) }
            }
            }
            numberField("Audio correction", value: take.audioOffset * 1000, suffix: "ms") { value in
                model.editTake(take.id) { $0.audioOffset = max(-2000, min(2000, value)) / 1000 }
            }
            Text("Select a Scene to arrange or hide this video for that portion of the timeline.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack {
                if take.regions == nil {
                    Button("Reset trim") { model.editTake(take.id) { $0.sourceIn = 0; $0.duration = $0.sourceDuration } }
                }
                Spacer()
                Button(role: .destructive) {
                    model.deleteTrack(take.id)
                } label: { Image(systemName: "trash") }.help("Remove from timeline. Original media stays in the project; Undo restores the take.")
            }.buttonStyle(.borderless)
        }.disabled(model.locked)
    }
    private func numberField(_ title: String, value: Double, suffix: String, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 11)); Spacer()
            CommitNumber(value: value, set: set).frame(width: 64)
            Text(suffix).font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 22, alignment: .leading)
        }
    }
}

struct CommitNumber: View {
    let value: Double
    let set: (Double) -> Void
    var fractionDigits: Int = 3
    var updatesWhileEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $draft).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            .focused($focused)
            .onAppear { reset() }
            .onChange(of: draft) { _, text in
                if updatesWhileEditing, focused, let number = Double(text), number.isFinite { set(number) }
            }
            .onChange(of: value) { _, _ in if !focused { reset() } }
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onSubmit { commit(); focused = false }
    }
    private func reset() { draft = String(format: "%.*f", fractionDigits, value) }
    private func commit() { if let number = Double(draft), number.isFinite { set(number) }; reset() }
}

struct RoutingView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Hear your tone. Record your tone.", systemImage: "waveform.path").font(.title2)
            Text("Use BlackHole 2ch to send only Neural DSP’s processed guitar into Playthr.").foregroundStyle(Theme.muted)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26).background(Theme.accent.opacity(0.16), in: Circle()).foregroundStyle(Theme.accent)
                    Text(step).font(.system(size: 13)).lineSpacing(4)
                }
            }
            Text("Playthr does not monitor the captured input back to your speakers. Listen through Neural DSP’s output so you do not hear an extra delayed copy. Use headphones to avoid acoustic spill if you select a microphone.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(4)
            HStack {
                Link("BlackHole routing guide", destination: URL(string: "https://github.com/ExistentialAudio/BlackHole/wiki/Multi-Output-Device")!)
                Spacer()
                Button("Got it") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 620).background(Theme.panel).preferredColorScheme(.dark)
    }
    private let steps = [
        "In Audio MIDI Setup, create a Multi-Output Device containing your audio interface and BlackHole 2ch. Use a common sample rate (48 kHz is a good starting point) and configure drift correction for the secondary device.",
        "In Neural DSP standalone, keep your guitar interface as the input and select that Multi-Output Device as the output. If your plugin only offers one device selector, use a configured interface loopback or a routing host that sends the tone to both destinations. An Aggregate Device alone does not duplicate outputs.",
        "In Playthr, select your webcam, BlackHole 2ch as Guitar input, and your physical interface as Playback output. Keep macOS system sound on the physical interface too.",
        "Connect devices and strum: the input meter should move. Play the backing with your guitar silent: the meter should stay quiet. If it moves, backing audio is leaking into BlackHole.",
        "Record a short test at a clear beat. Review it, then adjust the take’s Audio correction if needed. A negative correction advances late guitar audio; positive delays it."
    ]
}
