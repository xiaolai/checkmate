#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
checkmate_evidence=${CHECKMATE_EVIDENCE_DIR:?}
checkmate_copy=$(mktemp -d /tmp/checkmate-relocated.XXXXXX)
trap 'rm -rf "$checkmate_copy"' EXIT
ditto build/CheckmateAutomation.app "$checkmate_copy/Checkmate.app"
(cd "$checkmate_copy"; env -i PATH=/usr/bin:/bin CHECKMATE_AUTOMATION=1 ./Checkmate.app/Contents/MacOS/CheckmateNative --package-check "$checkmate_evidence/relocated-results.json")
python3 - "$checkmate_evidence/relocated-results.json" "$checkmate_copy" <<'PY'
import json,sys,pathlib
result=json.load(open(sys.argv[1]));assert result['passed'] and pathlib.Path(result['resourceRoot']).is_relative_to(pathlib.Path(sys.argv[2]).resolve()),result
PY
