#!/bin/bash
# Execute Intel XCTest bundles under Rosetta; SwiftPM's host helper is ARM-only on Xcode 27.
set -euo pipefail
cd "$(dirname "$0")/.."
case $(hostname) in *build-host*|*build-host*|build-host*) ;; *) echo 'Run Intel acceptance on build-host only.' >&2; exit 1;; esac
checkmate_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-intel-acceptance.XXXXXX)}
mkdir -p "$checkmate_evidence"
checkmate_scratch="$PWD/.build-intel"
swift build --build-tests --arch x86_64 --scratch-path "$checkmate_scratch" > "$checkmate_evidence/build.log" 2>&1
checkmate_bin=$(swift build --show-bin-path --arch x86_64 --scratch-path "$checkmate_scratch")
checkmate_runner=$(xcrun --find xctest)
lipo -verify_arch x86_64 "$checkmate_runner"
for checkmate_suite in CheckmateCoreTests CheckmateMCPTests; do
 CHECKMATE_AUTOMATION=1 /usr/bin/arch -x86_64 "$checkmate_runner" "$checkmate_bin/$checkmate_suite.xctest" > "$checkmate_evidence/$checkmate_suite.log" 2>&1
done
CHECKMATE_EXECUTION_ARCH=x86_64 CHECKMATE_EVIDENCE_DIR="$checkmate_evidence/ui" bash scripts/test-ui.sh
CHECKMATE_EXECUTION_ARCH=x86_64 CHECKMATE_EVIDENCE_DIR="$checkmate_evidence/mcp" bash scripts/test-integration.sh
python3 scripts/check-package.py build/CheckmateAutomation.app > "$checkmate_evidence/package.json"
printf '%s\n' "$checkmate_evidence"
