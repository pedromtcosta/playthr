# Playthr

A local Mac recording and editing studio for layered guitar playthroughs. Import a backing song or Sound Razor stems, choose a timeline position, record your webcam and processed guitar together, layer another part, and export the performance.

## Run

Requires macOS 14 or later and Xcode / Swift 6 to build. There are no third-party packages, servers, accounts, or downloads. FFmpeg is not required.

```sh
bash scripts/build.sh
bash scripts/run.sh
```

The app is created at `.build/Playthr.app`. You can open that bundle in Finder or copy it to Applications. Use the app bundle rather than `swift run`: the bundle includes the camera/microphone privacy descriptions and a stable app identifier. The build script signs it locally; it is not a notarized distribution build. macOS requests camera and microphone access when you click **Connect devices**.

For development:

```sh
swift test --disable-sandbox
bash scripts/build.sh debug
```

The debug bundle is `.build/Playthr-Debug.app`, with a separate app identifier so it can run beside the regular app. Rebuilds stage a fresh bundle without rewriting a running executable.

## Record a playthrough

1. **Create project** and choose where to save its `.playthr` folder. Changes are saved automatically.
2. **Import backing → Sound Razor song / stems folder**. Choose a song under `../sound-razor/projects`, its `stems` directory, or another folder of aligned audio files. Individual audio files can also be imported together. All backing tracks begin at zero.
3. Mute the original guitar stem(s) you want to replace. Set backing levels with the track sliders. **M** mutes audio; **S** solos audio across backing tracks and takes. The master volume is included in the export.
4. Select your camera, **Guitar input**, and **Playback output**. USB inputs and virtual inputs such as BlackHole are discovered through macOS. Select the input carrying your processed guitar tone. Click **Connect devices** and check the preview and meter.
5. Click the timeline ruler or enter a position in **Go to** (seconds). Set the count-in **BPM** and number of **counts**, then press **Record** (`R`). You hear that many metronome clicks through **Playback output**; the backing and recording begin on the next beat. For example, 4 counts at 120 BPM take 2 seconds. Set counts to **0** to skip the count-in. Tempo and count are remembered across launches.
6. Press **Stop & save** or Space. The take is saved at the starting playhead position; the playhead returns there for review or another pass. Record another guitar at the same position to layer parts.
7. Review with Space. Click a take to inspect it, drag it to move it, or enter exact start/trim/length values. Audio and video remain linked. Set **Audio correction** to compensate for your audio route's latency without moving the video.
8. Choose a video arrangement, then **Export video**. Export creates a 1920 × 1080, 30 fps MP4 with the backing tracks and all audible takes. Sections without visible takes are black. The full project duration is exported.

## Getting the Neural DSP tone into the recorder

The interface brand is not required by Playthr. USB identifies the connection; the device's inputs determine which signal is available. A physical guitar input often supplies the dry signal. Use an interface loopback input or BlackHole when you want Neural DSP's processed output.

For a Neural DSP setup with separate input and output device selectors:

