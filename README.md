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
8. Select a **Scene** in the timeline to arrange its videos, then **Export video**. Export creates a 1920 × 1080, 30 fps MP4 with the backing tracks and all audible takes. Sections without visible takes are black. The full project duration is exported.

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

The inspector has **Record**, **Scene**, and **Take** tabs. Recording setup stays in Record; selecting a take opens its timing/audio controls; selecting a Scene opens the arrangement for that time range.

Every track header has a **trash button**. It removes a backing track or a recorded take (its linked audio and video) from the timeline and saves immediately. **⌘Z** restores it; **⇧⌘Z** redoes the deletion. Deletion, trim and position changes are non-destructive: source media stays in the project. Undo history is available within the current session and is not persisted across launches. Mix/layout changes pause playback while rebuilding the preview. Mute and Solo affect audio only; Scene visibility controls the image separately.

### Scenes

A Scene is a time range with its own video selection, layout, and stacking order. The blue Scene lane appears above the media tracks. Scenes never overlap and can have gaps between them; the tracks underneath keep their own timing and audio mix. Sections without a Scene show black video while their audio continues, in both preview and export.

- **Automatic creation:** saving a new take creates a Scene for its recorded range, with a default arrangement of the videos that overlap it. That interval replaces the covered portions of existing Scenes. Portions to the left and right keep their arrangements. This one operation handles nested recordings, partial overlaps, and recordings that span multiple Scenes.
- **Manual creation:** drag across the timeline ruler (or enter From/to), then click **Create Scene**. A new Scene starts with the default arrangement set in **Record → New Scenes**; it can combine several existing Scenes into one range. This does not cut or move media.
- **Boundaries:** click a Scene, then drag its left/right edge or enter exact From/To seconds in its inspector. Expanding takes time from neighboring Scenes; shrinking gives time back to adjacent neighbors while preserving their layouts. If there is no adjacent neighbor, the released portion becomes a gap without video.
- **Deletion:** click the trash button beside the Scene name in its inspector, or right-click its timeline block and choose **Delete Scene**. Its interval becomes a gap without video; media, audio, other Scenes, and the timeline duration stay intact. Deletion autosaves, **⌘Z** restores the Scene, and gaps remain after reopening or editing the project. You can delete every Scene and still play or export the audio with a black picture. Select a gap and choose **Create Scene** to show its videos again.
- **Arrangement:** choose **Side by side**, **Top & bottom**, or **Picture in picture**. Click a video frame in the paused preview, drag it to move, and drag its lower-right handle to resize. The outline follows your gesture; releasing commits the edit and updates the picture. Exact Left/Top/Width/Height percentages are available in the inspector. Videos fit their rectangles without changing aspect ratio.
- **Visibility and layers:** the Scene's video list is ordered front to back. Uncheck a video to omit its picture only in that Scene; its audio keeps playing. Select a video and use **Back/Forward** to change its order. In picture-in-picture, the backmost video fills the frame and the others become insets. **Full frame** expands the selected video's rectangle; it does not hide other layers.

For a five-minute take followed by a recording from 2:10 to 3:05, the Scene ranges become 0:00–2:10, 2:10–3:05, and 3:05–5:00. A later recording from 2:50 to 3:50 replaces that range, producing boundaries at 0:00, 2:10, 2:50, 3:50, and 5:00.

A Scene can include a video whose footage covers only part of its range. That video appears only where recorded material exists; its position is reserved throughout the Scene, so other videos do not jump or resize when it ends. A clock icon marks videos without footage at the playhead. Moving/trimming a take keeps Scene boundaries and existing video selections in place; use the Scene's checkboxes to include a take in another Scene. All-track **Close gap** cuts shift Scene boundaries along with the media.

Scenes autosave and support Undo/Redo. Older projects are converted in memory to Scenes matching their existing picture, and the next edit saves format version 3. Source recordings remain intact. The same composition renders the Scene arrangements in preview and export. There are no animation keyframes, effects, or transitions yet.

### Cut a time range

1. **Drag across the timeline ruler** to select a time range, in either direction. A click still seeks. Alternatively enable **Range tool** and drag on a track; this also selects that track. You can enter exact **From / to** times in seconds.
2. Under **Apply to**, choose the selected track or **All tracks**. Click a track header to change the selected track.
3. **Leave gap** removes the selected material while keeping later material at its current time. **Close gap** removes it and moves later material left by the selected duration on the affected track(s). Choosing All tracks keeps the remaining backing stems and guitar parts aligned.

The remaining pieces stay on the same track with the same volume, solo/mute, audio correction and video layout. Recorded audio and video are cut together. Cuts affect playback and export, save automatically, and can be undone/redone with **⌘Z / ⇧⌘Z**. Cutting an entire track's content leaves its empty row; use its trash button to remove the row. Clear a time selection with **×**. Turn off Range tool to drag a recorded take and move its remaining pieces together.

After cutting a take into pieces, use the range controls for further trimming. The original source file stays intact. The project format is versioned so older builds cannot silently ignore range edits or Scenes.

## Project files and recovery

