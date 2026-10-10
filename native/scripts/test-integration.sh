#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
checkmate_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-integration.XXXXXX)}
mkdir -p "$checkmate_evidence"
checkmate_launcher=()
if [[ -n "${CHECKMATE_EXECUTION_ARCH:-}" ]]; then
 case "$CHECKMATE_EXECUTION_ARCH" in arm64|x86_64) ;; *) echo 'Invalid execution architecture' >&2;exit 1;; esac
 checkmate_launcher=(/usr/bin/arch "-$CHECKMATE_EXECUTION_ARCH")
fi
checkmate_data=$(mktemp -d /tmp/checkmate-integration-state.XXXXXX)
CHECKMATE_AUTOMATION=1 "${checkmate_launcher[@]}" build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative --automation --data-dir "$checkmate_data" --companion-test > "$checkmate_evidence/broker-app.log" 2>&1 &
checkmate_pid=$!
trap 'kill "$checkmate_pid" 2>/dev/null || true' EXIT
for ((i=0;i<30;i++)); do [[ -f "$checkmate_data/companion/connection.json" ]] && break; sleep 1; done
python3 scripts/test-integration.py build/CheckmateAutomation.app/Contents/MacOS/CheckmateMCP "$checkmate_data/companion/connection.json" > "$checkmate_evidence/broker-coach.json"
kill "$checkmate_pid";wait "$checkmate_pid" || true
for phase in preview opponent; do
 checkmate_data=$(mktemp -d /tmp/checkmate-integration-state.XXXXXX)
 flags=(--companion-test --preview-fixture);if [[ "$phase" == opponent ]];then flags=(--opponent-fixture);fi
 CHECKMATE_AUTOMATION=1 "${checkmate_launcher[@]}" build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative --automation --data-dir "$checkmate_data" "${flags[@]}" > "$checkmate_evidence/broker-$phase.log" 2>&1 &
 checkmate_pid=$!
 for ((i=0;i<30;i++));do [[ -f "$checkmate_data/companion/connection.json" ]] && break;sleep 1;done
 python3 scripts/test-integration.py build/CheckmateAutomation.app/Contents/MacOS/CheckmateMCP "$checkmate_data/companion/connection.json" "$phase" > "$checkmate_evidence/broker-$phase.json"
 kill "$checkmate_pid";wait "$checkmate_pid" || true
done
python3 - "$checkmate_evidence" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]);parts=[json.loads((p/('broker-'+phase+'.json')).read_text()) for phase in ['coach','preview','opponent']];tools=sorted(set(t for part in parts for t in part['tools']));assert len(tools)==13;result={'passed':all(part['passed'] for part in parts),'checks':sum(part['checks'] for part in parts),'tools':tools};(p/'broker-results.json').write_text(json.dumps(result));print(json.dumps(result))
PY
