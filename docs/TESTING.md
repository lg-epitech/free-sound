# Architecture and validation

## Architecture

FreeSound is a native SwiftUI view hosted in an AppKit window, with a menu bar item. `LSUIElement` and the accessory activation policy keep it out of the Dock. Closing the window hides it; quitting tears down audio processing. Launch at login uses `SMAppService.mainApp` and follows the same startup path, including showing the mixer.

| Component | Responsibility |
| --- | --- |
| `FreeSoundApp.swift` | Application lifecycle, window, menu bar item, read-only JSON diagnostics, and view snapshots. |
| `Views/MixerView.swift` | System and app controls, favorites, filtering, meters, and errors. |
| `Models/AudioController.swift` | Main-thread coordination, process grouping, device discovery, route reconciliation, and login item registration. Devices and processes refresh every 1.5 seconds. |
| `Models/AudioPreferences.swift` | JSON preferences in `UserDefaults`, keyed by application bundle identity. Stores volume, mute, balance, route UID, favorite, boost, and window options. |
| `Audio/SystemAudio.swift` | Core Audio hardware queries and writable default-device, volume, and mute properties. |
| `Audio/ProcessAudioEngine.swift` | One private stereo process tap and aggregate device for each adjusted app. The selected output supplies the clock; Core Audio drift compensation synchronizes the tap. Physical microphone streams in duplex hardware are disabled for the route. |
| `AudioDSP/AudioDSP.c` | A preallocated C audio callback with atomic controls, gain smoothing, balance, channel mapping, mono downmix, sample bounds, and a peak meter. No allocation or locks in the render callback. |

An app at its default mix does not need a tap. Once an adjustment requires processing, the controller creates a route and the tap mutes the app's original stream only while it is being read. Disabling controls, resetting the mix, or quitting stops routes. A missing saved output falls back to the system output; reconnecting it triggers route reconciliation. These are implementation behaviors to validate with actual playback, not evidence that every driver handles them correctly.

## Check status

Recorded during initial implementation on an Apple Silicon Mac with Swift 6.3 and Command Line Tools, without full Xcode:

| Check | Recorded status |
| --- | --- |
| Build/run script shell syntax and help output | Passed. |
| Info.plist and entitlement plist validation | Passed. |
| Native icon generation and visual inspection | Passed. |
| Full release build and local bundle signature | Passed. |
| C DSP checks | All five groups passed with AddressSanitizer and UndefinedBehaviorSanitizer, including the final run after engine fixes. |
| Preference checks | All 12 checks passed. |
| Live read-only Core Audio checks | Passed: five devices, four readable volume capabilities, four mute capabilities, and five sample rates. Audio process counts varied from 39 to 41 as processes changed. No live settings changed. |
| JSON diagnostics and native mixer snapshot | Executed; snapshot visually inspected. |
| Native UI interaction | Opened the output device menu, expanded balance/boost controls, searched for Arc, toggled a favorite and restored it, and verified Quit. |
| Live synthetic process-tap routes | Passed to WH-1000XM4 at 44.1 kHz and MacBook Pro Speakers at 48 kHz: captured signal, half gain, mute, clean teardown, and unchanged default output. See measured results below. |
| Listening, app first-run permission flow, device switching/disconnects, sleep recovery, login item | Not yet manually verified. |

Update this table only after executing the corresponding check. A successful build or a moving meter does not establish that sound reaches the intended output. An active I/O callback also does not establish that capture permission was granted.

## Automated checks

```sh
./scripts/test.sh
./scripts/build.sh
./dist/FreeSound.app/Contents/MacOS/FreeSound --diagnostics
```

`scripts/test.sh` compiles standalone C and Swift programs. This avoids the XCTest dependency, which is unavailable with the installed Command Line Tools alone. The C program runs with AddressSanitizer and UndefinedBehaviorSanitizer.

The checks cover synthetic interleaved and planar audio, disabled microphone stream offsets, preferred output channels, gain, balance, mono, mute smoothing, short input buffers, sample bounds, nonfinite values, preference persistence, normalization, and default settings that do not require processing. The live Core Audio check reads device/process properties, validates IDs and capabilities, and repeats discovery. These checks do not create process taps or change live audio devices.

`--diagnostics` lists real Core Audio devices, defaults, and process objects without starting the app controller or any audio tap. It can confirm enumeration, not routing.

For layout inspection, quit FreeSound and run:

```sh
./dist/FreeSound.app/Contents/MacOS/FreeSound --snapshot /tmp/FreeSound.png
```

