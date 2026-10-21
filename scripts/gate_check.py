"""Result checks shared by the full aggregate (aggregate-evidence.py) and targeted runs (run-gates.py).

Every gate must pass in full: a false flag or a skipped/failed sub-result fails it, not just a false 'passed'.
"""
import json
import pathlib
import re

# These checks are asserts: with assertions disabled (python -O, PYTHONOPTIMIZE) every gate would pass unchecked.
if not __debug__:
    raise SystemExit('Acceptance checks need assertions enabled: unset PYTHONOPTIMIZE and do not run python with -O.')

OPTIONAL_SKIPS = {
    'EngineGoldenTests testHeldOutStrongEvidence',
    # Real Bonjour stays out of routine tests (LAN-play plan D12); the network-bonjour gate exercises it.
    'NetworkLoopbackTests testBonjourPublishesBothListenersAndAJoinPairsThemByGameID',
    # WI-018's proof-search spike: a measurement run on demand (CHECKMATE_MINI_PROOF_SPIKE), not a routine test.
    'MiniGameProofSpikeTests testSpikeMeasurementsAndUsefulnessGate',
    'OpponentCalibrationTests testSeededCompleteGames',
    'ReviewPerformanceTests testImportNavigationAndSelectedLatency',
    'ReviewPerformanceTests testMaximumMainlineNavigationScale',
    'ReviewPerformanceTests testSelectedQuickP95OnActualGame',
    # Wall-time measurement of whole-game analysis (CHECKMATE_REVIEW_RESOURCES); the budget arithmetic itself is
    # ReviewGradeAndDepthTests testTheWholeGameAnalysisFitsItsBudget, which always runs.
    'ReviewPerformanceTests testWholeGameAnalysisFitsItsBudget',
}
EXPECTED_FALSE = {('layout-verification.json', 'settledFrameJump')}


def check_unit(evidence: pathlib.Path) -> dict:
    """The swift test log: all XCTest bundles passed, and only the known optional tests were skipped."""
    log = (evidence / 'swift-tests.log').read_text()
    assert "Test Suite 'All tests' passed" in log, 'swift test did not pass'
    summaries = re.findall(r"Test Suite '([^']+\.xctest)' passed[^\n]*\n\s*Executed (\d+) tests, with (?:(\d+) tests skipped and )?0 failures", log)
    assert {name for name, _, _ in summaries} == {'CheckmateCoreTests.xctest', 'CheckmateMCPTests.xctest', 'CheckmateNativeTests.xctest', 'CheckmateDomainTests.xctest'}, 'Missing XCTest bundle result'
    assert len(summaries) == 4, 'Duplicate XCTest bundle result'
    count = sum(int(total) for _, total, _ in summaries)
    skipped = sum(int(skips or 0) for _, _, skips in summaries)
    skipped_names = re.findall(r"Test Case '-\[CheckmateCoreTests\.(.*?)\]' skipped", log)
    assert len(skipped_names) == skipped, 'Unaccounted skipped tests'
    assert set(skipped_names) <= OPTIONAL_SKIPS, f'Unexpected skipped tests: {set(skipped_names) - OPTIONAL_SKIPS}'
    return {'deterministicTests': count - skipped, 'totalTests': count, 'optionalSkippedTests': skipped_names}


def check_result(evidence: pathlib.Path, file: str, requires: tuple = ()) -> None:
    """A gate's JSON result: passed, every required check present and true, no false flag, no skipped or failed sub-result."""
    value = json.loads((evidence / file).read_text())
    assert value.get('passed') is True, file
    missing = [key for key in requires if value.get(key) is not True]
    assert not missing, f'{file}: required checks missing or not true {missing}'
    bad = [k for k, v in value.items()
           if (v is False and (file, k) not in EXPECTED_FALSE) or (v is True and (file, k) in EXPECTED_FALSE)
           or (isinstance(v, str) and v.startswith('failed'))]
    assert not bad, f'{file}: failed or skipped sub-results {bad}'


def check_gate(evidence: pathlib.Path, gate: dict) -> None:
    if gate['name'] == 'unit':
        check_unit(evidence)
    else:
        check_result(evidence, gate['result'], tuple(gate.get('requires', ())))
