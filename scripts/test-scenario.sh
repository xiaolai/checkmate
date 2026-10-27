#!/bin/bash
# One in-app acceptance scenario: build the automation app, launch it with --<name>-scenario <evidence>, wait for its
# result file and require that it passed.
#
#   test-scenario.sh [options] <scenario-flag> <result-file> <timeout-seconds> [extra launch args...]
#     --log NAME         the app's log in the evidence folder (default app.log)
#     --stale NAME       another evidence file this run replaces, removed with the result before the build (repeatable)
#     --show FIELD       print only these result fields, in order (scripts/assert-result.py; repeatable)
#     --exited MESSAGE   fail with MESSAGE as soon as the app exits without writing its result
set -euo pipefail
cd "$(dirname "$0")/.."
python3 "$(dirname "$0")/test_host.py" "native UI tests" || exit 1
checkmate_log=app.log
checkmate_stale=()
checkmate_show=()
checkmate_exited=""
while [[ $# -gt 0 && "$1" == --* && "$1" != --*-scenario ]]; do
    case "$1" in
        --log) checkmate_log=$2;;
        --stale) checkmate_stale+=("$2");;
        --show) checkmate_show+=("$2");;
        --exited) checkmate_exited=$2;;
        *) echo "Unknown option $1" >&2; exit 2;;
    esac
    shift 2
done
[[ $# -ge 3 && "$1" == --*-scenario && "$3" =~ ^[1-9][0-9]*$ ]] || { echo 'Usage: test-scenario.sh [options] <--x-scenario> <result-file> <timeout-seconds> [extra launch args...]' >&2; exit 2; }
checkmate_flag=$1 checkmate_result=$2 checkmate_timeout=$3
shift 3
checkmate_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-ui.XXXXXX)}
mkdir -p "$checkmate_evidence"
# A previous result must never satisfy the wait for this run.
checkmate_remove=("$checkmate_evidence/$checkmate_result")
for checkmate_name in ${checkmate_stale[@]+"${checkmate_stale[@]}"}; do checkmate_remove+=("$checkmate_evidence/$checkmate_name"); done
rm -f "${checkmate_remove[@]}"
checkmate_data=$(mktemp -d "${TMPDIR:-/tmp}/checkmate-ui-state.XXXXXX")
CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate.native-automation CHECKMATE_APP_NAME=CheckmateAutomation bash build.sh > "$checkmate_evidence/build.log" 2>&1
checkmate_launcher=()
if [[ -n "${CHECKMATE_EXECUTION_ARCH:-}" ]]; then
    case "$CHECKMATE_EXECUTION_ARCH" in arm64|x86_64) ;; *) echo 'Invalid execution architecture' >&2;exit 1;; esac
    checkmate_launcher=(/usr/bin/arch "-$CHECKMATE_EXECUTION_ARCH")
fi
CHECKMATE_AUTOMATION=1 ${checkmate_launcher[@]+"${checkmate_launcher[@]}"} build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative --automation --data-dir "$checkmate_data" "$checkmate_flag" "$checkmate_evidence" ${@+"$@"} > "$checkmate_evidence/$checkmate_log" 2>&1 &
checkmate_pid=$!
# The app is stopped before its state is removed, so nothing writes into a folder being deleted.
trap 'kill "$checkmate_pid" 2>/dev/null || true;wait "$checkmate_pid" 2>/dev/null || true;rm -rf "$checkmate_data"' EXIT
# Polled five times a second for the same deadline of <timeout-seconds>.
for ((i=0;i<checkmate_timeout*5;i++)); do
    [[ -f "$checkmate_evidence/$checkmate_result" ]] && break
    # The app may write its results and exit between the check above and this one: look once more before failing.
    [[ -z "$checkmate_exited" ]] || kill -0 "$checkmate_pid" 2>/dev/null || [[ -f "$checkmate_evidence/$checkmate_result" ]] || { echo "$checkmate_exited" >&2; exit 1; }
    sleep 0.2
done
python3 scripts/assert-result.py "$checkmate_evidence/$checkmate_result" ${checkmate_show[@]+"${checkmate_show[@]}"}
printf '%s\n' "$checkmate_evidence"
