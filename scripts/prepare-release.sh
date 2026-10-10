#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Version.env
CHECKMATE_CONFIGURATION=release CHECKMATE_APP_NAME=Checkmate CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate bash build.sh
out="$PWD/build/release"
mkdir -p "$out"
rm -rf "$out/Checkmate.app"
ditto build/Checkmate.app "$out/Checkmate.app"
app="$out/Checkmate.app"
python3 -O scripts/check-package.py "$app"
ditto -c -k --keepParent "$app" "$out/Checkmate-$CHECKMATE_VERSION.zip"
