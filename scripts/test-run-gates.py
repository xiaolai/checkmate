"""Self-test of targeted gate selection; pure file checks, launches nothing, runs on any Mac.

Simulates edits by altering one recorded hash in a scratch ledger, then asserts which gates the runner selects.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
runner = root / 'scripts/run-gates.py'
spec = json.loads((root / 'scripts/gates.json').read_text())
hashes = json.loads(subprocess.check_output([sys.executable, str(root / 'scripts/source-hashes.py'), str(root)], text=True))
sys.path.insert(0, str(root / 'scripts'))
gates = __import__('importlib').import_module('run-gates')

subprocess.run([sys.executable, str(runner), '--check-map'], check=True, stdout=subprocess.DEVNULL)
# A pattern left pointing at a moved file is reported, not silently ignored.
assert gates.dead_patterns(hashes) == []
assert 'intel: Sources/CheckmateEngine/Engine.swift' in gates.dead_patterns({k: v for k, v in hashes.items() if k != 'Sources/CheckmateEngine/Engine.swift'})


def selected(edited: list, never_passed=(), redefined=()) -> set:
    ledger = {}
    for gate in spec['gates']:
        if gate['name'] in never_passed:
            continue
        recorded = gates.inputs(gate, hashes)
        ledger[gate['name']] = {'inputs': {path: ('edited' if path in edited else digest) for path, digest in recorded.items()},
                                'definition': 'changed' if gate['name'] in redefined else gates.definition(gate['name'])}
    # One frozen snapshot of the tree: the selection is judged against the same hashes the ledger was built from.
    return {name for name in gates.ORDER if gates.stale_reason(name, hashes, ledger) is not None}


# Every helper program a gate's script names (Tools/*, scripts/*.py) must be one of that gate's inputs, so editing a helper reruns it.
# The runner's own files run the scripts rather than serve them, so a script that names the runner does not depend on it.
RUNNER = {'scripts/run-gates.py', 'scripts/gate_check.py', 'scripts/test-run-gates.py', 'scripts/aggregate-evidence.py', 'scripts/source-hashes.py'}
for gate in spec['gates']:
    for script in re.findall(r'scripts/[\w.-]+\.(?:py|sh)', gate['run']):
        if script in RUNNER:
            continue
        text = (root / script).read_text()
        tokens = set(re.findall(r'[\w.-]+', text))  # a helper is named with or without its extension
        named = {path for path in hashes if (path.startswith('Tools/') or (path.startswith('scripts/') and path.endswith('.py'))) and path != script and path not in RUNNER and not gates.matches(path, list(spec['untested']))
                 and ({pathlib.PurePath(path).name, pathlib.PurePath(path).stem} & tokens)}
        missing = sorted(path for path in named if path not in gates.inputs(gate, hashes))
        assert not missing, f"{gate['name']}: {script} uses {missing}, which are not inputs of the gate"

every = {gate['name'] for gate in spec['gates']}
cases = [
    ([], set()),
    (['Sources/CheckmateDomain/MiniGames.swift'], every),
    (['Tools/pointer-helper.swift'], {'pointer', 'lesson-remediation', 'lesson-exercise', 'board-clicks', 'training-pointer', 'training-b-pointer', 'network-ui', 'network-bonjour', 'network-lan'}),
    (['Tests/CheckmateNativeTests/BoardClickTests.swift'], {'architecture', 'unit'}),
    # Play on Network: the loopback gate always; the Bonjour and two-Mac gates too, behind their prerequisites.
    (['Sources/CheckmateMacPlatform/NWNetworkTransport.swift'], {'architecture', 'ui', 'network-ui', 'network-bonjour', 'network-lan', 'unit', 'package'}),
    (['scripts/test-network-lan.py'], {'network-lan'}),
    (['Sources/CheckmateNative/ReviewViews.swift'], {'architecture', 'ui', 'sidebar', 'layout', 'review-ui', 'pointer', 'unit', 'package'}),
    # The library table is exercised by the real-pointer and review-scenario gates, not only by the shared UI build.
    (['Sources/CheckmateNative/LibraryTableView.swift'], {'architecture', 'ui', 'review-ui', 'pointer', 'unit', 'package', 'network-ui'}),
    (['Sources/CheckmateNative/ReviewDetailViews.swift'], {'architecture', 'ui', 'sidebar', 'layout', 'review-ui', 'pointer', 'unit', 'package', 'network-ui'}),
    (['Sources/CheckmateCore/Resources/game-library/manifest.json'], {'architecture', 'ui', 'sidebar', 'pointer', 'integration', 'review-ui', 'unit', 'relocated', 'package'}),
    (['Content/game-library/selection.json'], {'sidebar', 'pointer', 'review-ui', 'unit'}),
    (['Content/openings/a.tsv'], {'sidebar', 'pointer', 'review-ui', 'unit'}),
    (['Tools/build-game-library.py'], {'unit'}),
    (['Sources/CheckmateApplication/GameCollections.swift'], {'architecture', 'ui', 'sidebar', 'pointer', 'review-ui', 'unit', 'package'}),
    (['Sources/CheckmateMCPKit/BrokerClient.swift'], {'architecture', 'integration', 'unit', 'package'}),
    (['build.sh'], every),
    (['Sources/CheckmateApplication/GameSession.swift'], every),
    (['scripts/release.sh'], set()),
]
for edited, expected in cases:
    actual = selected(edited)
    assert actual == expected, f'{edited}: selected {sorted(actual)}, expected {sorted(expected)}'
assert selected([], never_passed={'lifecycle'}) == {'lifecycle'}, 'A gate that never passed must run'
assert selected([], redefined={'layout'}) == {'layout'}, 'A gate whose command or checks changed must run'
# A gate that leaves temporary files fails: run-gates gives each gate a private TMPDIR and reports what remains in it.
scratch = pathlib.Path(tempfile.mkdtemp())
assert gates.temporary_leftovers(scratch) == [], 'An empty TMPDIR must report nothing'
(scratch / 'checkmate-ui-state.abc').mkdir()
assert gates.temporary_leftovers(scratch) == ['checkmate-ui-state.abc'], 'A leftover state folder must be reported'
shutil.rmtree(scratch)

# Every test program runs in some gate: a test listed as untested would never run, and could rot unseen.
test_programs = [path for path in hashes if re.search(r'(^|/)test[-_][^/]*\.(py|sh)$|Tests\.swift$', path)]
exempt = sorted(path for path in test_programs if gates.matches(path, list(spec['untested'])))
assert not exempt, f'Test programs listed as untested never run: {exempt}'

# The checks a run applies are the ones it fingerprints: loaded from the same text, and any edit to that text changes it.
assert gates.GATE_CHECK_SOURCE == (root / 'scripts/gate_check.py').read_text(), 'gate_check.py changed while the self-test ran'
assert gates.check_gate.__code__.co_filename == str(root / 'scripts/gate_check.py')
assert gates.definition('unit', gates.GATE_CHECK_SOURCE) == gates.definition('unit')
assert gates.definition('unit', gates.GATE_CHECK_SOURCE + '#') != gates.definition('unit'), 'An edited check must change the definition'
# Acceptance runs only on the Mac whose marker names it the test host: a Mac without a marker, or the build host, is
# refused, and a marker naming an unknown role stops the run instead of passing as "not a test host".
import test_host
with tempfile.TemporaryDirectory() as home:
    marker = pathlib.Path(home) / test_host.ROLE_FILE
    assert test_host.host_roles(home) == frozenset() and not test_host.is_test_host(home)
    marker.parent.mkdir(parents=True)
    marker.write_text('test\n')
    assert test_host.is_test_host(home)
    marker.write_text('build\n')
    assert test_host.host_roles(home) == {'build'} and not test_host.is_test_host(home)
    # One Mac may hold both roles; the Swift guards accept the same marker.
    marker.write_text('test build\n')
    assert test_host.host_roles(home) == {'test', 'build'} and test_host.is_test_host(home)
    for refused in ('tester\n', 'test tester\n', '\n'):
        marker.write_text(refused)
        try:
            test_host.host_roles(home)
            raise AssertionError(f'A marker holding {refused!r} must be refused')
        except SystemExit:
            pass
# Prerequisites (LAN-play plan D14): checked before anything builds; never a quiet skip, never a certified full run.
import contextlib
import io
import os
fake_gate = {'name': 'network-lan-fixture', 'run': 'true', 'result': 'none.json', 'key': 'none', 'inputs': [], 'prerequisites': ['bonjour-ready', 'lan-pair']}
saved = (dict(gates.GATES), list(gates.ORDER), dict(gates.PREREQUISITES), gates.run, gates.stale_reason, dict(os.environ), list(sys.argv))
ran = []
try:
    gates.GATES[fake_gate['name']] = fake_gate
    gates.ORDER.append(fake_gate['name'])
    # No pair configured, and no bonjour-ready evidence: both checks say why without touching the network.
    os.environ.pop('CHECKMATE_LAN_PAIR', None)
    assert 'CHECKMATE_LAN_PAIR' in gates.lan_pair() and 'CHECKMATE_LAN_PAIR' in gates.bonjour_ready_pair()
    with tempfile.TemporaryDirectory() as home:
        os.environ['HOME'] = home
        assert 'no bonjour-ready evidence' in gates.bonjour_ready()
        os.environ['HOME'] = saved[5]['HOME']
    # Evidence made for another identity, account or system no longer holds.
    good = {'fingerprint': 'F', 'bundleID': gates.AUTOMATION_BUNDLE, 'account': 'ops', 'macOSBuild': 'B'}
    assert gates._evidence_problem(good, 'F', 'ops', 'B', 'here') is None
    assert 'cannot read the current fingerprint' in gates._evidence_problem(good, '', 'ops', 'B', 'here'), 'a missing identity must not pass'
    assert 'not a JSON object' in gates._evidence_problem(['not', 'an', 'object'], 'F', 'ops', 'B', 'here'), 'a record that is not an object must not crash or pass'
    for key, value in (('fingerprint', 'G'), ('bundleID', 'other'), ('account', 'someone'), ('macOSBuild', 'C')):
        assert key in (gates._evidence_problem({**good, key: value}, 'F', 'ops', 'B', 'here') or ''), f'a changed {key} must invalidate bonjour-ready'
    gates.PREREQUISITES.update({'bonjour-ready': lambda: None, 'bonjour-ready-pair': lambda: None, 'lan-pair': lambda: 'no LAN pair configured'})
    assert gates.unmet(gates.ORDER) == {name: [('lan-pair', 'no LAN pair configured')] for name in (fake_gate['name'], 'network-lan')}
    assert gates.GATES['network-bonjour']['prerequisites'] == ['bonjour-ready']
    gates.run = lambda names, full=False: ran.append((list(names), full)) or 0
    ledger = pathlib.Path(tempfile.mkdtemp()) / 'ledger.json'
    os.environ['CHECKMATE_GATE_LEDGER'] = str(ledger)

    def main(*arguments):
        sys.argv = ['run-gates.py', *arguments]
        with contextlib.redirect_stderr(io.StringIO()) as errors, contextlib.redirect_stdout(io.StringIO()):
            status = gates.main()
        return status, errors.getvalue()
    # --changed: the stale network gate is UNVERIFIED, the other stale gates still run, and the run fails.
    gates.stale_reason = lambda name, hashes, ledger: 'never passed' if name in (fake_gate['name'], 'unit') else None
    status, errors = main('--changed')
    assert status == gates.UNVERIFIED and f"UNVERIFIED {fake_gate['name']}: needs lan-pair" in errors, (status, errors)
    assert ran == [(['unit'], False)], ran
    # --only: stops at once, before anything runs or builds.
    ran.clear()
    status, errors = main('--only', fake_gate['name'])
    assert status == gates.UNVERIFIED and ran == [] and 'lan-pair' in errors
    # A full run refuses to certify: nothing runs and no acceptance.json is written.
    with tempfile.TemporaryDirectory() as evidence:
        os.environ['CHECKMATE_EVIDENCE_DIR'] = evidence
        status, errors = main('--full')
        assert status == gates.UNVERIFIED and ran == [] and not (pathlib.Path(evidence) / 'acceptance.json').exists() and 'cannot be certified' in errors
    shutil.rmtree(ledger.parent, ignore_errors=True)
finally:
    gates.GATES.clear(); gates.GATES.update(saved[0]); gates.ORDER[:] = saved[1]; gates.PREREQUISITES.clear(); gates.PREREQUISITES.update(saved[2])
    gates.run, gates.stale_reason = saved[3], saved[4]
    os.environ.clear(); os.environ.update(saved[5]); sys.argv[:] = saved[6]
# The Swift guards cannot import test_host, so each reads the marker itself; none may drift from it.
for guard in ['Tools/ReviewScenario.swift', 'Tools/Acceptance/Probe.swift', 'Tools/calibrate-opponents.swift', 'Tools/lan-vm.swift', 'Tools/lan-vm-input.swift']:
    assert test_host.ROLE_FILE in (root / guard).read_text(), f'{guard} does not read ~/{test_host.ROLE_FILE}'
# A crash report of this checkout's app fails the gate whose apps were running, even when that gate exited 0 and the report
# arrives during a later gate; another checkout's build, another program, and a report that is not JSON are not blamed.
with tempfile.TemporaryDirectory() as reports:
    reports = pathlib.Path(reports)
    def report(file, app, uuid, captured):
        (reports / file).write_text(json.dumps({'app_name': app, 'slice_uuid': uuid}) + '\n' + json.dumps({'captureTime': captured}))
    report('CheckmateNative-ours.ips', 'CheckmateNative', '1DBA8679-7997-3AF0-99BC-741872B92F67', '2026-10-16 20:44:03.6928 +0800')
    report('CheckmateNative-other.ips', 'CheckmateNative', '00000000-0000-0000-0000-000000000000', '2026-10-16 20:44:03.0000 +0800')
    report('Finder-ours.ips', 'Finder', '1dba8679-7997-3af0-99bc-741872b92f67', '2026-10-16 20:44:03.0000 +0800')
    (reports / 'Partial.ips').write_text('not a report')
    found = gates.crashes(gates.crash_reports(reports), {'1dba8679-7997-3af0-99bc-741872b92f67'})
    assert [r.name for _, r in found] == ['CheckmateNative-ours.ips'], found
    crashed = found[0][0]
    windows = [('intel', crashed - 400, crashed + 2), ('relocated', crashed + 20, crashed + 22)]
    assert gates.attribute(windows, found) == {'intel': ['CheckmateNative-ours.ips']}, 'a report written during relocated still blames intel'
    assert gates.attribute([('relocated', crashed + 20, crashed + 22)], found) == {'relocated': ['CheckmateNative-ours.ips']}, 'a crash before any gate began'
    assert gates.attribute(windows, []) == {}
    assert gates.crash_reports(reports / 'missing') == set()
    # A report captured before this run began is an earlier run's, written late: it blames no gate of this run.
    assert gates.attribute(windows, found, since=crashed + 1) == {}, "an earlier run's late report blamed this run"
    assert gates.attribute(windows, found, since=crashed - 1) == {'intel': ['CheckmateNative-ours.ips']}
    # A late crash is checked however the run ends: a gate that failed later still clears the crashed gate's pass.
    saved = (gates.crash_reports, gates.built_uuids, gates.update_ledger, gates.time.sleep)
    cleared = []
    try:
        gates.crash_reports, gates.built_uuids = (lambda directory=None: set(found_reports)), (lambda root=None: set())
        found_reports = {reports / 'CheckmateNative-ours.ips'}
        gates.update_ledger, gates.time.sleep = cleared.append, (lambda seconds: None)
        with contextlib.redirect_stdout(io.StringIO()):
            assert gates.late_crashes(windows, set(), {'1dba8679-7997-3af0-99bc-741872b92f67'}, crashed - 500), 'a late crash was not found'
        assert cleared == [{'intel': None}], f'the crashed gate kept its pass: {cleared}'
        assert not gates.late_crashes([], set(), set(), 0), 'no gate ran, so nothing can have crashed late'
    finally:
        gates.crash_reports, gates.built_uuids, gates.update_ledger, gates.time.sleep = saved
# Clearing Notification Center never stops acceptance: a stalled or missing osascript is a warning, not an exception.
saved_run = gates.subprocess.run
try:
    for problem in (gates.subprocess.TimeoutExpired('osascript', 60), FileNotFoundError('osascript')):
        def stalled(*arguments, problem=problem, **options):
            raise problem
        gates.subprocess.run, printed = stalled, io.StringIO()
        with contextlib.redirect_stdout(printed):
            gates.clear_notifications()
        assert 'WARNING: could not clear Notification Center' in printed.getvalue(), printed.getvalue()
finally:
    gates.subprocess.run = saved_run
print(f'Gate selection self-test passed ({len(cases) + 22} cases).')
