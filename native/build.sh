#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source "$PWD/Version.env"
checkmate_configuration=${CHECKMATE_CONFIGURATION:-debug}
case "$checkmate_configuration" in debug|release) ;; *) echo "Invalid build configuration" >&2;exit 1;; esac
checkmate_build_arguments=()
if [[ -n "${CHECKMATE_BUILD_PATH:-}" ]]; then checkmate_build_arguments+=(--scratch-path "$CHECKMATE_BUILD_PATH"); fi
swift build -c "$checkmate_configuration" "${checkmate_build_arguments[@]}"
checkmate_bin=$(swift build -c "$checkmate_configuration" "${checkmate_build_arguments[@]}" --show-bin-path)
checkmate_bundle_id=${CHECKMATE_BUNDLE_ID:-ai.xiaolai.checkmate.native-development}
checkmate_app=${CHECKMATE_APP_NAME:-CheckmateNative}
checkmate_target="build/$checkmate_app.app/Contents"
case "$checkmate_app" in *[!a-zA-Z0-9_-]*|"") echo "Invalid app name" >&2;exit 1;; esac
rm -rf "build/$checkmate_app.app"
mkdir -p "$checkmate_target/MacOS" "$checkmate_target/Resources"
cp "$checkmate_bin/CheckmateNative" "$checkmate_target/MacOS/CheckmateNative"
for resource in "$checkmate_bin"/*.bundle; do cp -R "$resource" "$checkmate_target/Resources/"; done
cat > "$checkmate_target/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleInfoDictionaryVersion</key><string>6.0</string><key>CFBundleExecutable</key><string>CheckmateNative</string><key>CFBundleIdentifier</key><string>$checkmate_bundle_id</string><key>CFBundleName</key><string>Checkmate</string><key>CFBundleVersion</key><string>$CHECKMATE_BUILD_NUMBER</string><key>CFBundleShortVersionString</key><string>$CHECKMATE_VERSION</string><key>NSHighResolutionCapable</key><true/><key>LSMinimumSystemVersion</key><string>27.0</string><key>NSMicrophoneUsageDescription</key><string>Listen to your questions during chess practice.</string></dict></plist>
PLIST
# Restore the pinned engine bytes even if a prior nested signing pass touched
# SwiftPM's cached resource copy. Release signing updates only its own copy.
checkmate_engine_destination=$(find "$checkmate_target/Resources" -type f -name stockfish)
[[ -n "$checkmate_engine_destination" && "$checkmate_engine_destination" != *$'\n'* ]] || exit 1
cp Sources/CheckmateCore/Resources/stockfish "$checkmate_engine_destination"
# Reuse the Dock icon's canonical vector artwork for lesson title cards.
checkmate_lesson_catalog="$PWD/build/LessonArtwork.xcassets"
rm -rf "$checkmate_lesson_catalog"
cp -R Artwork/LessonArtwork.xcassets "$checkmate_lesson_catalog"
cp Artwork/Checkmate.icon/Assets/Knight.svg "$checkmate_lesson_catalog/LessonKnight.imageset/Knight.svg"
checkmate_icon_report="$PWD/build/$checkmate_app-icon.log"
checkmate_icon_partial="$PWD/build/$checkmate_app-icon.plist"
bash Tools/actool.sh --compile "$PWD/$checkmate_target/Resources" --app-icon Checkmate \
    --output-partial-info-plist "$checkmate_icon_partial" --platform macosx \
    --minimum-deployment-target 27.0 --target-device mac --errors --warnings \
    --output-format human-readable-text "$PWD/Artwork/Checkmate.icon" "$checkmate_lesson_catalog" > "$checkmate_icon_report" 2>&1 || { cat "$checkmate_icon_report"; exit 1; }
if grep -qiE ': (warning|error):' "$checkmate_icon_report"; then cat "$checkmate_icon_report";exit 1;fi
checkmate_icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$checkmate_icon_partial")
[[ "$checkmate_icon_name" == Checkmate ]] || { echo 'Unexpected compiled icon name' >&2;exit 1; }
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $checkmate_icon_name" "$checkmate_target/Info.plist"
[[ -s "$checkmate_target/Resources/Assets.car" ]] || { echo 'Icon asset catalog missing' >&2;exit 1; }
# The macOS 27 deployment floor uses the layered catalog, not a flattened legacy fallback.
rm -f "$checkmate_target/Resources/Checkmate.icns"
codesign --force --sign - "build/$checkmate_app.app"
