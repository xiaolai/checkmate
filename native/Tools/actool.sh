#!/bin/bash
# `xcrun actool`, with its arguments passed through untouched — and **what it leaves behind taken back**.
#
# A helper actool spawns renders the app icon into a UUID-named directory under the per-user temporary
# directory and never removes it: one `<AppIcon>1024x1024_….png` per compile, for good. `TMPDIR` does
# not reach the helper — measured 2026-10-03, set to a scratch directory, the render still landed in the
# real one — so it cannot be steered, only collected. The renders this compile made are found by a
# marker taken just before it, removed with their directory where nothing else is in it, and the run
# fails if one survives: a leak that is quiet is a leak that returns.
#
# Every actool call in this repository goes through here: the bundle build and the icon tests both
# leaked, and a cleanup written twice is a cleanup that drifts.
#
# Not safe to run two at once: each would collect the other's render. Nothing here does — the bundle
# build holds its lock and the test suites run one after another.
set -euo pipefail

icon=""
previous=""
for argument in "$@"; do
    [ "$previous" = "--app-icon" ] && icon=$argument
    previous=$argument
done
[ -n "$icon" ] || { echo "actool.sh: --app-icon is required, so its render can be found" >&2; exit 2; }

user_tmp=$(getconf DARWIN_USER_TEMP_DIR)
user_tmp=${user_tmp%/}
marker=$(mktemp "$user_tmp/checkmate-actool-marker.XXXXXX")
trap 'rm -f "$marker"' EXIT

status=0
xcrun actool "$@" || status=$?

renders() { find "$user_tmp" -maxdepth 2 -name "${icon}1024x1024_*.png" -newer "$marker"; }
while IFS= read -r render; do
    rm -f "$render"
    # Only an emptied directory goes: `rmdir` cannot remove anything this did not just empty.
    rmdir "$(dirname "$render")" 2>/dev/null || true
done < <(renders)
if [ -n "$(renders)" ]; then
    echo "actool.sh: actool's icon render was left in $user_tmp and could not be removed" >&2
    exit 1
fi
exit "$status"
