#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SOURCE="${1:-$ROOT/dist/Auto Recorder.app}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
BUNDLE_ID="local.prototech.screenrecorder"
PLIST_BUDDY=/usr/libexec/PlistBuddy

fail() { echo "Error: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "Auto Recorder requires macOS."
[[ "$(uname -m)" == arm64 ]] || fail "This build requires an Apple Silicon Mac."
MACOS_VERSION="$(sw_vers -productVersion)"
[[ "${MACOS_VERSION%%.*}" -ge 15 ]] || fail "Auto Recorder requires macOS 15 or later."
[[ -d "$APP_SOURCE/Contents" ]] || fail "App not found: $APP_SOURCE. Build it first with bash build.sh."
APP_SOURCE="$(cd "$APP_SOURCE" && pwd -P)"
[[ "$($PLIST_BUDDY -c 'Print :CFBundleIdentifier' "$APP_SOURCE/Contents/Info.plist")" == "$BUNDLE_ID" ]] || fail "The source is not an Auto Recorder bundle."
codesign --verify --strict "$APP_SOURCE"

if ! mkdir -p "$INSTALL_DIR" || [[ ! -w "$INSTALL_DIR" ]]; then
  fail "Destination is not writable. Try INSTALL_DIR=\"\$HOME/Applications\" bash install.sh instead."
fi
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
TARGET="$INSTALL_DIR/Auto Recorder.app"
[[ "$APP_SOURCE" != "$TARGET" ]] || fail "This app is already at the installation destination."
[[ ! -L "$TARGET" ]] || fail "Refusing to replace a symbolic link: $TARGET"
if [[ -e "$TARGET" ]]; then
  [[ -d "$TARGET/Contents" ]] || fail "Destination is not an application bundle: $TARGET"
  [[ "$($PLIST_BUDDY -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist")" == "$BUNDLE_ID" ]] || fail "Refusing to replace an unrelated application."
  if pgrep -x AutoRecorder >/dev/null; then
    fail "Quit Auto Recorder before replacing an installed copy."
  fi
fi

STAGE="$(mktemp -d "$INSTALL_DIR/.AutoRecorder.install.XXXXXX")"
cleanup() {
  result=$?
  trap - EXIT
  if [[ -d "$STAGE/previous.app" && ! -e "$TARGET" ]]; then
    if ! mv "$STAGE/previous.app" "$TARGET"; then
      echo "Installation failed; the previous app remains at $STAGE/previous.app" >&2
      exit 1
    fi
  fi
  rm -rf "$STAGE"
  exit "$result"
}
trap cleanup EXIT
ditto "$APP_SOURCE" "$STAGE/Auto Recorder.app"
codesign --verify --strict "$STAGE/Auto Recorder.app"
if [[ -e "$TARGET" ]]; then mv "$TARGET" "$STAGE/previous.app"; fi
mv "$STAGE/Auto Recorder.app" "$TARGET"
echo "Installed: $TARGET"
echo "Open it from Finder. macOS will request screen-recording and optional microphone permissions."
