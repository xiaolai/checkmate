#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source "$PWD/Version.env"
checkmate_configuration=${CHECKMATE_CONFIGURATION:-debug}
case "$checkmate_configuration" in debug|release) ;; *) echo "Invalid build configuration" >&2;exit 1;; esac
checkmate_build_arguments=(--arch arm64 --arch x86_64)
if [[ -n "${CHECKMATE_BUILD_PATH:-}" ]]; then checkmate_build_arguments+=(--scratch-path "$CHECKMATE_BUILD_PATH"); fi
# SwiftPM keeps its build locks in TMPDIR: always the user's temp folder, so every build of this checkout shares them.
checkmate_swiftpm_tmp=$(getconf DARWIN_USER_TEMP_DIR)
TMPDIR="$checkmate_swiftpm_tmp" swift build -c "$checkmate_configuration" "${checkmate_build_arguments[@]}"
checkmate_bin=$(TMPDIR="$checkmate_swiftpm_tmp" swift build -c "$checkmate_configuration" "${checkmate_build_arguments[@]}" --show-bin-path)
checkmate_bundle_id=${CHECKMATE_BUNDLE_ID:-ai.xiaolai.checkmate.native-development}
checkmate_app=${CHECKMATE_APP_NAME:-CheckmateNative}
checkmate_target="build/$checkmate_app.app/Contents"
case "$checkmate_app" in *[!a-zA-Z0-9_-]*|"") echo "Invalid app name" >&2;exit 1;; esac
# One Bonjour service type per build kind (LAN-play plan D12), so automation and development builds never see
# released games. The app reads its type back from NSBonjourServices.
case "$checkmate_bundle_id" in
  ai.xiaolai.checkmate) checkmate_bonjour_service=_checkmate._tcp ;;
  *automation*) checkmate_bonjour_service=_checkmate-auto._tcp ;;
  *) checkmate_bonjour_service=_checkmate-dev._tcp ;;
esac
rm -rf "build/$checkmate_app.app"
mkdir -p "$checkmate_target/MacOS" "$checkmate_target/Resources"
cp "$checkmate_bin/CheckmateNative" "$checkmate_target/MacOS/CheckmateNative"
cp "$checkmate_bin/CheckmateMCP" "$checkmate_target/MacOS/CheckmateMCP"
# SwiftPM can retain bundles of removed/renamed targets in its cache. Copy only current ownership.
checkmate_resources="$checkmate_bin/Checkmate_CheckmateAssets.bundle"
[[ -d "$checkmate_resources" ]] || { echo 'CheckmateAssets resource bundle missing' >&2; exit 1; }
cp -R "$checkmate_resources" "$checkmate_target/Resources/"
# SwiftUI's Text("…") and AppKit look up text in the app itself, so the String Catalog's compiled tables ship there too.
checkmate_localizations=$(find "$checkmate_target/Resources/Checkmate_CheckmateAssets.bundle" -maxdepth 3 -type d -name '*.lproj')
[[ -n "$checkmate_localizations" ]] || { echo 'Compiled String Catalog missing from the resource bundle' >&2; exit 1; }
while IFS= read -r checkmate_localization; do cp -R "$checkmate_localization" "$checkmate_target/Resources/"; done <<< "$checkmate_localizations"
cat > "$checkmate_target/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleInfoDictionaryVersion</key><string>6.0</string><key>CFBundleExecutable</key><string>CheckmateNative</string><key>CFBundleIdentifier</key><string>$checkmate_bundle_id</string><key>CFBundleName</key><string>Checkmate</string><key>CFBundleVersion</key><string>$CHECKMATE_BUILD_NUMBER</string><key>CFBundleShortVersionString</key><string>$CHECKMATE_VERSION</string><key>NSHighResolutionCapable</key><true/><key>LSMinimumSystemVersion</key><string>$CHECKMATE_MINIMUM_MACOS</string><key>NSMicrophoneUsageDescription</key><string>Checkmate sends what you say to OpenAI so the voice coach can answer. The microphone is used only while the voice coach is connected.</string><key>NSLocalNetworkUsageDescription</key><string>Checkmate finds and connects to games on your local network</string><key>NSBonjourServices</key><array><string>$checkmate_bonjour_service</string></array><key>CFBundleDevelopmentRegion</key><string>en</string><key>LSApplicationCategoryType</key><string>public.app-category.education</string><key>NSHumanReadableCopyright</key><string>Copyright © 2026 xiaolai</string><key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>PGN chess game</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>org.chessprogramming.pgn</string></array></dict><dict><key>CFBundleTypeName</key><string>FEN chess position</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>org.chessprogramming.fen</string></array></dict></array><key>UTImportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>org.chessprogramming.pgn</string><key>UTTypeDescription</key><string>PGN chess game</string><key>UTTypeConformsTo</key><array><string>public.plain-text</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>pgn</string></array><key>public.mime-type</key><array><string>application/x-chess-pgn</string></array></dict></dict><dict><key>UTTypeIdentifier</key><string>org.chessprogramming.fen</string><key>UTTypeDescription</key><string>FEN chess position</string><key>UTTypeConformsTo</key><array><string>public.plain-text</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>fen</string></array></dict></dict></array></dict></plist>
PLIST
# Release packaging records the exact commit it was built from (scripts/release.sh checks it is the tag).
if [[ -n "${CHECKMATE_SOURCE_COMMIT:-}" ]]; then
  [[ "$CHECKMATE_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid source commit' >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :CheckmateSourceCommit string $CHECKMATE_SOURCE_COMMIT" "$checkmate_target/Info.plist"
fi
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
    --minimum-deployment-target "$CHECKMATE_MINIMUM_MACOS" --target-device mac --errors --warnings \
    --output-format human-readable-text "$PWD/Artwork/Checkmate.icon" "$checkmate_lesson_catalog" > "$checkmate_icon_report" 2>&1 || { cat "$checkmate_icon_report"; exit 1; }
if grep -qiE ': (warning|error):' "$checkmate_icon_report"; then cat "$checkmate_icon_report";exit 1;fi
checkmate_icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$checkmate_icon_partial")
[[ "$checkmate_icon_name" == Checkmate ]] || { echo 'Unexpected compiled icon name' >&2;exit 1; }
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $checkmate_icon_name" "$checkmate_target/Info.plist"
[[ -s "$checkmate_target/Resources/Assets.car" ]] || { echo 'Icon asset catalog missing' >&2;exit 1; }
# Keep actool's flattened icon fallback for macOS before Icon Composer support.
checkmate_icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$checkmate_icon_partial")
[[ "$checkmate_icon_file" == *.icns ]] || checkmate_icon_file="$checkmate_icon_file.icns"
[[ -s "$checkmate_target/Resources/$checkmate_icon_file" ]] || { echo 'Legacy icon fallback missing' >&2;exit 1; }
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $checkmate_icon_file" "$checkmate_target/Info.plist"
# SwiftPM's universal release helper may be unsigned after slice merging.
# Sign nested code before the enclosing app so strict package verification works.
codesign --force --sign - "$checkmate_target/MacOS/CheckmateMCP"
codesign --force --sign - "build/$checkmate_app.app"