```text
Song.playthr/
  project.json             # versioned timeline, scenes, mix, waveforms and placements
  Media/
    <uuid>.wav             # copied backing tracks (original format preserved)
    <uuid>.mov             # camera H.264 + stereo 48 kHz float PCM audio
    .background.mov        # small generated background for video gaps
```

Import copies media into the project; Sound Razor's originals are never modified. Copy or move the entire `.playthr` package to move the project. In Finder, **Show Package Contents** reveals its files. Saving atomically replaces the manifest. Exports use a temporary file and are moved to the chosen filename only after success; existing exports are not overwritten.

Projects use regular media files contained in their `Media` directory. Linked project files, special files, and reference movies that load media from another file are rejected, including during recovery and background rendering. To bound processing of shared projects, timelines and source media are limited to 24 hours, `project.json` to 16 MiB, and each Sound Razor metadata JSON file to 1 MiB.

**Project → Recover takes** finds readable MOV files that are not listed in the manifest, including finalized recordings whose manifest save failed. Recovered takes are placed at the current playhead because the original start position may be unknown. This also finds deliberately removed takes. Original files are kept even if recovery fails. Fragmented recording improves the chances of recovery after interruption, but an unfinished recording is not guaranteed to be readable.

The app reports capture/write failures and writer backpressure drops. Keep enough free disk space: original takes use H.264 video and uncompressed stereo audio. A disconnected device, disk failure, forced quit or power loss can interrupt capture. Normal window close and Quit are blocked while recording, saving, importing or exporting.

## Implementation and verification

- `PlaythrCore`: project validation/storage, Sound Razor import, waveform analysis, capture writer, shared preview/export composition.
- `Playthr`: SwiftUI studio, AVFoundation capture devices, Core Audio output selection, transport and project workflow.
- A shared composition builder drives preview and export. Media and Scene boundaries determine active videos; each Scene supplies visibility, rectangles, and layer order. The video instructions and background preserve the exact media duration, including fractional audio sample boundaries, and are validated before playback/export.
- Tests cover portable save/load, missing media, unsafe paths, invalid trims, Sound Razor split metadata, solo/mute, offsets and layout geometry. Count-in tests measure generated clicks at integer and fractional tempos, check the recording boundary and zero-count setting, and verify cancellation leaves no empty take. Integration tests generate real audio/video through the recorder, export overlapping takes, and check rendered pixels, duration and audio presence, including gaps and picture-in-picture layering. A playback regression covers 44.1 kHz backing audio ending between timeline ticks and camera frames starting after the audio.

Automated tests use synthetic media and do not activate your camera or microphone. Your webcam, USB/BlackHole route, actual output latency and a long recording still need a hardware acceptance pass. The first release is a focused local prototype, not a general-purpose DAW or video editor.

For a repeatable visual smoke test, preserve an integration-test project in a **new** directory and use a debug bundle:

```sh
PLAYTHR_TEST_ARTIFACTS="$PWD/TestArtifacts" swift test --disable-sandbox --filter MediaTests.testRecordingAndOverlappingVideoExport
bash scripts/build.sh debug
open -n -F -W .build/Playthr-Debug.app \
  --stdout "$PWD/TestArtifacts/smoke.log" --stderr "$PWD/TestArtifacts/smoke-errors.log" \
  --args --ui-smoke-project "$PWD/TestArtifacts/Session.playthr" --ui-smoke-output "$PWD/TestArtifacts/studio.png" --ui-smoke-test-delete
```

This opens the studio, loads generated media, plays it muted, verifies native video rendering, captures its own window content, and exits. `--ui-smoke-test-delete` exercises delete/autosave/undo/redo on each track and restores the original timeline; use this flag on a disposable test project. The check does not connect capture devices. A normal release build does not include this command-line test behavior.

Add `--ui-smoke-test-count-in` to check live metronome output: it audibly plays four clicks at 120 BPM, checks the rendered beat timing and selected output device, then cancels another count-in after its first click. It also verifies that zero counts bypass the audio engine. This optional check uses speakers/headphones, with no camera or microphone access.

Add `--ui-smoke-test-cuts` on a disposable project with backing audio and a take to verify all six combinations of track scope and gap behavior, autosave, rebuilt previews, undo/redo and source preservation. It restores the original timeline after capturing the window. Automated range tests also check repeated edits and old/new project formats, then export real media to verify the removed picture and sound and the shifted source content.

Add `--ui-smoke-test-scenes` on a disposable project with two overlapping takes to verify Scene creation, selection, resizing, local visibility, custom placement, stacking order, autosave, and Undo/Redo. Native mouse events also verify frame dragging and corner resizing. It restores the initial project after capturing the Scene editor. Core tests cover the recording overlap examples, interval partitioning, shrinking/expanding, cuts and migration. Render tests compare scene-specific side-by-side, stacked, inset, hidden, and custom-positioned video in both preview and MP4 export, including preserved guitar audio and videos ending inside a Scene.

Add `--ui-smoke-test-delete-scenes` on a disposable project with Scenes to check deletion, preserved gaps and audio tracks, cleared selection, autosave/reload, Undo/Redo, and native playback with every Scene removed. It restores the original project after capturing the window. Render tests also verify black gaps and a completely black timeline in preview and exported MP4, with the full audio mix preserved.
