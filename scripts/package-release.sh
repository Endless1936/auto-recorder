#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Auto Recorder.app}"
OUTPUT="${2:-$ROOT/dist/release}"
PLIST_BUDDY=/usr/libexec/PlistBuddy
PROFILE="${NOTARY_PROFILE:-}"

fail() { echo "Error: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "Packaging requires macOS."
[[ -d "$APP/Contents" ]] || fail "Build Auto Recorder before packaging."
APP="$(cd "$APP" && pwd -P)"
PLIST="$APP/Contents/Info.plist"
[[ "$($PLIST_BUDDY -c 'Print :CFBundleIdentifier' "$PLIST")" == local.prototech.screenrecorder ]] || fail "Unexpected application identifier."
VERSION="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$PLIST")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Expected a numeric major.minor.patch version."
[[ "$VERSION" == "$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")" ]] || fail "App and source versions differ; rebuild first."
[[ "$(lipo -archs "$APP/Contents/MacOS/AutoRecorder")" == arm64 ]] || fail "Expected an arm64 application."
codesign --verify --strict "$APP"
SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)"
IDENTITY="$(sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' <<< "$SIGNATURE" | head -n 1)"
[[ -n "$IDENTITY" ]] || fail "Public packaging requires a Developer ID Application signature."
grep -q '^Timestamp=' <<< "$SIGNATURE" || fail "Rebuild with BUILD_MODE=release to add a secure timestamp."
grep -q 'flags=.*runtime' <<< "$SIGNATURE" || fail "Rebuild with hardened runtime enabled."
TIMESTAMP="$(sed -n 's/^Timestamp=//p' <<< "$SIGNATURE")"

for item in Sources Tests Assets scripts docs .github LICENSE Info.plist Entitlements.plist build.sh install.sh README.md README.en.md AGENTS.md CONTRIBUTING.md .gitignore .gitattributes; do
  [[ -e "$ROOT/$item" ]] || fail "Missing source-distribution input: $item"
done
for item in INSTALL.txt SOURCE.txt; do
  [[ -f "$ROOT/docs/$item" ]] || fail "Missing docs/$item"
done
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
case "$OUTPUT/" in
  "$ROOT/Sources/"*|"$ROOT/Tests/"*|"$ROOT/Assets/"*|"$ROOT/scripts/"*|"$ROOT/docs/"*|"$ROOT/.github/"*)
    fail "Release output must not be inside a public source-input directory." ;;
esac
PREFIX="Auto-Recorder-v$VERSION"
DMG_NAME="$PREFIX-macos-arm64.dmg"
SOURCE_NAME="$PREFIX-source.tar.gz"
for item in "$DMG_NAME" "$SOURCE_NAME" RELEASE-NOTES.md SHA256SUMS.txt; do
  [[ ! -e "$OUTPUT/$item" ]] || fail "Output already exists: $OUTPUT/$item. Use a new output directory."
done
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/auto-recorder-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/Auto Recorder.app"
ln -s /Applications "$STAGE/dmg/Applications"
cp "$ROOT/LICENSE" "$STAGE/dmg/LICENSE"
sed "s/<VERSION>/$VERSION/g" "$ROOT/docs/SOURCE.txt" > "$STAGE/dmg/SOURCE.txt"
cp "$ROOT/docs/INSTALL.txt" "$STAGE/dmg/Read Me.txt"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "Auto Recorder" -srcfolder "$STAGE/dmg" "$OUTPUT/$DMG_NAME"
codesign --force --sign "$IDENTITY" --timestamp "$OUTPUT/$DMG_NAME"

NOTARIZATION="NOT NOTARIZED — first launch may require macOS Privacy & Security > Open Anyway."
if [[ -n "$PROFILE" ]]; then
  xcrun notarytool submit "$OUTPUT/$DMG_NAME" --keychain-profile "$PROFILE" --wait --output-format json > "$STAGE/notary-result.json"
  STATUS="$(plutil -extract status raw "$STAGE/notary-result.json")"
  [[ "$STATUS" == Accepted ]] || { cat "$STAGE/notary-result.json" >&2; fail "Apple notarization was not accepted."; }
  xcrun stapler staple "$OUTPUT/$DMG_NAME"
  xcrun stapler validate "$OUTPUT/$DMG_NAME"
  xcrun stapler staple "$APP"
  codesign --verify --strict "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  NOTARIZATION="Apple notarized; the disk image and source app have stapled tickets."
fi

SOURCE_ROOT="$STAGE/$PREFIX-source"
mkdir -p "$SOURCE_ROOT/Tests"
for item in Sources Assets scripts docs .github; do ditto "$ROOT/$item" "$SOURCE_ROOT/$item"; done
for item in "$ROOT"/Tests/*.swift; do cp "$item" "$SOURCE_ROOT/Tests/"; done
for item in LICENSE Info.plist Entitlements.plist build.sh install.sh README.md README.en.md AGENTS.md CONTRIBUTING.md .gitignore .gitattributes; do
  cp "$ROOT/$item" "$SOURCE_ROOT/$item"
done
COPYFILE_DISABLE=1 tar --no-xattrs \
  --exclude='.DS_Store' --exclude='.git' --exclude='.env*' --exclude='*.p12' --exclude='*.pfx' \
  --exclude='*.key' --exclude='*.pem' --exclude='*.p8' --exclude='*.cer' --exclude='*.keychain*' \
  --exclude='*.mobileprovision' --exclude='*.provisionprofile' \
  --exclude='*.mov' --exclude='*.mp4' --exclude='*.m4v' --exclude='*.wav' --exclude='*.m4a' \
  --exclude='*.cursor.json' --exclude='project*.json' \
  --exclude='*.dmg' --exclude='*.zip' --exclude='*.app' --exclude='*.tar.gz' --exclude='*.textClipping' \
  --exclude='*.log' --exclude='__pycache__' --exclude='.build*' --exclude='node_modules' \
  -czf "$OUTPUT/$SOURCE_NAME" -C "$STAGE" "$PREFIX-source"
cat > "$OUTPUT/RELEASE-NOTES.md" <<EOF
# Auto Recorder $VERSION

- Requirements: Apple Silicon (arm64), macOS 15 or later. Intel Macs are not supported.
- Installation: open $DMG_NAME, drag Auto Recorder.app onto Applications, eject the image, then open the installed app.
- First use: allow screen recording; microphone permission is requested only when enabled.
- Signature: $IDENTITY; hardened runtime enabled; secure timestamp: $TIMESTAMP.
- Notarization: $NOTARIZATION
- License: GPL-3.0-only. Complete matching source is provided in $SOURCE_NAME alongside this binary.
- Verify downloads with: shasum -a 256 -c SHA256SUMS.txt

Project and installation instructions: https://github.com/Endless1936/auto-recorder
EOF
(cd "$OUTPUT" && shasum -a 256 "$DMG_NAME" "$SOURCE_NAME" RELEASE-NOTES.md > SHA256SUMS.txt)
echo "Release files: $OUTPUT"
echo "$NOTARIZATION"
