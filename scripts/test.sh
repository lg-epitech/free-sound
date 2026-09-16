#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$PROJECT_DIR"
CHECK_DIR="$PROJECT_DIR/.build/checks"
mkdir -p "$CHECK_DIR"

# Standalone checks work with Command Line Tools; XCTest needs full Xcode.
xcrun clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  -I Sources/AudioDSP/include Sources/AudioDSP/AudioDSP.c Tests/AudioDSPChecks/main.c \
  -framework CoreAudio -o "$CHECK_DIR/audio-dsp"
"$CHECK_DIR/audio-dsp"

xcrun swiftc Sources/FreeSound/Models/AudioPreferences.swift Tests/PreferencesChecks/main.swift \
  -o "$CHECK_DIR/preferences"
"$CHECK_DIR/preferences"

xcrun swiftc Sources/FreeSound/Audio/SystemAudio.swift Tests/SystemAudioChecks/main.swift \
  -o "$CHECK_DIR/system-audio"
"$CHECK_DIR/system-audio"

printf '\nAll checks passed. No live audio settings were changed.\n'
