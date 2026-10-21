#!/bin/bash
# Live voice acceptance for a release (D10). It talks to the provider and costs money, so it never runs in a gate: run
# it on the test host, where Codex is signed in, and copy the report to the build machine before scripts/release.sh. It drives the production coach headless (no
# microphone, no speaker): scripted narration, a typed coach turn in en/zh/es, and a Settings voice preview. The report
# carries this tree's source hashes; prepare-release.sh refuses a report from another tree.
set -euo pipefail
unset PYTHONOPTIMIZE
cd "$(dirname "$0")/.."
report=${1:?Usage: scripts/live-voice.sh <report.json>}
# The tree is fingerprinted before building and again after the run; a change in between certifies nothing.
before=$(mktemp /tmp/checkmate-live-voice.XXXXXX);trap 'rm -f "$before"' EXIT
python3 scripts/source-hashes.py . > "$before"
python3 scripts/fresh-sources.py .build -- swift build --product CheckmateAcceptance
.build/debug/CheckmateAcceptance --live-voice "$report"
python3 - "$report" "$before" <<'PY'
import json,subprocess,sys
path,before=sys.argv[1],json.load(open(sys.argv[2]))
report=json.load(open(path))
assert report.get('passed') is True,'Live voice acceptance did not pass'
after=json.loads(subprocess.check_output([sys.executable,'scripts/source-hashes.py','.'],text=True))
changed=sorted(k for k in before.keys()|after.keys() if before.get(k)!=after.get(k))
assert not changed,f'The tree changed during the live run: {changed[:20]}'
report['sourceHashes']=before
with open(path,'w') as f: json.dump(report,f,indent=2,sort_keys=True,ensure_ascii=False)
PY
echo "Live voice report for this tree: $report"
