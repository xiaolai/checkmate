#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 "$(dirname "$0")/test_host.py" "native UI tests" || exit 1
checkmate_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-ui.XXXXXX)}
mkdir -p "$checkmate_evidence"
# A previous result must never satisfy the wait for this run.
rm -f "$checkmate_evidence/ui-results.json"
checkmate_data=$(mktemp -d "${TMPDIR:-/tmp}/checkmate-ui-state.XXXXXX")
CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate.native-automation CHECKMATE_APP_NAME=CheckmateAutomation bash build.sh > "$checkmate_evidence/build.log" 2>&1
checkmate_launcher=()
if [[ -n "${CHECKMATE_EXECUTION_ARCH:-}" ]]; then
    case "$CHECKMATE_EXECUTION_ARCH" in arm64|x86_64) ;; *) echo 'Invalid execution architecture' >&2;exit 1;; esac
    checkmate_launcher=(/usr/bin/arch "-$CHECKMATE_EXECUTION_ARCH")
fi
CHECKMATE_AUTOMATION=1 ${checkmate_launcher[@]+"${checkmate_launcher[@]}"} build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative --automation --data-dir "$checkmate_data" --ui-scenario "$checkmate_evidence" > "$checkmate_evidence/app.log" 2>&1 &
checkmate_pid=$!
# The app is stopped before its state is removed, so nothing writes into a folder being deleted.
trap 'kill "$checkmate_pid" 2>/dev/null || true;wait "$checkmate_pid" 2>/dev/null || true;rm -rf "$checkmate_data"' EXIT
for ((i=0;i<100;i++)); do [[ -f "$checkmate_evidence/ui-results.json" ]] && break; sleep 1; done
python3 - "$checkmate_evidence/ui-results.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]));print(json.dumps(result));assert result['passed'],result
PY
printf '%s\n' "$checkmate_evidence"
