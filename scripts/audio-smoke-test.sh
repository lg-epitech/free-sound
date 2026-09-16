#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$PWD/.build/audio-smoke"
check_app="$check_dir/FreeSound Audio Check.app"
mkdir -p "$check_app/Contents/MacOS" "$check_dir/include"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.freesound.audio-check</string>
<key>CFBundleName</key><string>FreeSound Audio Check</string>
<key>CFBundleExecutable</key><string>AudioCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSAudioCaptureUsageDescription</key><string>Test FreeSound routing using only a quiet synthetic audio source. Nothing is recorded.</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cat > "$check_dir/include/module.modulemap" <<'MAP'
module AudioDSP { header "AudioDSP.h" export * }
MAP
cp Sources/AudioDSP/include/AudioDSP.h "$check_dir/include/AudioDSP.h"
clang -mmacosx-version-min=14.2 -std=c11 -Wall -Wextra -Werror -I Sources/AudioDSP/include -c Sources/AudioDSP/AudioDSP.c -o "$check_dir/dsp.o"
clang -mmacosx-version-min=14.2 -Wall -Wextra -Werror Tests/AudioIntegration/source.c -framework AudioUnit -framework CoreAudio -o "$check_dir/SyntheticSource"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" -I "$check_dir/include" Sources/FreeSound/Audio/ProcessAudioEngine.swift Sources/FreeSound/Audio/SystemAudio.swift Tests/AudioIntegration/main.swift "$check_dir/dsp.o" -framework CoreAudio -framework AudioToolbox -o "$check_app/Contents/MacOS/AudioCheck"
codesign --force --sign - "$check_app" >/dev/null
printf '%s\n' 'Running the optional hardware check. macOS may ask for audio capture permission.'
# --built-in verifies redirecting to built-in speakers while the synthetic
# source continues using the existing default. No defaults or volumes change.
"$check_app/Contents/MacOS/AudioCheck" "$check_dir/SyntheticSource" "$@"
