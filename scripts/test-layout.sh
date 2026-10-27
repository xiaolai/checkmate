#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The verification below reads the scenario's evidence, so the folder is chosen here rather than in test-scenario.sh.
export CHECKMATE_EVIDENCE_DIR=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-ui.XXXXXX)}
bash scripts/test-scenario.sh --stale layout-verification.json --show passed --show '#samples' --show failures --layout-scenario layout-results.json 45

python3 scripts/verify-native-layout.py "$CHECKMATE_EVIDENCE_DIR/layout-results.json" > "$CHECKMATE_EVIDENCE_DIR/layout-verification.json"
