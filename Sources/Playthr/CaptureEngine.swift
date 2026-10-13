import AVFoundation
import CoreAudio
import PlaythrCore

struct DeviceChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

enum Devices {
    static func inputs(_ type: AVMediaType) -> [DeviceChoice] {
        let kinds: [AVCaptureDevice.DeviceType] = type == .video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(deviceTypes: kinds, mediaType: type, position: .unspecified).devices
            .map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
    }
    static func outputs() -> [DeviceChoice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            return DeviceChoice(id: uid, name: name)
        }
    }
    static func defaultOutputID() -> String? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, selector: kAudioDevicePropertyDeviceUID)
    }
    static func outputDeviceID(uniqueID: String) -> AudioDeviceID? {
        let uid = uniqueID.isEmpty ? defaultOutputID() : uniqueID
        guard let uid else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { string($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }
    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }
}

final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "playthr.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var writer: TakeWriter?
    private var videoSize: CMVideoDimensions?
    private var lastVideoTime: Double = 0
    private var lastAudioTime: Double = 0
    private var lastMeterTime: Double = 0
    private var runtimeObserver: NSObjectProtocol?
    private var failureReported = false
    private var watchdog: DispatchSourceTimer?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?

    override init() {
        super.init()
        runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onFailure?(error?.localizedDescription ?? "The capture device stopped. Reconnect your camera and audio input.")
        }
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            guard let self, self.writer != nil, !self.failureReported else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if now - self.lastAudioTime > 2 || now - self.lastVideoTime > 2 {
                self.failureReported = true
                self.onFailure?("A capture device stopped sending data. The take will be finalized; reconnect devices before recording again.")
            }
        }
        watchdog.resume(); self.watchdog = watchdog
    }
    deinit { watchdog?.cancel(); if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) } }

    func connect(cameraID: String, audioID: String) async throws {
        for media in [AVMediaType.video, .audio] {
            let status = AVCaptureDevice.authorizationStatus(for: media)
            if status == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: media) else { throw permissionError(media) }
            } else if status != .authorized { throw permissionError(media) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard writer == nil else { throw PlaythrError.message("Stop recording before changing devices.") }
                    session.stopRunning()
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    for input in session.inputs { session.removeInput(input) }
                    for output in session.outputs { session.removeOutput(output) }
                    videoSize = nil; lastVideoTime = 0; lastAudioTime = 0; failureReported = false
                    guard let camera = AVCaptureDevice(uniqueID: cameraID), let audio = AVCaptureDevice(uniqueID: audioID) else {
                        throw PlaythrError.message("A selected device is unavailable. Refresh the device list and select it again.")
                    }
                    for device in [camera, audio] {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw PlaythrError.message("Cannot use \(device.localizedName) for capture.") }
                        session.addInput(input)
                    }
                    if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                    else if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    videoOutput.setSampleBufferDelegate(self, queue: queue)
                    audioOutput.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                                                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
                    audioOutput.setSampleBufferDelegate(self, queue: queue)
                    for output in [videoOutput as AVCaptureOutput, audioOutput] {
                        guard session.canAddOutput(output) else { throw PlaythrError.message("Cannot connect capture outputs.") }
                        session.addOutput(output)
                    }
                    // Match a supported 30 fps format without assuming every webcam offers it.
                    if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                        try camera.lockForConfiguration()
                        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        camera.unlockForConfiguration()
                    }
                    // startRunning must occur after commitConfiguration's defer.
                    queue.async {
                        self.session.startRunning()
                        if self.session.isRunning { continuation.resume() }
                        else { continuation.resume(throwing: PlaythrError.message("Capture did not start. Check that another app is not using the webcam.")) }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func disconnect() {
        queue.async { [self] in if writer == nil { session.stopRunning(); videoSize = nil } }
    }

    func begin(url: URL, hostAnchor: CMTime) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    guard writer == nil, session.isRunning, let dimensions = videoSize,
                          now - lastVideoTime < 2, now - lastAudioTime < 2, let clock = session.synchronizationClock else {
                        throw PlaythrError.message("Camera and audio must both be receiving data. Connect devices, wait for the preview, and try again.")
                    }
                    let anchor = CMSyncConvertTime(hostAnchor, from: CMClockGetHostTimeClock(), to: clock)
                    failureReported = false
                    writer = try TakeWriter(url: url, anchor: anchor, width: Int(dimensions.width), height: Int(dimensions.height))
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func finish() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let recording = writer, let clock = session.synchronizationClock else {
                    continuation.resume(throwing: PlaythrError.message("No recording is active.")); return
                }
                writer = nil
                recording.finish(at: CMClockGetTime(clock)) { continuation.resume(with: $0) }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                writer?.cancel()
                writer = nil
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let isVideo = output === videoOutput
        if isVideo {
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer) { videoSize = CMVideoFormatDescriptionGetDimensions(description) }
            lastVideoTime = now
        } else {
            lastAudioTime = now
            if now - lastMeterTime >= 0.08 {
                let power = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
                onLevel?(max(0, min(1, pow(10, power / 20))))
                lastMeterTime = now
            }
        }
        writer?.append(sampleBuffer, video: isVideo)
        if let error = writer?.failure, !failureReported { failureReported = true; onFailure?(error.localizedDescription) }
    }

    private func permissionError(_ type: AVMediaType) -> Error {
        PlaythrError.message("Allow Playthr to use your \(type == .video ? "camera" : "microphone") in System Settings → Privacy & Security, then reconnect devices.")
    }
}
