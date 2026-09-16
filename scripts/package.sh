#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf 'Usage: ./scripts/package.sh\nBuild and verify a release ZIP for this Mac in dist/.\nSet FREESOUND_VERSION (X.Y.Z) and FREESOUND_BUILD_NUMBER to stamp a release.\n'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf 'Usage: ./scripts/package.sh (no arguments)\n' >&2
  exit 2
fi
"$PROJECT_DIR/scripts/build.sh"

APP_BUNDLE="$PROJECT_DIR/dist/FreeSound.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
ARCH="$(uname -m)"
ARCHIVE="FreeSound-$VERSION-macos-$ARCH.zip"
/usr/bin/lipo "$APP_BUNDLE/Contents/MacOS/FreeSound" -verify_arch "$ARCH"

# Zip the bundle before uploading: GitHub artifacts do not preserve executable permissions.
cd "$PROJECT_DIR/dist"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent FreeSound.app "$ARCHIVE"
/usr/bin/shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

# Validate the actual download, including its executable bit and signature.
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
test -x "$VERIFY_DIR/FreeSound.app/Contents/MacOS/FreeSound"
/usr/bin/codesign --verify --deep --strict "$VERIFY_DIR/FreeSound.app"
/usr/bin/shasum -a 256 -c "$ARCHIVE.sha256"
printf '\nPackaged %s/dist/%s\n' "$PROJECT_DIR" "$ARCHIVE"
