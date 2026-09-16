#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
for argument in "$@"; do
  if [[ "$argument" == --help || "$argument" == -h ]]; then
    "$PROJECT_DIR/scripts/build.sh" "$@"
    exit 0
  fi
done
if /usr/bin/pgrep -x FreeSound >/dev/null 2>&1; then
  printf 'FreeSound is already running. Quit it from its menu before launching this build.\n' >&2
  exit 1
fi
"$PROJECT_DIR/scripts/build.sh" "$@"
APP_BUNDLE="$PROJECT_DIR/dist/FreeSound.app"
for argument in "$@"; do
  if [[ "$argument" == --install ]]; then
    APP_BUNDLE="$HOME/Applications/FreeSound.app"
  fi
done
/usr/bin/open "$APP_BUNDLE"
printf 'FreeSound is in the menu bar. Click its waveform icon to open the mixer.\n'
