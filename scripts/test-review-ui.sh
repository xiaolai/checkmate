#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 "$(dirname "$0")/test_host.py" "native UI tests" || exit 1
checkmate_review_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-review-ui.XXXXXX)}
mkdir -p "$checkmate_review_evidence"
rm -f "$checkmate_review_evidence"/review-ui-results.json "$checkmate_review_evidence"/shutdown-persistence-result.json \
  "$checkmate_review_evidence"/open-panel-ready.json "$checkmate_review_evidence"/ax-request-*.json "$checkmate_review_evidence"/ax-result-*.json
checkmate_review_data=$(mktemp -d "${TMPDIR:-/tmp}/checkmate-review-state.XXXXXX")
CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate.native-review-automation CHECKMATE_APP_NAME=CheckmateReviewAutomation bash build.sh > "$checkmate_review_evidence/build.log" 2>&1
# The out-of-process helper answers the scenario's accessibility requests and clicks with the real pointer.
xcrun swiftc Tools/ReviewScenario.swift -o "$checkmate_review_evidence/review-scenario-helper"
"$checkmate_review_evidence/review-scenario-helper" "$checkmate_review_evidence" > "$checkmate_review_evidence/helper.log" 2>&1 &
checkmate_helper_pid=$!
CHECKMATE_AUTOMATION=1 build/CheckmateReviewAutomation.app/Contents/MacOS/CheckmateNative --automation --data-dir "$checkmate_review_data" --review-scenario "$checkmate_review_evidence" > "$checkmate_review_evidence/app.log" 2>&1 &
checkmate_review_pid=$!
trap 'kill "$checkmate_review_pid" "$checkmate_helper_pid" 2>/dev/null || true;wait "$checkmate_review_pid" "$checkmate_helper_pid" 2>/dev/null || true;rm -rf "$checkmate_review_data"' EXIT
for ((i=0;i<900;i++)); do
  [[ -f "$checkmate_review_evidence/review-ui-results.json" ]] && break
  # Both processes may finish between the check above and these: look for the results once more before failing.
  kill -0 "$checkmate_helper_pid" 2>/dev/null || [[ -f "$checkmate_review_evidence/review-ui-results.json" ]] || { echo 'Review scenario helper exited early:' >&2; cat "$checkmate_review_evidence/helper.log" >&2; exit 1; }
  kill -0 "$checkmate_review_pid" 2>/dev/null || [[ -f "$checkmate_review_evidence/review-ui-results.json" ]] || { echo 'Review scenario app exited before writing results' >&2; exit 1; }
  sleep 1
done
[[ -f "$checkmate_review_evidence/review-ui-results.json" ]] || { echo 'Review scenario timed out' >&2; exit 1; }
# The helper verifies that the scenario's normal termination persisted the latest cursor and ideas.
wait "$checkmate_helper_pid" || { echo 'Review scenario helper failed:' >&2; cat "$checkmate_review_evidence/helper.log" >&2; exit 1; }
python3 - "$checkmate_review_evidence" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
value=json.loads((p/'review-ui-results.json').read_text());shutdown=json.loads((p/'shutdown-persistence-result.json').read_text())
# The saved result carries the shutdown check, so the gate's result check (gate_check: any false flag fails) sees it.
value['shutdownPersistence']=shutdown['passed'] is True
(p/'review-ui-results.json').write_text(json.dumps(value,indent=2))
print(json.dumps(value));assert value['passed'],value;assert shutdown['passed'],shutdown
PY
