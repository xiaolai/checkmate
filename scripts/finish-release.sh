#!/bin/bash
set -euo pipefail
# Every Python check here is written with assert: an inherited PYTHONOPTIMIZE would silently skip them all.
unset PYTHONOPTIMIZE
cd "$(dirname "$0")/.."
source Version.env
app="$PWD/build/release/Checkmate.app"
dmg="$PWD/build/release/Checkmate-$CHECKMATE_VERSION.dmg"
staple() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if xcrun stapler staple "$1"; then break; fi
        (( attempt < 5 )) || return 1
        sleep 10
    done
    xcrun stapler validate "$1"
}
case "${1:-}" in
image)
    rm -f "$dmg.verified"  # a rebuilt image is unverified
    staple "$app"
    codesign --verify --deep --strict "$app"
    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' EXIT
    ditto "$app" "$staging/Checkmate.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -volname "Checkmate $CHECKMATE_VERSION" -srcfolder "$staging" -ov -format UDZO "$dmg"
    ;;
verify)
    rm -f "$dmg.verified"  # only this run, if it passes, may vouch for the image
    staple "$dmg"
    verdict=$(spctl -a -vvv -t open --context context:primary-signature "$dmg" 2>&1) || { echo "$verdict" >&2;exit 1; }
    [[ "$verdict" == *'source=Notarized Developer ID'* ]] || { echo "$verdict" >&2;exit 1; }
    mount=$(mktemp -d)
    trap 'hdiutil detach -quiet "$mount" 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg"
    codesign --verify --strict --deep "$mount/Checkmate.app"
    xcrun stapler validate "$mount/Checkmate.app"
    verdict=$(spctl -a -vvv -t exec "$mount/Checkmate.app" 2>&1) || { echo "$verdict" >&2;exit 1; }
    [[ "$verdict" == *'source=Notarized Developer ID'* ]] || { echo "$verdict" >&2;exit 1; }
    python3 -O scripts/check-package.py "$mount/Checkmate.app" --release
    # Run the shipped binary once: the engine child process, JavaScriptCore rules and bundled resources under the
    # hardened runtime and Developer ID signature. --package-check opens no window, saves no state and plays no audio.
    check=$(mktemp -d)
    env -i PATH=/usr/bin:/bin HOME="$HOME" CHECKMATE_AUTOMATION=1 perl -e 'alarm 120; exec @ARGV' "$mount/Checkmate.app/Contents/MacOS/CheckmateNative" --package-check "$check/package-check.json"
    python3 - "$check/package-check.json" "$mount" <<'PY'
import json,pathlib,sys
result=json.load(open(sys.argv[1]));assert result['passed'] and result['lessons']==39 and pathlib.Path(result['resourceRoot']).resolve().is_relative_to(pathlib.Path(sys.argv[2]).resolve()),result
print(json.dumps(result))
PY
    rm -rf "$check"
    # Reached only when every check above passed (set -e): publish-release.sh uploads only the DMG this record names.
    shasum -a 256 "$dmg" | tee "$dmg.verified"
    ;;
*) echo 'Usage: finish-release.sh image|verify' >&2;exit 1;;
esac
