#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 "$(dirname "$0")/test_host.py" "native UI tests" || exit 1
checkmate_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-ui.XXXXXX)}
mkdir -p "$checkmate_evidence"
# A previous result must never satisfy the wait for this run.
rm -f "$checkmate_evidence/fullscreen-results.json"
checkmate_data=$(mktemp -d "${TMPDIR:-/tmp}/checkmate-ui-state.XXXXXX")
CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate.native-automation CHECKMATE_APP_NAME=CheckmateAutomation bash build.sh > "$checkmate_evidence/build.log" 2>&1
CHECKMATE_AUTOMATION=1 build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative --automation --data-dir "$checkmate_data" --fullscreen-scenario "$checkmate_evidence" > "$checkmate_evidence/app.log" 2>&1 &
checkmate_pid=$!
# The app is stopped before its state is removed, so nothing writes into a folder being deleted.
trap 'kill "$checkmate_pid" 2>/dev/null || true;wait "$checkmate_pid" 2>/dev/null || true;rm -rf "$checkmate_data"' EXIT
for ((i=0;i<60;i++)); do [[ -f "$checkmate_evidence/fullscreen-results.json" ]] && break; sleep 1; done
python3 - "$checkmate_evidence/fullscreen-results.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]));print(json.dumps(result));assert result['passed'],result
PY
printf '%s\n' "$checkmate_evidence"
