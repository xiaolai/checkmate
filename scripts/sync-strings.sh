#!/bin/bash
# Refreshes the String Catalog (Sources/CheckmateCore/Localizable.xcstrings) from the code. The compiler records every
# localized string with its interpolation types (%lld, %@), and xcstringstool merges them into the catalog: new text is
# added, text no longer in the code is marked stale, and hand-written plural variations and comments are kept.
# Run it on the test host after changing shown text, then review the catalog diff.
set -euo pipefail
cd "$(dirname "$0")/.."
checkmate_work=$(mktemp -d)
trap 'rm -rf "$checkmate_work"' EXIT
# A fresh scratch path compiles every file. An incremental build would record only the files it recompiled, and the
# sync would then mark every other string stale. The new build system writes each .stringsdata beside its object file;
# only this package's are read, not its dependencies'.
swift build --scratch-path "$checkmate_work/build" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$checkmate_work/strings"
checkmate_stringsdata=()
while IFS= read -r -d '' checkmate_file; do checkmate_stringsdata+=(--stringsdata "$checkmate_file"); done < <(find "$checkmate_work/build" -path '*/Checkmate.build/*' -name '*.stringsdata' -print0)
(( ${#checkmate_stringsdata[@]} > 0 )) || { echo 'The compiler recorded no localized strings' >&2; exit 1; }
xcrun xcstringstool sync Sources/CheckmateCore/Localizable.xcstrings "${checkmate_stringsdata[@]}"
echo "Synced the catalog from $(( ${#checkmate_stringsdata[@]} / 2 )) string tables."
