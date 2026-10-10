#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case $(hostname) in *build-host*|*build-host*|build-host*) ;; *) echo 'Run acceptance on build-host only.' >&2; exit 1;; esac
export CHECKMATE_EVIDENCE_DIR=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-acceptance.XXXXXX)}
mkdir -p "$CHECKMATE_EVIDENCE_DIR"
bash scripts/test-ui.sh
python3 scripts/test-startup-settings.py
python3 scripts/test-sidebar.py
bash scripts/test-fullscreen.sh
bash scripts/test-layout.sh
python3 scripts/test-lifecycle.py
bash scripts/test-integration.sh
xcrun swiftc Tools/legacy-store-test.swift -o "$CHECKMATE_EVIDENCE_DIR/legacy-store-test"
"$CHECKMATE_EVIDENCE_DIR/legacy-store-test" Tools/legacy-export.js "$CHECKMATE_EVIDENCE_DIR/legacy-export.json"
CHECKMATE_LEGACY_EXPORT="$CHECKMATE_EVIDENCE_DIR/legacy-export.json" CHECKMATE_AUTOMATION=1 swift test > "$CHECKMATE_EVIDENCE_DIR/swift-tests.log" 2>&1
bash scripts/test-relocated-package.sh
python3 scripts/check-package.py build/CheckmateAutomation.app > "$CHECKMATE_EVIDENCE_DIR/package-results.json"
python3 scripts/aggregate-evidence.py "$CHECKMATE_EVIDENCE_DIR"
