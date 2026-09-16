#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CONFIGURATION=release
INSTALL_APP=false

usage() {
  cat <<'EOF'
Build FreeSound as a locally signed macOS application.

Usage: ./scripts/build.sh [--debug] [--install]

  --debug    Use a debug build instead of the default release build.
  --install  Copy the finished app to ~/Applications/FreeSound.app.
  --help     Show this message.

Requires macOS 14.2 or later and Apple's Command Line Tools.
Set FREESOUND_VERSION (X.Y.Z) and FREESOUND_BUILD_NUMBER to stamp a release.
EOF
}

for argument in "$@"; do
  case "$argument" in
    --debug) CONFIGURATION=debug ;;
    --install) INSTALL_APP=true ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "${FREESOUND_VERSION:-}" && ! "$FREESOUND_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'FREESOUND_VERSION must be X.Y.Z.\n' >&2
  exit 2
fi
if [[ -n "${FREESOUND_BUILD_NUMBER:-}" && ! "$FREESOUND_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FREESOUND_BUILD_NUMBER must be a positive integer.\n' >&2
  exit 2
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'FreeSound requires macOS.\n' >&2
  exit 1
fi

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
  printf 'Install Apple Command Line Tools first: xcode-select --install\n' >&2
  exit 1
fi

/usr/bin/xcrun swift build --package-path "$PROJECT_DIR" \
  --configuration "$CONFIGURATION" --product FreeSound
EXECUTABLE_DIR="$(/usr/bin/xcrun swift build --package-path "$PROJECT_DIR" \
  --configuration "$CONFIGURATION" --show-bin-path)"

ICON_DIR="$PROJECT_DIR/.build/app-icon"
mkdir -p "$ICON_DIR"
/usr/bin/xcrun swift "$PROJECT_DIR/scripts/make-icon.swift" "$ICON_DIR"

APP_BUNDLE="$PROJECT_DIR/dist/FreeSound.app"
mkdir -p "$PROJECT_DIR/dist"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
/usr/bin/install -m 755 "$EXECUTABLE_DIR/FreeSound" "$APP_BUNDLE/Contents/MacOS/FreeSound"
/usr/bin/install -m 644 "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [[ -n "${FREESOUND_VERSION:-}" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$FREESOUND_VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "${FREESOUND_BUILD_NUMBER:-}" ]]; then
  /usr/bin/plutil -replace CFBundleVersion -string "$FREESOUND_BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
fi
/usr/bin/install -m 644 "$ICON_DIR/FreeSound.icns" "$APP_BUNDLE/Contents/Resources/FreeSound.icns"
/usr/bin/install -m 644 "$PROJECT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist"

# Ad hoc signing needs no Apple account, certificate, or paid membership.
/usr/bin/codesign --force --sign - --timestamp=none \
  --entitlements "$PROJECT_DIR/Resources/FreeSound.entitlements" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

printf '\nBuilt %s\n' "$APP_BUNDLE"
if [[ "$INSTALL_APP" == true ]]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  if /usr/bin/pgrep -x FreeSound >/dev/null 2>&1; then
    printf 'Quit FreeSound before replacing the installed app. The new build is ready in dist/.\n' >&2
    exit 1
  fi
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_DIR/FreeSound.app"
  printf 'Installed %s/FreeSound.app\n' "$INSTALL_DIR"
fi
