#!/bin/bash
# The unit gate: the legacy-store export round trip, both XCTest bundles and the Python self-tests.
# SwiftPM builds with the user's temp folder, where its lock files coordinate concurrent builds of this checkout
# (it also leaves empty TemporaryDirectory.* folders there). The test bundles then run directly under the gate's
# private TMPDIR, so anything a test leaves behind fails the gate (scripts/run-gates.py).
set -euo pipefail
cd "$(dirname "$0")/.."
evidence=${CHECKMATE_EVIDENCE_DIR:?Set CHECKMATE_EVIDENCE_DIR}
swiftpm_tmp=$(getconf DARWIN_USER_TEMP_DIR)
xcrun swiftc Tools/legacy-store-test.swift -o "$evidence/legacy-store-test"
"$evidence/legacy-store-test" Tools/legacy-export.js "$evidence/legacy-export.json"
TMPDIR="$swiftpm_tmp" swift build --build-tests > "$evidence/swift-build-tests.log" 2>&1
bin=$(TMPDIR="$swiftpm_tmp" swift build --show-bin-path)
runner=$(xcrun --find xctest)
: > "$evidence/swift-tests.log"
for suite in CheckmateDomainTests CheckmateCoreTests CheckmateNativeTests CheckmateMCPTests; do
  CHECKMATE_LEGACY_EXPORT="$evidence/legacy-export.json" CHECKMATE_AUTOMATION=1 "$runner" "$bin/$suite.xctest" >> "$evidence/swift-tests.log" 2>&1
done
python3 -I Tools/test-lesson-action-alignment.py
python3 -I Tools/test-import-cedar.py
python3 -I Tools/test-narration-coverage.py
# Lesson sources: baseline parity, reviewed illustrations, practice relations and current exports.
python3 -I Tools/prepare-lesson-scripts.py --check > /dev/null
python3 -I Tools/test-lesson-rules.py
python3 -I Tools/test-provenance.py
python3 -I Tools/build-game-library.py --check
python3 -I Tools/test-record-lessons.py
python3 -I Tools/prepare-training-content.py --check
python3 -I Tools/test-prepare-training-content.py
python3 scripts/test-run-gates.py
