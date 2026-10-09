#!/bin/bash
set -euo pipefail
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
    staple "$app"
    codesign --verify --deep --strict "$app"
    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' EXIT
    ditto "$app" "$staging/Checkmate.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -volname "Checkmate $CHECKMATE_VERSION" -srcfolder "$staging" -ov -format UDZO "$dmg"
    ;;
verify)
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
    python3 -O scripts/check-package.py "$mount/Checkmate.app"
    shasum -a 256 "$dmg"
    ;;
*) echo 'Usage: finish-release.sh image|verify' >&2;exit 1;;
esac
