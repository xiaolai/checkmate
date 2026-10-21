#!/bin/bash
# Execute Intel XCTest bundles under Rosetta; SwiftPM's host helper is ARM-only on Xcode 27.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 "$(dirname "$0")/test_host.py" "Intel acceptance" || exit 1
checkmate_evidence=${CHECKMATE_EVIDENCE_DIR:-$(mktemp -d /tmp/checkmate-intel-acceptance.XXXXXX)}
mkdir -p "$checkmate_evidence"
checkmate_scratch="$PWD/.build-intel"
# SwiftPM keeps its build locks in TMPDIR: always the user's temp folder (see build.sh).
checkmate_swiftpm_tmp=$(getconf DARWIN_USER_TEMP_DIR)
TMPDIR="$checkmate_swiftpm_tmp" python3 scripts/fresh-sources.py "$checkmate_scratch" -- swift build --build-tests --arch x86_64 --scratch-path "$checkmate_scratch" > "$checkmate_evidence/build.log" 2>&1
checkmate_bin=$(TMPDIR="$checkmate_swiftpm_tmp" swift build --show-bin-path --arch x86_64 --scratch-path "$checkmate_scratch")
checkmate_runner=$(xcrun --find xctest)
lipo -verify_arch x86_64 "$checkmate_runner"
for checkmate_suite in CheckmateDomainTests CheckmateCoreTests CheckmateNativeTests CheckmateMCPTests; do
 CHECKMATE_AUTOMATION=1 /usr/bin/arch -x86_64 "$checkmate_runner" "$checkmate_bin/$checkmate_suite.xctest" > "$checkmate_evidence/$checkmate_suite.log" 2>&1
done
CHECKMATE_EXECUTION_ARCH=x86_64 CHECKMATE_EVIDENCE_DIR="$checkmate_evidence/ui" bash scripts/test-ui.sh
CHECKMATE_EXECUTION_ARCH=x86_64 CHECKMATE_EVIDENCE_DIR="$checkmate_evidence/mcp" bash scripts/test-integration.sh
python3 scripts/check-package.py build/CheckmateAutomation.app > "$checkmate_evidence/package.json"
# The gate's result: every step above already exited non-zero on failure (set -e); this records what ran.
python3 - "$checkmate_evidence" <<'PY'
import json,pathlib,re,sys
p=pathlib.Path(sys.argv[1])
def executed(suite):
    counts=re.findall(r"Executed (\d+) tests, with (?:\d+ tests skipped and )?0 failures",(p/f"{suite}.log").read_text())
    assert counts,f"{suite} did not report a passing run";return int(counts[-1])
ui=json.loads((p/'ui'/'ui-results.json').read_text());mcp=json.loads((p/'mcp'/'broker-results.json').read_text())
result={'passed':ui['passed'] is True and mcp['passed'] is True,'domainTests':executed('CheckmateDomainTests'),'coreTests':executed('CheckmateCoreTests'),'nativeTests':executed('CheckmateNativeTests'),'mcpTests':executed('CheckmateMCPTests'),'ui':ui['passed'] is True,'mcp':mcp['passed'] is True}
(p/'intel-results.json').write_text(json.dumps(result,indent=2));print(json.dumps(result));assert result['passed'],result
PY