- Keep the physical interface as Neural DSP's input.
- Create a **Multi-Output Device** containing the physical interface and BlackHole 2ch in Audio MIDI Setup. Set compatible sample rates and enable drift correction for the non-clock device, following the [BlackHole guide](https://github.com/ExistentialAudio/BlackHole/wiki/Multi-Output-Device).
- Select that Multi-Output Device as Neural DSP's output so you can hear the tone and send it to BlackHole.
- In Playthr, select **BlackHole 2ch** as Guitar input and the **physical interface** as Playback output. Keep macOS system output on the physical interface as well. The BlackHole guide's system-wide output step is unnecessary for this workflow.

Some Neural DSP versions offer a single audio-device selector. An Aggregate Device exposes several devices' channels, but does **not** duplicate audio to every output. In that case use a configured interface loopback or a routing host capable of sending the processed guitar to both your monitors and BlackHole. The app works with either route. See [Neural DSP audio settings](https://neuraldsp.com/getting-started/setting-up-your-plugin) and [BlackHole Aggregate Devices](https://github.com/ExistentialAudio/BlackHole/wiki/Aggregate-Device).

Strum with playback stopped: the input meter should move. Then play the backing while your guitar is silent: the input meter should stay quiet. If backing audio enters the recording input, each take will contain another copy of the backing. Playthr prevents choosing exactly the same input and playback device, but cannot detect every routing path inside aggregate or multi-output devices.

Playthr does not monitor its live input back to the output. Listen through your existing Neural DSP monitoring route. It records a stereo stream; BlackHole 2ch is the straightforward choice. Arbitrary channel-pair mapping on multichannel interfaces is not implemented.

## Timing and editing

Camera and audio are captured in the same `AVCaptureSession`. A chosen host-clock instant is translated to the session's synchronization clock for the recorder; primed playback is aligned to that instant at the end of the count-in. Metronome clicks are generated ahead of time and scheduled on that same host clock through the selected playback device, with the device's reported output latency taken into account. The on-screen number shows beats remaining. Clicks stop before the take begins and are not included in the project mix or export. Captured timestamps, not the UI refresh timer, determine media timing. The recorder trims audio buffers that cross the start boundary.

The count-in supports 20–400 BPM and 0–64 beats, with a higher first click. Press **Cancel count-in**, Space, or `R` before recording starts to silence the clicks and cancel without saving an empty take.

Your interface, output buffers and Neural DSP can still add latency. Record a short passage with a clear beat and adjust **Audio correction** after listening. Negative milliseconds bring recorded audio earlier; positive milliseconds delay it. This adjustment trims the affected edge of the audio within the take's video interval. The setup correction applies to new takes; each saved take has its own correction. There is no automatic latency measurement or calibration claim.

**Side by side**, **Top & bottom**, and **Picture in picture** adapt to the takes active at each point. A single active take fills the frame. In picture-in-picture mode, higher layers become insets; **Bring to front / inset** changes that order. **Custom positions** uses the selected take's position and size, normalized to the output canvas. Images fit inside their rectangles with their original aspect ratio. There are no animation keyframes, effects or transitions yet.

Every track header has a **trash button**. It removes a backing track or a recorded take (its linked audio and video) from the timeline and saves immediately. **⌘Z** restores it; **⇧⌘Z** redoes the deletion. Deletion, trim and position changes are non-destructive: source media stays in the project. Undo history is available within the current session and is not persisted across launches. Mix/layout changes pause playback while rebuilding the preview. Mute and Solo affect audio only; **Show video** controls the image separately.

### Cut a time range

1. **Drag across the timeline ruler** to select a time range, in either direction. A click still seeks. Alternatively enable **Range tool** and drag on a track; this also selects that track. You can enter exact **From / to** times in seconds.
2. Under **Apply to**, choose the selected track or **All tracks**. Click a track header to change the selected track.
3. **Leave gap** removes the selected material while keeping later material at its current time. **Close gap** removes it and moves later material left by the selected duration on the affected track(s). Choosing All tracks keeps the remaining backing stems and guitar parts aligned.

The remaining pieces stay on the same track with the same volume, solo/mute, audio correction and video layout. Recorded audio and video are cut together. Cuts affect playback and export, save automatically, and can be undone/redone with **⌘Z / ⇧⌘Z**. Cutting an entire track's content leaves its empty row; use its trash button to remove the row. Clear a time selection with **×**. Turn off Range tool to drag a recorded take and move its remaining pieces together.

After cutting a take into pieces, use the range controls for further trimming. The original source file stays intact. Existing projects load as before; the first cut saves version 2 of the project format so older builds cannot accidentally ignore the edits.

## Project files and recovery

```text
Song.playthr/
  project.json             # versioned timeline, mix, waveform peaks and placements
  Media/
    <uuid>.wav             # copied backing tracks (original format preserved)
    <uuid>.mov             # camera H.264 + stereo 48 kHz float PCM audio
    .background.mov        # small generated background for video gaps
```

Import copies media into the project; Sound Razor's originals are never modified. Copy or move the entire `.playthr` package to move the project. In Finder, **Show Package Contents** reveals its files. Saving atomically replaces the manifest. Exports use a temporary file and are moved to the chosen filename only after success; existing exports are not overwritten.

**Project → Recover takes** finds readable MOV files that are not listed in the manifest, including finalized recordings whose manifest save failed. Recovered takes are placed at the current playhead because the original start position may be unknown. This also finds deliberately removed takes. Original files are kept even if recovery fails. Fragmented recording improves the chances of recovery after interruption, but an unfinished recording is not guaranteed to be readable.

The app reports capture/write failures and writer backpressure drops. Keep enough free disk space: original takes use H.264 video and uncompressed stereo audio. A disconnected device, disk failure, forced quit or power loss can interrupt capture. Normal window close and Quit are blocked while recording, saving, importing or exporting.

## Implementation and verification

- `PlaythrCore`: project validation/storage, Sound Razor import, waveform analysis, capture writer, shared preview/export composition.
- `Playthr`: SwiftUI studio, AVFoundation capture devices, Core Audio output selection, transport and project workflow.
- A shared composition builder drives preview and export. Timeline interval boundaries determine active videos; per-take placement and layer order support future editing features. The video instructions and background preserve the exact media duration, including fractional audio sample boundaries, and are validated before playback/export.
- Tests cover portable save/load, missing media, unsafe paths, invalid trims, Sound Razor split metadata, solo/mute, offsets and layout geometry. Count-in tests measure generated clicks at integer and fractional tempos, check the recording boundary and zero-count setting, and verify cancellation leaves no empty take. Integration tests generate real audio/video through the recorder, export overlapping takes, and check rendered pixels, duration and audio presence, including gaps and picture-in-picture layering. A playback regression covers 44.1 kHz backing audio ending between timeline ticks and camera frames starting after the audio.

Automated tests use synthetic media and do not activate your camera or microphone. Your webcam, USB/BlackHole route, actual output latency and a long recording still need a hardware acceptance pass. The first release is a focused local prototype, not a general-purpose DAW or video editor.

For a repeatable visual smoke test, preserve an integration-test project in a **new** directory and use a debug bundle:

```sh
PLAYTHR_TEST_ARTIFACTS="$PWD/TestArtifacts" swift test --disable-sandbox --filter MediaTests.testRecordingAndOverlappingVideoExport
bash scripts/build.sh debug
.build/Playthr-Debug.app/Contents/MacOS/Playthr --ui-smoke-project "$PWD/TestArtifacts/Session.playthr" --ui-smoke-output "$PWD/TestArtifacts/studio.png" --ui-smoke-test-delete
```

This opens the studio, loads generated media, plays it muted, verifies native video rendering, captures its own window content, and exits. `--ui-smoke-test-delete` exercises delete/autosave/undo/redo on each track and restores the original timeline; use this flag on a disposable test project. The check does not connect capture devices. A normal release build does not include this command-line test behavior.

Add `--ui-smoke-test-count-in` to check live metronome output: it audibly plays four clicks at 120 BPM, checks the rendered beat timing and selected output device, then cancels another count-in after its first click. It also verifies that zero counts bypass the audio engine. This optional check uses speakers/headphones, with no camera or microphone access.

Add `--ui-smoke-test-cuts` on a disposable project with backing audio and a take to verify all six combinations of track scope and gap behavior, autosave, rebuilt previews, undo/redo and source preservation. It restores the original timeline after capturing the window. Automated range tests also check repeated edits and old/new project formats, then export real media to verify the removed picture and sound and the shifted source content.
