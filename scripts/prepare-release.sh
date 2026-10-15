#!/bin/bash
set -euo pipefail
# Every Python check here is written with assert: an inherited PYTHONOPTIMIZE would silently skip them all.
unset PYTHONOPTIMIZE
cd "$(dirname "$0")/.."
source Version.env
# Package only a tree that passed acceptance unchanged (scripts/acceptance.sh writes acceptance.json last).
evidence=${CHECKMATE_ACCEPTANCE_EVIDENCE:?Set CHECKMATE_ACCEPTANCE_EVIDENCE to the passing acceptance evidence directory for this tree}
accepted_tree() {
python3 - "$evidence/acceptance.json" <<'PY'
import json,subprocess,sys
accepted=json.load(open(sys.argv[1]))['sourceHashes']
current=json.loads(subprocess.check_output([sys.executable,'scripts/source-hashes.py','.'],text=True))
changed=sorted(k for k in accepted.keys()|current.keys() if accepted.get(k)!=current.get(k))
assert not changed,f'The tree differs from the accepted acceptance run: {changed[:20]}'
PY
}
# The voice coach was exercised against the live provider for this same tree (scripts/live-voice.sh on the test host).
live=${CHECKMATE_LIVE_VOICE_REPORT:?Set CHECKMATE_LIVE_VOICE_REPORT to the passing scripts/live-voice.sh report for this tree}
live_voice_tree() {
python3 - "$live" <<'PY'
import json,subprocess,sys
report=json.load(open(sys.argv[1]))
assert report.get('passed') is True,'The live voice report did not pass'
turns={turn.get('language'):turn for turn in report.get('coachTurns',[])}
assert all(turns.get(language,{}).get('passed') is True for language in ('en','zh','es')),'The live coach turn is missing or failed in a language'
assert report.get('preview',{}).get('passed') is True,'The live voice preview is missing or failed'
current=json.loads(subprocess.check_output([sys.executable,'scripts/source-hashes.py','.'],text=True))
changed=sorted(k for k in report.get('sourceHashes',{}).keys()|current.keys() if report.get('sourceHashes',{}).get(k)!=current.get(k))
assert not changed,f'The tree differs from the live voice run: {changed[:20]}'
PY
}
# The release is built from a private snapshot (0700, this process only), checked against the accepted run before the
# build and again after it: an edit to the working tree while it builds can neither reach nor slip past the binary.
snapshot=$(mktemp -d /tmp/checkmate-release-source.XXXXXX)
trap 'rm -rf "$snapshot"' EXIT
rsync -a --exclude=/.git --exclude='/.build*' --exclude=/build --exclude=/evidence ./ "$snapshot/"
(cd "$snapshot" && accepted_tree && live_voice_tree)
(cd "$snapshot" && CHECKMATE_CONFIGURATION=release CHECKMATE_APP_NAME=Checkmate CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate bash build.sh)
(cd "$snapshot" && accepted_tree)
out="$PWD/build/release"
mkdir -p "$out"
rm -rf "$out/Checkmate.app"
ditto "$snapshot/build/Checkmate.app" "$out/Checkmate.app"
app="$out/Checkmate.app"
python3 -O scripts/check-package.py "$app" --release-identity
ditto -c -k --keepParent "$app" "$out/Checkmate-$CHECKMATE_VERSION.zip"
