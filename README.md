# EP-2350 Agent for macOS

A native SwiftUI menu-bar controller for Teenage Engineering EP-2350 microphones.
Hold the handle, speak, and release; MacWhisper transcribes the audio and the app
inserts the transcript into your focused coding-agent app. Custom sample tones trigger
eight configurable keyboard actions. Speech **does not press Enter**.

This is a focused Swift recreation of
[tajchert/tink-agent](https://github.com/tajchert/tink-agent), not a Python wrapper.
MacWhisper is the only external runtime dependency.

The general name covers the Ting and MicFx variants without assuming they have
identical factory samples or firmware. The supplied tone pack comes from the
upstream Ting setup; it does not depend on the factory sounds. MicFx compatibility
has not yet been verified on physical hardware. Confirm its configuration format
and back up its files before installing the pack.

## Requirements

- macOS 14 or newer; Xcode 16 or newer with Swift 6.
- MacWhisper with its bundled `mw` command-line interface and an available model.
- An EP-2350 configured with the supplied tone samples and compatible presets.
- Microphone analog line-out connected to an audio input, normally a USB audio adapter.
- Microphone and Accessibility permission for the built EP-2350 Agent app.

Ting's USB-C port mounts its configuration disk; it is **not** a USB audio or
button-event connection. Handle state is inferred from audio, not read digitally.

## Build and run

Open `EP2350Agent.xcodeproj`, select the **EP2350Agent** scheme and **My Mac**, choose
your signing team if required, and run. The microphone icon appears in the menu
bar; there is no Dock icon or main window. Choose **Settings...** from the menu.
The app starts paused and does not ask for microphone access until you resume.

Command-line build:

```sh
xcodebuild -project EP2350Agent.xcodeproj -scheme EP2350Agent \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
open "DerivedData/Build/Products/Debug/EP-2350 Agent.app"
```

For ongoing use, build/sign in Xcode and keep the app at a consistent location so
macOS permissions attach to a stable app identity. Release notarization and
installers are not part of this MVP.

The checked-in Xcode project is generated from `project.yml`. If changing targets
or file membership, regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
```

XcodeGen is a development tool, not an app dependency. The checked-in project
allows building without installing it.

### Scout code search

Scout is an optional development tool, not an app or CI dependency. With the
Scout CLI installed, attach this checkout to index Swift code, tests, and
project documentation:

```sh
scout attach .
scout ensure-fresh .
scout search "tone detection" --limit 5
```

Repository search exclusions are checked in at `.scout/scout.config.yaml`.
Scout respects `.gitignore`, stores its index under `~/.scout`, and watches
the checkout for changes. Attaching also installs local Copilot hooks; if
Scout's MCP tools are not already registered, run `scout setup --mcp-target copilot`.

Inference uses your machine's Scout settings. A configured embedding server
receives indexed code chunks, queries, and reranking snippets. For local-only
inference, select `scout admin embedding set bundled` and restart the Scout
daemon before attaching; this changes the machine-wide Scout setting.

## Set up the EP-2350 tone pack

The procedure below is the upstream **Ting** procedure, not a hardware-verified
MicFx installation guide. Disk naming and configuration compatibility should be
checked on your model before proceeding.

1. Back up any existing Ting configuration and samples.
2. Connect Ting by USB-C and power it on to mount `TINGDISK`.
3. Copy **the contents** of `EP2350Agent/Resources/TingConfig/` to the root of
   `TINGDISK`: `config.json` and `1.wav` through `4.wav`.
4. Power-cycle Ting. Files are loaded only at boot.
5. For normal use, disconnect USB-C, run Ting on batteries, and connect its
   analog line-out to the USB audio adapter.

The Settings **Setup** tab can reveal the same files inside the app bundle.
The app never modifies the hardware disk itself. These fixed-pitch SAMPLE
presets prevent handle-driven pitch modulation from smearing the cues.

| Sample | Global slot | Frequency | Default |
|---|---:|---:|---|
| A1 | 1 | 1500 Hz | Enter |
| A2 | 2 | 2300 Hz | Escape |
| A3 | 3 | 3100 Hz | Control-C |
| A4 | 4 | 3900 Hz | Shift-Tab |
| B1 | 5 | 2751 Hz | Up |
| B2 | 6 | 4218 Hz | Down |
| B3 | 7 | 5685 Hz | No action |
| B4 | 8 | 7153 Hz | No action |

In the upstream Ting setup, the green sample selector chooses A1-A4 or B1-B4 and the white play
control triggers the selected sample. The orange mode selector sets A (no mode LED) or B (first
mode LED). Mode B shifts the four samples up 10.5 semitones.
Keyboard shortcuts, `yes`, `continue`, `/clear`, `/compact`, and custom
text-plus-Enter macros are available in the **Actions** tab.

## Settings and permissions

Select the USB audio adapter in **Audio**, save, and resume listening. The first
available input named `USB Audio Device` is suggested on initial setup. Selection
is persisted by stable Core Audio UID. The app never silently switches to another
microphone when the selected device disappears.

Grant **Microphone** and **Accessibility** under System Settings > Privacy &
Security. Missing permissions and input failures appear in the menu/Settings.
Saving settings pauses capture and cancels pending output; resume explicitly.

### Choose an output destination

The **Output** tab offers two modes. **Foreground app** is the default and
preserves the existing behavior: the app focused when speech begins must stay
focused throughout capture and transcription.

Choose **Fixed target app**, then **Choose Target Application...** to select
Ghostty or another installed app. If Safety has a nonempty allowlist, explicitly
add the target there (or use **Allow** in Output) before saving. Save and resume
listening. The menu shows the saved destination; unsaved choices are not used.

In fixed-target mode you can dictate while working in another app. Only when a
transcript is ready, or before a mapped keyboard action, does EP-2350 Agent
activate the selected app. It confirms the exact running process is frontmost,
waiting up to two seconds. Output goes to that app's most recently active
window/tab/pane; there is no terminal-session selection or automatic focus
restoration. Keep the intended Ghostty terminal selected.

The target must already be running. A closed target, ambiguous running
instances, rejected activation, timeout, permission failure, or target exit
blocks output rather than sending it to another app. Blocked transcripts remain
available through **Copy Last Transcript**. Once activation is confirmed,
switching away during output stops the remaining keys even if you switch back.
The app does not repeatedly reactivate the target during a single delivery.
Transcripts still do not press Enter; mapped macros retain their existing
text-plus-Enter behavior.

Activation and keyboard output share one delivery gate. Actions arriving while
output is being prepared or inserted are rejected visibly, not deferred, so an
Enter cue cannot unexpectedly submit a partial prompt. Tone Test and **No
action** slots never activate another app.

### Test tones without sending actions

In **Audio**, select your adapter and save. Open **Tone Test** and choose
**Start Tone Test**, then play the microphone samples in modes A and B.
The input meter and newest-first history show the detected global slot (1-8),
mode/sample slot, matched detector frequency, and its **saved** action mapping,
including custom text and **No action** slots. Unsaved edits are not used.
The history holds the most recent 20 detections in memory and can be cleared.

Tone Test never sends keys, changes the clipboard, or transcribes speech, and
does not require Accessibility permission or a working MacWhisper installation.
Microphone permission and a live audio input are still required. You can keep
Settings focused throughout the test. The usual tone debounce applies, so one
sustained tone is reported once.

Starting Tone Test pauses normal capture and cancels pending output. **Stop Tone
Test** stops capture but keeps the safe test mode selected; **Exit Tone Test**
returns to normal mode **paused**, requiring an explicit resume. The mode is
not persisted across launches. Displayed frequencies are the detector's matched
targets, not measurements of arbitrary input tones.

MacWhisper's default executable is:

```text
/Applications/MacWhisper.app/Contents/MacOS/mw
```

Confirm your installation supports the CLI:

```sh
/Applications/MacWhisper.app/Contents/MacOS/mw transcribe --help
/Applications/MacWhisper.app/Contents/MacOS/mw models list
```

Leave **Model override** and **Language override** blank to use MacWhisper's
current selections. Model overrides use its `engine:model-id` format; language
overrides use an ISO code such as `en`, or `auto`. Download/select models in
MacWhisper; this app does not change MacWhisper's preferences.

The app writes a temporary 16 kHz mono WAV and invokes `mw` directly, without a
shell. It reads the complete UTF-8 transcript file, including multiple lines,
rather than parsing CLI status output. Requests time out after 120 seconds.
One request runs at a time with at most two waiting utterances; overflow is
reported, not silently accepted.

## Output safety and privacy

- Transcripts are inserted without Enter. Submit with the microphone Enter action.
- In foreground mode the app records the target process at voice onset and blocks automatic output
  if focus changes during capture/transcription, including switching away and
  back. It never activates another app in this mode.
- Fixed-target mode explicitly activates the selected running app immediately
  before delivery and establishes a fresh focus guard. Changes of focus before
  that activation do not block delivery; changes during output do.
- **Safety** optionally restricts output to exact application bundle identifiers.
  An empty list allows any eligible focused app. EP-2350 Agent and MacWhisper are
  excluded even with an empty list.
- Actions check focus, the allowlist, and Accessibility immediately before
  dispatch. Unicode text is chunked without splitting surrogate pairs and
  rechecks the guard between chunks. A focus change during insertion can leave
  partial text in the original target; remaining output is stopped.
- Actions during activation or ongoing text insertion are rejected visibly so an Enter cue
  cannot submit a partially inserted prompt.
- Pausing, saving settings, input failures, or system sleep invalidate pending
  deliveries. Resume after waking.
- Blocked transcripts remain in memory for manual **Copy Last Transcript**.
  Clear them from the menu. Automatic typing does not change the clipboard;
  Copy and the explicit Paste action do.
- Audio/transcript temporary files are cleaned up after success, failure,
  cancellation, and timeout. No app-owned transcript history or activity log is
  written. MacWhisper is invoked without `--persist`.
- MacWhisper controls the transcription engine and its privacy characteristics.
  Select a local model there if you require on-device processing.

Settings are stored atomically at:

```text
~/Library/Application Support/TinkAgent/settings.json
```

The legacy settings directory and bundle identifier `io.github.garthdb.TinkAgent`
are intentionally retained across the rename so existing settings and permission
identity are preserved. Keep the renamed app consistently signed and located;
macOS may still require permission approval when an app's signature or path changes.

Invalid stored settings are reported and listening remains disabled until you
review and explicitly save Settings. There is no automatic import of the Python
app's `~/.tink-agent/config.json`.

## Architecture

`EP2350Core` contains configuration/actions, Goertzel tone detection, energy-based
voice gating, WAV encoding, and delivery policy. The app contains selected-device
Core Audio capture, AVFoundation sample-rate conversion, the MacWhisper process
adapter, bounded AppKit target activation, Quartz output, and SwiftUI menu/settings.

The audio callback uses preallocated bounded storage. A serial worker converts
audio into 800-sample (50 ms) blocks at 16 kHz and runs tone detection before
voice gating. Tone blocks do not enter the speech buffer. Speech requires at
least 400 ms of voiced audio, closes after 800 ms of quiet/tone-only audio, and
is bounded to 30 seconds of elapsed audio.

UI/output are main-actor isolated. Transcription runs off the audio/UI paths.
Selected-device disconnects, format changes, and capture overflow stop capture
with an explicit error rather than falling back to another input.

## Tests

```sh
swift test --package-path Packages/EP2350Core
xcodebuild -project EP2350Agent.xcodeproj -scheme EP2350Agent \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Tests use synthetic audio, upstream regression recordings, mock CLI processes,
and injected audio/keyboard/focus/permission boundaries. They do not need an EP-2350,
MacWhisper model, or permission to record/type. Physical hardware, real MacWhisper
transcription, and actual cross-app keyboard delivery still need a manual check
on the user's configured system.

GitHub Actions runs these tests for pull requests and pushes to `main` on a
`macos-15` runner with Xcode 16.4. The workflow also regenerates the checked-in
Xcode project with XcodeGen and fails if the generated project differs from
`project.yml`. CI does not sign or publish the app and needs no secrets, EP-2350
hardware, MacWhisper installation/model, microphone access, or Accessibility
permission. Hardware behavior, real transcription, microphone permission, and
cross-app keyboard delivery remain manual acceptance checks.

This MVP does not include login startup, alternate STT backends, transcript
history, automated microphone disk installation, or direct coding-agent APIs. The app
is intentionally not App Sandbox enabled because it invokes the external CLI
and synthesizes cross-app keyboard events.

## Attribution

The Ting configuration/samples, regression recordings, and documented signal
processing behavior come from MIT-licensed `tajchert/tink-agent`, revision
`7d5be444bc9f525725148b5efdd226cb10c02ee7`. Its license is preserved in
[`ThirdPartyNotices.txt`](EP2350Agent/Resources/ThirdPartyNotices.txt) and bundled
with the app.

This project is independent and is not affiliated with or endorsed by Teenage
Engineering or MacWhisper.
