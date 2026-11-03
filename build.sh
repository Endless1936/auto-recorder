#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SOURCE_DIR/dist}"
APP="$OUTPUT_DIR/Auto Recorder.app"
MODULE_CACHE="${TMPDIR:-/tmp}/local-recorder-swift-module-cache"
BUILD_MODE="${BUILD_MODE:-development}"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: building Auto Recorder requires macOS and Apple Command Line Tools." >&2
  exit 1
fi
case "$BUILD_MODE" in
  development|release) ;;
  *) echo "Error: BUILD_MODE must be development or release." >&2; exit 1 ;;
esac
AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(awk '/\"Developer ID Application:/ {print $2; exit}' <<< "$AVAILABLE_IDENTITIES")"
  if [ -z "$SIGNING_IDENTITY" ] && [ "$BUILD_MODE" = "development" ]; then
    SIGNING_IDENTITY="$(awk '/\"Apple Development:/ {print $2; exit}' <<< "$AVAILABLE_IDENTITIES")"
  fi
fi
if [ "$BUILD_MODE" = "release" ]; then
  RELEASE_IDENTITY="$(printf '%s\n' "$AVAILABLE_IDENTITIES" | grep -F -- "$SIGNING_IDENTITY" | grep '"Developer ID Application:' || true)"
  if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ] || [ -z "$RELEASE_IDENTITY" ]; then
    echo "Error: release builds require an accessible Developer ID Application certificate." >&2
    exit 1
  fi
fi
if [ -z "$SIGNING_IDENTITY" ]; then
  RELEASE_TEAM="$(codesign -dv "$SOURCE_DIR/dist/Auto Recorder.app" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
  if [ -n "$RELEASE_TEAM" ] && [ "$RELEASE_TEAM" != "not set" ]; then
    echo "Error: the current release uses a certificate. No signing identity is accessible; unlock the keychain or set CODE_SIGN_IDENTITY. Refusing to replace it with an ad-hoc build." >&2
    exit 1
  fi
  SIGNING_IDENTITY="-"
  echo "Warning: no signing certificate available; ad-hoc builds may need screen recording permission again after each rebuild." >&2
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  -module-cache-path "$MODULE_CACHE" \
  "$SOURCE_DIR"/Sources/*.swift \
  "$SOURCE_DIR"/Tests/*.swift \
  -o "$APP/Contents/MacOS/AutoRecorder" \
  -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework Carbon -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$SOURCE_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_DIR/Info.plist")"
sed "s/<VERSION>/$VERSION/g" "$SOURCE_DIR/docs/SOURCE.txt" > "$APP/Contents/Resources/SOURCE.txt"
SIGN_OPTIONS=(--timestamp=none)
if [ "$BUILD_MODE" = "release" ]; then SIGN_OPTIONS=(--timestamp); fi
codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
  --entitlements "$SOURCE_DIR/Entitlements.plist" "${SIGN_OPTIONS[@]}" \
  --identifier local.prototech.screenrecorder "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
echo "Mode: $BUILD_MODE. Apple notarization is optional; see docs/RELEASING.md for first-launch instructions."
