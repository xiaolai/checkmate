#!/bin/bash
set -euo pipefail
# Every Python check here is written with assert: an inherited PYTHONOPTIMIZE would silently skip them all.
unset PYTHONOPTIMIZE
cd "$(dirname "$0")/.."
source Version.env
# Acceptance evidence (scripts/acceptance.sh writes acceptance.json last, only when every gate passed on an unchanged
# tree) and the live-voice report are each checked when named and warned about when not; the warning is never silent.
# CHECKMATE_SKIP_VERIFICATION_REASON, optional, says why in it.
evidence=${CHECKMATE_ACCEPTANCE_EVIDENCE:-} live=${CHECKMATE_LIVE_VOICE_REPORT:-} skip_reason=${CHECKMATE_SKIP_VERIFICATION_REASON:-}
safe_reason='^[A-Za-z0-9 .,:;/_()-]+$'
[[ -z "$skip_reason" || "$skip_reason" =~ $safe_reason ]] || { echo "error: CHECKMATE_SKIP_VERIFICATION_REASON has characters a remote shell could misread; use plain words, digits and .,:;/_()- only" >&2; exit 1; }
if [[ -n "$evidence" ]]; then
    accepted_tree() {
    python3 scripts/source-hashes.py --compare "$evidence/acceptance.json" --key sourceHashes . \
        || { echo "error: The tree differs from the accepted acceptance run" >&2; return 1; }
    }
else
    echo "WARNING: packaging without accepted acceptance evidence${skip_reason:+: $skip_reason}" >&2
    accepted_tree() { :; }
fi
if [[ -n "$live" ]]; then
    # The voice coach was exercised against the live provider for this same tree (scripts/live-voice.sh on the test host).
    live_voice_tree() {
    # Called inside an && list, where set -e is off: each step must stop the function itself.
    python3 - "$live" <<'PY' || return 1
import json,sys
report=json.load(open(sys.argv[1]))
assert report.get('passed') is True,'The live voice report did not pass'
turns={turn.get('language'):turn for turn in report.get('coachTurns',[])}
assert all(turns.get(language,{}).get('passed') is True for language in ('en','zh','es')),'The live coach turn is missing or failed in a language'
assert report.get('preview',{}).get('passed') is True,'The live voice preview is missing or failed'
PY
    python3 scripts/source-hashes.py --compare "$live" --key sourceHashes . \
        || { echo "error: The tree differs from the live voice run" >&2; return 1; }
    }
else
    echo "WARNING: packaging without a live-voice report${skip_reason:+: $skip_reason}" >&2
    live_voice_tree() { :; }
fi
# The release is built from a private snapshot (0700, this process only), checked against the accepted run before the
# build and again after it: an edit to the working tree while it builds can neither reach nor slip past the binary.
snapshot=$(mktemp -d /tmp/checkmate-release-source.XXXXXX)
trap 'rm -rf "$snapshot"' EXIT
rsync -a --exclude=/.git --exclude='/.build*' --exclude=/build --exclude=/evidence ./ "$snapshot/"
# With no evidence file to anchor against, skipped verification still must not let the build mutate tracked sources.
baseline=$(mktemp)
trap 'rm -rf "$snapshot" "$baseline"' EXIT
[[ -n "$evidence" ]] || (cd "$snapshot" && python3 scripts/source-hashes.py .) > "$baseline"
(cd "$snapshot" && accepted_tree && live_voice_tree)
(cd "$snapshot" && CHECKMATE_CONFIGURATION=release CHECKMATE_APP_NAME=Checkmate CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate bash build.sh)
(cd "$snapshot" && accepted_tree)
if [[ -z "$evidence" ]]; then
    diff -q "$baseline" <(cd "$snapshot" && python3 scripts/source-hashes.py .) >/dev/null \
        || { echo "error: build.sh modified tracked sources" >&2; exit 1; }
fi
out="$PWD/build/release"
mkdir -p "$out"
rm -rf "$out/Checkmate.app"
ditto "$snapshot/build/Checkmate.app" "$out/Checkmate.app"
app="$out/Checkmate.app"
python3 -O scripts/check-package.py "$app" --release-identity
ditto -c -k --keepParent "$app" "$out/Checkmate-$CHECKMATE_VERSION.zip"
