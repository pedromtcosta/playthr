import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import PlaythrCore

enum InspectorTab: String, CaseIterable { case record = "Record", scene = "Scene", take = "Take" }

@MainActor
final class SessionModel: ObservableObject {
    @Published private(set) var project = Project()
    @Published private(set) var store: ProjectStore?
    @Published var selectedTrackID: UUID?
    @Published var selectedSceneID: UUID?
    @Published var selectedSceneVideoID: UUID?
    @Published var inspectorTab = InspectorTab.record
    @Published var selectedRange: TimelineRange?
    @Published var isSelectingRange = false
    @Published var cutAllTracks = false
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var isRecording = false
    @Published var isCountingIn = false
    @Published var isConnected = false
    @Published var isBuilding = false
    @Published var busy: String?
    @Published var message = "Create a project, import your stems, and make a take."
    @Published var error: String?
    @Published var level: Float = 0
    @Published var countdown: Int = 0
    @Published var exportProgress: Float = 0
    @Published var cameras: [DeviceChoice] = []
    @Published var audioInputs: [DeviceChoice] = []
    @Published var audioOutputs: [DeviceChoice] = []
    @Published var cameraID = UserDefaults.standard.string(forKey: "cameraID") ?? ""
    @Published var audioID = UserDefaults.standard.string(forKey: "audioID") ?? ""
    @Published var outputID = UserDefaults.standard.string(forKey: "outputID") ?? ""
    @Published private(set) var countInBPM: Double = 120
    @Published private(set) var countInCounts: Int = 4
    @Published var defaultAudioOffsetMS: Double = UserDefaults.standard.double(forKey: "audioOffsetMS")
    let player = AVPlayer()
    let capture = CaptureEngine()
    private var observer: Any?
    private var ticker: Timer?
    private var rebuildTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var recordingPath: String?
    private var recordingStart: Double = 0
    private var recordingAnchor: Double = 0
    private var activeCountIn: CountIn?
    private let countInPlayer = CountInPlayer()
    private var recordTask: Task<Void, Never>?
    private var undoHistory: [Project] = []
    private var redoHistory: [Project] = []
    var locked: Bool { isRecording || busy != nil }
    var hasProject: Bool { store != nil }
    var hasVisibleVideo: Bool { project.takes.contains { project.showsVideo($0) } }
    var canExportVideo: Bool { hasProject && project.duration > 0 && (project.scenes != nil || hasVisibleVideo) }
    var timelineDuration: Double { max(30, project.duration + 3, playhead + 3) }
    var selectedTake: Take? { project.takes.first { $0.id == selectedTrackID } }
    var selectedScene: VideoScene? { project.scenes?.first { $0.id == selectedSceneID } }
    var canCreateScene: Bool { !locked && hasProject && selectedRange != nil }
    var isEditingScene: Bool {
        inspectorTab == .scene && !locked && !isPlaying && (selectedScene?.contains(playhead) ?? false)
    }
    var selectedTrackName: String? {
        project.tracks.first { $0.id == selectedTrackID }?.name ?? selectedTake?.name
    }
    var canCutRange: Bool {
        !locked && selectedRange != nil && (selectedRange?.start ?? 0) < project.duration && (cutAllTracks || selectedTrackName != nil)
    }
    var activeRecordingStart: Double { recordingStart }
    var canUndo: Bool { !locked && !undoHistory.isEmpty }
    var canRedo: Bool { !locked && !redoHistory.isEmpty }