This opens the normal app, captures its own content view after startup, and exits. It uses saved preferences, so disable app controls before taking a snapshot if you want to avoid activating saved routes. Inspect the image for clipped labels, usable device menus, error text, and the small-window layout.

## Optional live engine check

```sh
./scripts/audio-smoke-test.sh
./scripts/audio-smoke-test.sh --built-in
```

The script creates and locally signs a disposable **FreeSound Audio Check** app in `.build/audio-smoke`. macOS may request system audio recording permission for this test app. It starts a separate synthetic audio source at −100 dBFS, taps only that process, checks half gain and mute, then releases the route and exits. It does not tap the user's applications or change hardware volume or the default output.

Without arguments, the check routes to the existing default output. With `--built-in`, the synthetic source continues using that default while the test engine redirects it to built-in speakers. The check requires a measured captured signal; an I/O callback alone is insufficient to pass.

Final recorded results used WH-1000XM4 as the source's existing default output:

| Route | Output sample rate | Expected peak at half gain | Measured peak | Result |
| --- | --- | --- | --- | --- |
| WH-1000XM4 → WH-1000XM4 | 44,100 Hz | `5e-6` | `5.000042e-6` | Passed. |
| WH-1000XM4 → MacBook Pro Speakers | 48,000 Hz | `5e-6` | `5.0000463e-6` | Passed. |

Both runs also passed mute, clean teardown, and unchanged-default checks. These results establish live signal processing and routing through the engine on these two devices. They do not replace listening tests, establish first-run permission behavior for the main app, or validate disconnect/sleep recovery.

## Manual hardware checklist

Start at a comfortable hardware volume with two applications playing different, easily identifiable audio. Record the macOS version, app build, application names, output devices, sample rates, and observed result for each case.

| Case | Procedure and expected observation |
| --- | --- |
| System controls | Switch output, input, and sound-effects devices. Confirm macOS reports the same defaults. Adjust supported output/input hardware volume and mute. Sound effects use their selected device volume; there is no independent alert slider. |
| First capture permission | On a fresh permission state, enable app controls and adjust one playing app. Respond to the system audio recording prompt. Verify only that app changes, with no duplicate original playback. Unchanged apps should stay on their ordinary audio path. |
| Permission denial and recovery | Deny capture access and check for an actionable error or silent-capture failure. Disable app controls to restore original playback. Grant access in Privacy & Security, quit/reopen, and retry. Report any UI that claims mixing while audio is unavailable. |
| Volume and mute isolation | Reduce one app from 100% to 25%, mute, then unmute. Confirm the other app is unaffected and no original stream remains audible. Return to defaults and confirm ordinary playback resumes. |
| Output routing | Route one app to headphones and another to built-in speakers. Listen to each output separately, then change the system default. Explicit routes should stay on their selected device; system routes should follow the default. |
| Headphone disconnect | While routed to headphones, disconnect them. Expect fallback to the system output and **Unavailable · using system** in the app row. Audio may become audible on speakers. Reconnect and verify the saved route returns without duplicate output or repeated errors. |
| Fixed hardware volume | Select HDMI, USB, or another device without writable hardware volume. The system row should show **Fixed** with its volume slider disabled. Selection and supported mute remain independent. Verify per-app volume separately. |
| Unsupported format/device | Try available mono, multichannel, or nonstandard devices and sample rates. Supported 32-bit float PCM streams should have correct channels; unsupported formats should report an error without leaving the app muted after controls are disabled. |
| Balance and boost | Use stereo content to confirm left/right balance. Enable boost on quiet content and verify gain above 100%; loud peaks may clip. Reset and confirm the original mix. |
| Process lifecycle | Start, quit, and reopen a media app; test a browser with helper processes. Confirm rows and routes follow the correct application and saved settings reapply. |
| Sleep and recovery | Sleep/wake with a route active; also change Bluetooth profiles where available. Verify playback resumes or an actionable error is shown. |
| Exit and reset | Disable app controls, reset an app, reset all mixes, and quit in separate trials. Each should restore affected apps' ordinary playback; resetting preserves favorites. |
| Persistence and window | Relaunch and verify saved mix, favorites, filter, window position, and pin state. Closing the window should leave audio processing running; the menu bar icon should reopen it. |
| Launch at login | Install in `~/Applications`, enable the setting, approve the login item if requested, then log out/in. Expect one running copy and the mixer window shown. Disable the setting and verify the login item is removed. |

Long playback sessions, CPU load, audible latency, dropouts, protected media, Bluetooth profile switching, and crash/driver failure recovery remain hardware validation work. Synthetic tests do not cover these conditions.
