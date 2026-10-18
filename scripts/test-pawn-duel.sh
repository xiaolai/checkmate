#!/bin/bash
# Silent test-host acceptance: every lesson mini-game takes a clicked move and the computer replies, and a game won by
# a clicked move opens its post-game review sheet (WI-018).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 "$(dirname "$0")/test_host.py" "native UI tests" || exit 1
checkmate_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-ui.XXXXXX)}
mkdir -p "$checkmate_evidence"
# A previous result must never satisfy the wait for this run.
rm -f "$checkmate_evidence/pawn-duel-results.json"
checkmate_data=$(mktemp -d "${TMPDIR:-/tmp}/checkmate-ui-state.XXXXXX")
CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate.native-automation CHECKMATE_APP_NAME=CheckmateAutomation bash build.sh > "$checkmate_evidence/build.log" 2>&1
CHECKMATE_AUTOMATION=1 build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative --automation --data-dir "$checkmate_data" --pawn-duel-scenario "$checkmate_evidence" > "$checkmate_evidence/pawn-duel-app.log" 2>&1 &
checkmate_pid=$!
# The app is stopped before its state is removed, so nothing writes into a folder being deleted.
trap 'kill "$checkmate_pid" 2>/dev/null || true;wait "$checkmate_pid" 2>/dev/null || true;rm -rf "$checkmate_data"' EXIT
for ((i=0;i<120;i++)); do
  [[ -f "$checkmate_evidence/pawn-duel-results.json" ]] && break
  # The app may write its results and exit between the check above and this one: look once more before failing.
  kill -0 "$checkmate_pid" 2>/dev/null || [[ -f "$checkmate_evidence/pawn-duel-results.json" ]] || { echo 'Mini-game scenario exited before writing results' >&2; exit 1; }
  sleep 1
done
python3 - "$checkmate_evidence/pawn-duel-results.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]));print(json.dumps({"passed":result["passed"],"games":result["games"],"review":result.get("review")}));assert result['passed'],result
PY
