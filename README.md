# FreeSound

A small, free macOS menu bar audio mixer. Control system devices and each application's sound in one place, with no subscriptions, accounts, or third-party runtime dependencies.

FreeSound is an independent project inspired by the convenience of SoundSource. It is not affiliated with Rogue Amoeba, and contains no SoundSource code or assets.

## Requirements

- macOS 14.2 or later.
- Apple's Command Line Tools with Swift 5.10 or later. A full Xcode installation is optional.
- Permission to capture system audio for application mixing.

## Build and run

If the developer tools are missing, install them first:

```sh
xcode-select --install
```

Then build and launch the app:

```sh
./scripts/run.sh
```

The mixer window opens when FreeSound launches. Use its waveform icon in the menu bar to show or hide it. Closing the window keeps the mixer running; choose **Quit FreeSound** in the gear menu to stop it. FreeSound does not appear in the Dock.

To build without launching, run `./scripts/build.sh`. The result is `dist/FreeSound.app`. To copy it into your user Applications folder, run `./scripts/build.sh --install`, then open `~/Applications/FreeSound.app`. Quit a running copy before replacing it. `--debug` is also available on both scripts.

The scripts create an original app icon and sign the bundle locally. No Apple developer account, certificate, or paid membership is required. Local signing is for running your own build; this project does not provide a notarized release for distribution.

## What it does

- Select the default output, input, and system sound effects devices.
- Adjust supported hardware output and input volume, with mute controls where the device supports them.
- Discover running audio applications and give each one its own volume and mute control.
- Send an application's audio to a chosen output device.
- Adjust stereo balance and optionally boost an app up to 200%.
- Search applications, keep favorites, and remember mixer preferences between launches.
- Pin the mixer above other windows and optionally launch at login.

The sound effects row selects a device and uses that device's volume; it does not provide a separate alert-volume slider. Hardware volume controls display **Fixed** when the device does not expose writable volume.

Click **Enable app controls**, then adjust an application's volume, mute, balance, or output. macOS asks for system audio recording permission when the first audio tap is created. Enabling the controls alone does not capture unchanged apps. A 100% volume, centered balance, unmuted app using the system output keeps its original audio path.

Application mixing uses Apple's [Core Audio process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), available since macOS 14.2. FreeSound captures an application's stereo output, applies its mix, and plays it on the selected device while silencing that application's original stream. Audio is processed locally; it is not recorded to disk or sent anywhere. Quit FreeSound or disable **App controls** to stop the taps and restore ordinary playback. **Reset app mix** also clears saved application adjustments while preserving favorites.

If capture permission was denied, choose **Audio capture permission…** in the gear menu, enable FreeSound in System Settings → Privacy & Security, then quit and reopen it. System device controls do not need capture permission.

For launch at login, install the app in `~/Applications` first, then enable **Launch at login** in the gear menu. macOS may ask you to approve its login item. The app currently shows its mixer window when launched at login, just as it does on a manual launch.

## Prototype status

This is an early implementation, not a complete replacement for SoundSource. Audio Unit effects, equalizers, saved routing presets, and a privileged audio driver are not included. There is no installer or background service.

Some HDMI, USB, Bluetooth, and aggregate devices do not expose a hardware volume control. Their system volume controls may be unavailable even though selecting them works. The tap engine requires 32-bit float PCM streams and a synchronized sample rate; unsupported formats report an error. It mixes to stereo, with a mono downmix for mono outputs. Boost applies gain and clips samples at full scale, so loud material can distort.

If a saved application output is disconnected, FreeSound falls back to the current system output; the row displays **Unavailable · using system**. This can make audio play through built-in speakers. The saved device remains selected so routing can return when it reconnects.

Process tap compatibility depends on the application and macOS version. Protected content, helper processes, device removal, differing sample rates, and Bluetooth profile changes need particular care and manual validation. The first implementation does not yet have verified audible results across those cases.

A locally signed rebuild can cause macOS to request audio permission again. For regular use, keep the app at one stable location. FreeSound must stay running for application mixing to remain active.

## Development and validation

The project uses Swift Package Manager. Build the bundled app with the scripts above so macOS can read its capture permission description and bundle identity; `swift run` alone does not provide the same app bundle environment.

Run the DSP, preference, and read-only device checks with:

```sh
./scripts/test.sh
```

These are standalone C and Swift checks, so they work with Command Line Tools alone. They do not require XCTest or full Xcode. The C audio checks run with AddressSanitizer and UndefinedBehaviorSanitizer.

Optional live engine checks capture only a separate, very quiet synthetic source. The script creates a locally signed disposable test app under `.build/audio-smoke`; macOS may request audio capture permission for it:

```sh
./scripts/audio-smoke-test.sh
./scripts/audio-smoke-test.sh --built-in
```

The first command routes to the current default output; `--built-in` redirects to built-in speakers while leaving the default unchanged. Neither command captures your other applications or changes hardware volume.

The bundled executable has a read-only diagnostic mode that prints devices, current default device IDs, and audio processes as JSON. It does not initialize application mixing or request capture permission:

```sh
./dist/FreeSound.app/Contents/MacOS/FreeSound --diagnostics
```

For a PNG of the native mixer, quit any running copy, then run:

```sh
./dist/FreeSound.app/Contents/MacOS/FreeSound --snapshot /tmp/FreeSound.png
```

Snapshot mode opens the app using its saved preferences, captures its own view, and exits. Unlike diagnostics, it follows normal startup behavior and can activate a saved mix.

The initial release build and local signature passed, along with five DSP check groups, 12 preference checks, and read-only live device checks. Live synthetic capture, half gain, mute, and teardown passed on WH-1000XM4 headphones at 44.1 kHz and built-in speakers at 48 kHz. The native snapshot and basic UI interactions were also verified. See [architecture and validation notes](docs/TESTING.md) for results and the remaining checklist. Listening tests, the app's first-run permission flow, disconnect/sleep recovery, and launch at login remain unverified.

## License

[MIT](LICENSE). Free to use, modify, and redistribute.
