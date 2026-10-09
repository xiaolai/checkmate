#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case $(hostname) in *build-host*|*build-host*|build-host*) ;; *) echo 'Run native UI tests on build-host only.' >&2; exit 1;; esac
checkmate_review_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-review-ui.XXXXXX)}
mkdir -p "$checkmate_review_evidence"
rm -f "$checkmate_review_evidence/review-ui-results.json"
checkmate_review_data=$(mktemp -d /tmp/checkmate-review-state.XXXXXX)
CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate.native-review-automation CHECKMATE_APP_NAME=CheckmateReviewAutomation bash build.sh > "$checkmate_review_evidence/build.log" 2>&1
CHECKMATE_AUTOMATION=1 build/CheckmateReviewAutomation.app/Contents/MacOS/CheckmateNative --automation --data-dir "$checkmate_review_data" --review-scenario "$checkmate_review_evidence" > "$checkmate_review_evidence/app.log" 2>&1 &
checkmate_review_pid=$!
trap 'kill "$checkmate_review_pid" 2>/dev/null || true' EXIT
# The scenario also waits for Tools/ReviewScenario.swift accessibility answers.
for ((i=0;i<300;i++)); do [[ -f "$checkmate_review_evidence/review-ui-results.json" ]] && break; sleep 1; done
python3 - "$checkmate_review_evidence/review-ui-results.json" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]));print(json.dumps(value));assert value['passed'],value
PY