    init() {
        let defaults = UserDefaults.standard
        if let bpm = defaults.object(forKey: "countInBPM") as? Double, CountIn.bpmRange.contains(bpm) { countInBPM = bpm }
        if let counts = defaults.object(forKey: "countInCounts") as? Int, CountIn.countRange.contains(counts) { countInCounts = counts }
        player.automaticallyWaitsToMinimizeStalling = false
        refreshDevices()
        capture.onLevel = { [weak self] value in DispatchQueue.main.async { self?.level = value } }
        capture.onFailure = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isRecording { self.stopRecording() }
                self.isConnected = false
                self.error = text
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.04, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isRecording, self.isPlaying else { return }
                self.playhead = max(0, time.seconds.isFinite ? time.seconds : 0)
                if self.playhead >= self.project.duration - 0.04 { self.pause() }
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - self.recordingAnchor
                if let countIn = self.activeCountIn {
                    self.countdown = countIn.remainingBeats(elapsed: elapsed + countIn.duration)
                }
                self.playhead = self.recordingStart + max(0, elapsed)
            }
        }
    }

    func refreshDevices() {
        cameras = Devices.inputs(.video)
        audioInputs = Devices.inputs(.audio)
        audioOutputs = Devices.outputs()
        if !cameras.contains(where: { $0.id == cameraID }) { cameraID = cameras.first?.id ?? "" }
        if !audioInputs.contains(where: { $0.id == audioID }) {
            audioID = audioInputs.first { $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") }?.id ?? audioInputs.first?.id ?? ""
        }
        if !audioOutputs.contains(where: { $0.id == outputID }) { outputID = Devices.defaultOutputID() ?? audioOutputs.first?.id ?? "" }
    }

    func connect() {
        guard !locked else { return }
        pause(); busy = "Connecting devices…"; isConnected = false
        let camera = cameraID, audio = audioID
        Task {
            defer { busy = nil }
            do {
                try await capture.connect(cameraID: camera, audioID: audio)
                isConnected = true
                UserDefaults.standard.set(camera, forKey: "cameraID")
                UserDefaults.standard.set(audio, forKey: "audioID")
                message = "Devices connected. Play your guitar and check the input meter."
            } catch { self.error = error.localizedDescription }
        }
    }

    func devicesChanged() { if isConnected { capture.disconnect(); isConnected = false; level = 0 } }
    func disconnect() { guard !locked else { return }; capture.disconnect(); isConnected = false; level = 0 }

    func newProject() {
        guard !locked else { return }
        let panel = NSSavePanel()
        panel.title = "Create a Playthr project"
        panel.nameFieldStringValue = "My playthrough.playthr"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let url = selected.pathExtension == "playthr" ? selected : selected.appendingPathExtension("playthr")
        do {
            let newStore = try ProjectStore.create(at: url, name: url.deletingPathExtension().lastPathComponent)
            setProject(try newStore.load(), store: newStore)
            message = "Project created. Import a Sound Razor song or individual audio files."
        } catch { self.error = error.localizedDescription }
    }

    func openProject(url: URL? = nil) {
        guard !locked else { return }
        var selected = url
        if selected == nil {
            let panel = NSOpenPanel()
            panel.title = "Open a Playthr project"
            panel.canChooseDirectories = true; panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK else { return }
            selected = panel.url
        }
        guard var root = selected else { return }
        if root.lastPathComponent == "project.json" { root.deleteLastPathComponent() }
        do {
            let newStore = ProjectStore(root: root)
            setProject(try newStore.load(), store: newStore)
            let orphans = try newStore.unregisteredMovies(in: project)
            message = orphans.isEmpty ? "Project opened. All changes save automatically." : "\(orphans.count) unlisted movie(s) found in Media. Use Recover takes to add finalized recordings."
        } catch { self.error = error.localizedDescription }
    }

    private func setProject(_ newProject: Project, store newStore: ProjectStore) {
        pause(); rebuildTask?.cancel(); player.replaceCurrentItem(with: nil)
        var migrated = newProject; migrated.enableScenes()
        store = newStore; project = migrated; selectedTrackID = nil; selectedRange = nil; cutAllTracks = false; playhead = 0
        selectedSceneID = nil; selectedSceneVideoID = nil; inspectorTab = .record
        undoHistory = []; redoHistory = []
        scheduleRebuild()
    }

    func importAudio(soundRazor: Bool) {
        guard !locked, let store else { return }
        pause()
        let panel = NSOpenPanel()
        panel.title = soundRazor ? "Choose a Sound Razor song or stems folder" : "Import backing tracks"
        panel.canChooseDirectories = soundRazor; panel.canChooseFiles = !soundRazor
        panel.allowsMultipleSelection = !soundRazor
        if soundRazor {
            let sibling = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appendingPathComponent("sound-razor/projects")
            if FileManager.default.fileExists(atPath: sibling.path) { panel.directoryURL = sibling }
        } else { panel.allowedContentTypes = [.audio] }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        busy = "Importing audio and reading waveforms…"
        Task {
            defer { busy = nil }
            do {
                let imported = try await Task.detached(priority: .userInitiated) { () -> (String?, [BackingTrack]) in
                    let song = soundRazor ? try SoundRazorImport.inspect(urls[0]) : nil
                    let sources = song?.stems.map { ($0.name, $0.url) } ?? urls.map { ($0.deletingPathExtension().lastPathComponent, $0) }
                    var tracks: [BackingTrack] = []
                    for (name, url) in sources {
                        let info = try await Media.inspectAudio(url)
                        let file = try store.copyMedia(from: url)
                        tracks.append(BackingTrack(name: name, file: file, duration: info.duration, peaks: info.peaks))
                    }
                    return (song?.title, tracks)
                }.value
                var draft = project
                if draft.tracks.isEmpty, let name = imported.0 { draft.name = name }
                draft.tracks += imported.1
                try commit(draft)
                message = "Imported \(imported.1.count) tracks. Mute the guitar parts you want to replace."
            } catch { self.error = error.localizedDescription }
        }
    }

    func edit(_ action: (inout Project) -> Void) {
        guard !locked else { return }
        pause()
        var draft = project; action(&draft)
        do { try commit(draft) } catch { self.error = error.localizedDescription }
    }
    func editTake(_ id: UUID, _ action: (inout Take) -> Void) {
        edit { project in
            if let index = project.takes.firstIndex(where: { $0.id == id }) {
                let previous = project.takes[index]
                action(&project.takes[index])
                if let regions = previous.regions, previous.start != project.takes[index].start {
                    let delta = project.takes[index].start - previous.start
                    project.takes[index].regions = regions.map { region in
                        var moved = region; moved.start += delta; return moved
                    }
                }
            }
        }
    }

    func selectTrack(_ id: UUID) {
        guard !locked, project.tracks.contains(where: { $0.id == id }) || project.takes.contains(where: { $0.id == id }) else { return }
        selectedTrackID = id; cutAllTracks = false
        if selectedTake != nil { inspectorTab = .take }
    }

    func selectScene(_ id: UUID, seekToStart: Bool = true) {
        guard !locked, let scene = project.scenes?.first(where: { $0.id == id }) else { return }
        selectedSceneID = id; inspectorTab = .scene
        selectedSceneVideoID = scene.videos.last(where: \.visible)?.takeID
        if seekToStart { seek(scene.start) }
    }

    func createSceneFromSelection() {
        guard canCreateScene, let range = selectedRange else { return }
        pause()
        do {
            var draft = project
            let id = try draft.createScene(in: range)
            try commit(draft); selectedRange = nil; selectScene(id)
            message = "Scene created. Arrange its videos in the preview or Scene inspector. ⌘Z to undo."
        } catch { self.error = error.localizedDescription }
    }

    func resizeScene(_ id: UUID, start: Double, end: Double) {
        guard !locked, let range = TimelineRange(start: max(0, start), end: min(project.duration, end)) else { return }
        do {
            var draft = project; try draft.resizeScene(id, to: range); try commit(draft)
            selectScene(id, seekToStart: false)
            if !(selectedScene?.contains(playhead) ?? false) { seek(range.start) }
        } catch { self.error = error.localizedDescription }
    }

    func deleteScene(_ id: UUID) {
        guard !locked else { return }
        pause()
        do {
            var draft = project
            guard try draft.deleteScene(id) else { return }
            try commit(draft)
            message = "Scene deleted. Its range now has no video; audio keeps playing. ⌘Z to undo."
        } catch { self.error = error.localizedDescription }
    }

    func editScene(_ id: UUID, _ action: (inout VideoScene) -> Void) {
        edit { project in
            if let index = project.scenes?.firstIndex(where: { $0.id == id }) { action(&project.scenes![index]) }
        }
    }

    func setSceneVideoVisible(_ takeID: UUID, sceneID: UUID, visible: Bool) {
        editScene(sceneID) { scene in
            if let index = scene.videos.firstIndex(where: { $0.takeID == takeID }) { scene.videos[index].visible = visible }
            else { scene.videos.append(SceneVideo(takeID: takeID, visible: visible, placement: Placement(x: 0.65, y: 0.65, width: 0.3, height: 0.3))) }
            scene.applyLayout(scene.layout)
        }
        selectedSceneVideoID = takeID
    }

    func setScenePlacement(_ placement: Placement, takeID: UUID, sceneID: UUID) {
        guard [placement.x, placement.y, placement.width, placement.height].allSatisfy(\.isFinite) else { return }
        var p = placement
        p.width = min(1, max(0.01, p.width)); p.height = min(1, max(0.01, p.height))
        p.x = min(1 - p.width, max(0, p.x)); p.y = min(1 - p.height, max(0, p.y))
        editScene(sceneID) { scene in
            guard let index = scene.videos.firstIndex(where: { $0.takeID == takeID }) else { return }
            scene.videos[index].placement = p; scene.layout = .custom
        }
    }

    func reorderSceneVideo(_ takeID: UUID, sceneID: UUID, forward: Bool) {
        editScene(sceneID) { scene in
            guard let index = scene.videos.firstIndex(where: { $0.takeID == takeID }) else { return }
            let next = index + (forward ? 1 : -1)
            guard scene.videos.indices.contains(next) else { return }
            scene.videos.swapAt(index, next); scene.applyLayout(scene.layout)
        }
    }

    func selectRange(from: Double, to: Double, trackID: UUID? = nil) {
        guard !locked, hasProject, from.isFinite, to.isFinite else { return }
        pause()
        if let trackID { selectTrack(trackID) }
        let start = max(0, min(project.duration, min(from, to)))
        let end = max(0, min(project.duration, max(from, to)))
        selectedRange = TimelineRange(start: start, end: end)
    }

    func setRangeStart(_ value: Double) {
        guard value.isFinite, project.duration > 0 else { return }
        let start = min(max(0, value), max(0, project.duration - 0.001))
        selectRange(from: start, to: max(start + 0.001, selectedRange?.end ?? min(start + 1, project.duration)))
    }

    func setRangeEnd(_ value: Double) {
        guard value.isFinite, project.duration > 0 else { return }
        let end = min(project.duration, max(0.001, value))
        selectRange(from: min(selectedRange?.start ?? playhead, max(0, end - 0.001)), to: end)
    }

    func cutSelection(closeGap: Bool) {
        guard canCutRange, let range = selectedRange else { return }
        pause()
        var draft = project
        let target = cutAllTracks ? "all tracks" : (selectedTrackName ?? "the track")
        do {
            guard try draft.cut(range, trackID: cutAllTracks ? nil : selectedTrackID, closeGap: closeGap) else {
                message = "There is no material to cut in that range."; return
            }
            try commit(draft)
            playhead = min(range.start, project.duration)
            selectedRange = nil
            message = "Cut \(String(format: "%.3f", range.duration)) sec from \(target) · \(closeGap ? "gap closed" : "timing kept"). ⌘Z to undo."
        } catch { self.error = error.localizedDescription }
    }
    func deleteTrack(_ id: UUID) {
        guard !locked, let name = project.tracks.first(where: { $0.id == id })?.name
                ?? project.takes.first(where: { $0.id == id })?.name else { return }
        pause()
        var draft = project
        draft.tracks.removeAll { $0.id == id }
        draft.takes.removeAll { $0.id == id }
        do {
            try commit(draft)
            if selectedTrackID == id { selectedTrackID = nil }
            message = "Deleted \(name) from the timeline. Undo restores it; the original media is kept."
        } catch { self.error = error.localizedDescription }
    }
    private func commit(_ draft: Project, history: Bool = true) throws {
        guard let store else { return }
        var draft = draft; draft.reconcileScenes()
        guard draft != project else { return }
        try store.save(draft)
        if history { undoHistory.append(project); if undoHistory.count > 80 { undoHistory.removeFirst() }; redoHistory = [] }
        project = draft
        if !project.takes.contains(where: { $0.id == selectedTrackID }) && !project.tracks.contains(where: { $0.id == selectedTrackID }) { selectedTrackID = nil }
        if !((project.scenes ?? []).contains { $0.id == selectedSceneID }) { selectedSceneID = nil; selectedSceneVideoID = nil }
        scheduleRebuild()
    }
    func undo() {
        guard canUndo, let previous = undoHistory.last else { return }
        do { let current = project; try commit(previous, history: false); undoHistory.removeLast(); redoHistory.append(current) }
        catch { self.error = error.localizedDescription }
    }
    func redo() {
        guard canRedo, let next = redoHistory.last else { return }
        do { let current = project; try commit(next, history: false); redoHistory.removeLast(); undoHistory.append(current) }
        catch { self.error = error.localizedDescription }
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        guard let store else { return }
        pause(); isBuilding = true
        let snapshot = project
        rebuildTask = Task {
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let built = try await CompositionBuilder.build(project: snapshot, store: store)
                try Task.checkCancellation()
                guard snapshot == project else { return }
                player.replaceCurrentItem(with: built.playerItem())
                playhead = min(playhead, project.duration)
                if project.duration > 0 { await player.seek(to: CompositionBuilder.time(playhead), toleranceBefore: .zero, toleranceAfter: .zero) }
                try Task.checkCancellation()
                isBuilding = false
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                player.replaceCurrentItem(with: nil); isBuilding = false; self.error = error.localizedDescription
            }
        }
    }

    func seek(_ position: Double) {
        guard !locked else { return }
        pause(); playhead = max(0, min(position, max(project.duration, 30)))
        player.seek(to: CompositionBuilder.time(min(playhead, project.duration)), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func pause() { player.pause(); isPlaying = false }
    func togglePlay() {
        if isRecording { stopRecording(); return }
        guard !locked, !isBuilding, project.duration > 0 else { return }
        if isPlaying { pause(); return }
        if playhead >= project.duration { seek(0) }
        player.audioOutputDeviceUniqueID = outputID.isEmpty ? nil : outputID
        UserDefaults.standard.set(outputID, forKey: "outputID")
        player.play(); isPlaying = true
    }

    func setCountInBPM(_ value: Double) {
        guard !locked, value.isFinite else { return }
        countInBPM = (min(CountIn.bpmRange.upperBound, max(CountIn.bpmRange.lowerBound, value)) * 10).rounded() / 10
        UserDefaults.standard.set(countInBPM, forKey: "countInBPM")
    }

    func setCountInCounts(_ value: Double) {
        guard !locked, value.isFinite else { return }
        countInCounts = Int(min(Double(CountIn.countRange.upperBound), max(0, value)).rounded())
        UserDefaults.standard.set(countInCounts, forKey: "countInCounts")
    }

    func record() {
        if isRecording { stopRecording(); return }
        guard !locked, !isBuilding, let store else { return }
        guard isConnected else { error = "Connect your camera and processed-guitar input before recording."; return }
        guard outputID != audioID else { error = "Choose a playback output other than the recording input. Sending backing tracks into BlackHole would record them into every take."; return }
        pause(); busy = "Preparing recording…"
        recordTask = Task {
            var captureArmed = false
            do {
                let countIn = try CountIn(bpm: countInBPM, counts: countInCounts)
                try countInPlayer.prepare(countIn, outputID: outputID)
                if project.duration > 0 {
                    player.audioOutputDeviceUniqueID = outputID.isEmpty ? nil : outputID
                    try await waitForPlayer()
                    await player.seek(to: CompositionBuilder.time(min(playhead, project.duration)), toleranceBefore: .zero, toleranceAfter: .zero)
                    if playhead < project.duration { try await preroll() }
                }
                let (path, url) = try store.newTakePath()
                recordingStart = playhead
                // Leave time to arm the writer and schedule the first audible beat.
                let firstBeat = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CompositionBuilder.time(0.5))
                let anchor = CMTimeAdd(firstBeat, CompositionBuilder.time(countIn.duration))
                recordingAnchor = anchor.seconds
                try await capture.begin(url: url, hostAnchor: anchor)
                captureArmed = true
                try countInPlayer.start(at: firstBeat)
                activeCountIn = countIn; countdown = countIn.counts; isCountingIn = true
                recordingPath = path; isRecording = true; busy = nil
                UserDefaults.standard.set(defaultAudioOffsetMS, forKey: "audioOffsetMS")
                // Do not call setRate with a future time: AVPlayer plays preceding content immediately.
                // Audio clicks are already scheduled; this wait only releases backing playback.
                while CMClockGetTime(CMClockGetHostTimeClock()).seconds < recordingAnchor {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                try Task.checkCancellation()
                if recordingStart < project.duration {
                    player.audioOutputDeviceUniqueID = outputID.isEmpty ? nil : outputID
                    player.setRate(1, time: CompositionBuilder.time(recordingStart), atHostTime: anchor)
                }
                isCountingIn = false; countdown = 0
                countInPlayer.stop()
                message = "Recording a new take. Previous takes are preserved."
            } catch is CancellationError { } // Stop already silenced the count-in and owns capture cleanup.
            catch {
                countInPlayer.stop()
                if captureArmed { await capture.cancel() }
                recordingPath = nil; isRecording = false; isCountingIn = false; countdown = 0; activeCountIn = nil
                busy = nil; self.error = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        guard isRecording, let path = recordingPath, let store else { return }
        let cancelledCountIn = CMClockGetTime(CMClockGetHostTimeClock()).seconds < recordingAnchor
        recordTask?.cancel(); countInPlayer.stop(); player.pause(); isPlaying = false
        isRecording = false; isCountingIn = false; countdown = 0; activeCountIn = nil
        busy = cancelledCountIn ? "Cancelling count-in…" : "Saving take…"; recordingPath = nil
        let start = recordingStart
        Task {
            defer { busy = nil }
            if cancelledCountIn {
                await capture.cancel()
                playhead = start
                message = "Count-in cancelled. Press Record when you’re ready."
                return
            }
            do {
                let warning = try await capture.finish()
                let url = try store.mediaURL(path)
                let duration = try await Media.inspectTake(url)
                var take = Take(name: "Guitar \(project.takes.count + 1)", file: path, start: start, duration: duration,
                                layer: (project.takes.map(\.layer).max() ?? -1) + 1)
                take.audioOffset = defaultAudioOffsetMS / 1000
                take.peaks = (try await Media.inspectAudio(url)).peaks
                var draft = project; let sceneID = try draft.addTake(take)
                try commit(draft)
                selectedTrackID = take.id; playhead = start
                selectedSceneID = sceneID; selectedSceneVideoID = take.id; inspectorTab = .scene
                message = warning ?? "Take saved. Press Play to review, or Record to layer another guitar."
            } catch {
                self.error = "\(error.localizedDescription) Any captured file remains in the project’s Media folder. Use Recover takes if it is readable."
            }
        }
    }

    private func waitForPlayer() async throws {
        for _ in 0..<200 {
            try Task.checkCancellation()
            if player.currentItem?.status == .readyToPlay { return }
            if player.currentItem?.status == .failed { throw player.currentItem?.error ?? PlaythrError.message("Backing playback failed.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw PlaythrError.message("Playback did not become ready. Reopen the project and check its media files.")
    }

    private func preroll() async throws {
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { player.cancelPendingPrerolls() }
        }
        defer { timeout.cancel() }
        let ready = await withCheckedContinuation { continuation in
            player.preroll(atRate: 1) { continuation.resume(returning: $0) }
        }
        guard ready else { throw PlaythrError.message("Playback could not be primed for recording. Check the playback output and try again.") }
    }

    func exportVideo() {
        guard !locked, let store, canExportVideo else { return }
        pause()
        let panel = NSSavePanel()
        panel.title = "Export combined playthrough"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = project.name + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = project
        busy = "Exporting 1080p video…"; exportProgress = 0
        exportTask = Task {
            defer { busy = nil; exportTask = nil }
            do {
                let built = try await CompositionBuilder.build(project: snapshot, store: store)
                try await CompositionBuilder.export(built, to: url) { value in DispatchQueue.main.async { self.exportProgress = value } }
                message = "Exported \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = error.localizedDescription }
        }
    }
    func cancelExport() { exportTask?.cancel() }

    func recoverTakes() {
        guard !locked, let store else { return }
        pause(); busy = "Recovering saved movies…"
        Task {
            defer { busy = nil }
            do {
                let files = try store.unregisteredMovies(in: project)
                var draft = project; var recovered = 0; var unreadable = 0
                for url in files {
                    guard let duration = try? await Media.inspectTake(url) else { unreadable += 1; continue }
                    var take = Take(name: "Recovered take \(recovered + 1)", file: "Media/" + url.lastPathComponent,
                                    start: playhead, duration: duration, layer: draft.takes.count)
                    take.peaks = (try? await Media.inspectAudio(url))?.peaks ?? []
                    try draft.addTake(take); recovered += 1
                }
                if recovered > 0 { try commit(draft) }
                message = "Recovered \(recovered) take(s) at the playhead. \(unreadable) unfinished movie(s) could not be read; their files were kept."
            } catch { self.error = error.localizedDescription }
        }
    }
}
