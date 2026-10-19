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
        # A Swift executable's main.swift is named by its target's directory, never by the word "main".
        def names(path):
            p = pathlib.PurePath(path)
            return {p.parent.name} if p.name == 'main.swift' else {p.name, p.stem}
        named = {path for path in hashes if (path.startswith('Tools/') or (path.startswith('scripts/') and path.endswith('.py'))) and path != script and path not in RUNNER and not gates.matches(path, list(spec['untested']))
                 and (names(path) & tokens)}
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
# The runner's own validation and its Notification Center helper are part of what a pass means, for every gate.
assert gates.RUNNER_SOURCE == gates.runner_source(), 'run-gates.py or clear-notifications.applescript changed while the self-test ran'
assert gates.definition('unit', gates.GATE_CHECK_SOURCE, gates.RUNNER_SOURCE) == gates.definition('unit')
assert gates.definition('pointer', gates.GATE_CHECK_SOURCE, gates.RUNNER_SOURCE + '#') != gates.definition('pointer'), 'An edited runner must change every gate\'s definition'
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
for guard in ['Tools/ReviewScenario.swift', 'Tools/Acceptance/Probe.swift', 'Tools/calibrate-opponents.swift', 'Tools/MiniGameCalibration/main.swift', 'Tools/PositionGameCalibration/main.swift', 'Tools/lan-vm.swift', 'Tools/lan-vm-input.swift']:
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
# A helper that exits non-zero (it could not read Notification Center, or an alert's action failed) is a warning too.
try:
    gates.subprocess.run = lambda *arguments, **options: gates.subprocess.CompletedProcess(arguments, 1, '', 'Notification Center could not be read: changed')
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        gates.clear_notifications()
    assert 'WARNING: could not clear Notification Center: Notification Center could not be read' in printed.getvalue(), printed.getvalue()
finally:
    gates.subprocess.run = saved_run
# --list runs nothing: no prerequisite check (they compile a probe and reach the LAN pair), only what each one needs.
saved = (gates.PREREQUISITES.copy(), gates.stale_reason, list(sys.argv), gates.test_host.require)
try:
    def forbidden(*arguments, **options):
        raise AssertionError('--list ran a prerequisite check or required the test host')
    gates.PREREQUISITES.update({name: forbidden for name in gates.PREREQUISITES})
    # Listing works on any Mac: requiring the test host role here would break it on the main Mac.
    gates.test_host.require = forbidden
    gates.stale_reason = lambda name, hashes, ledger: 'never passed'
    sys.argv, printed = ['run-gates.py', '--list'], io.StringIO()
    with contextlib.redirect_stdout(printed):
        assert gates.main() == 0
    assert 'needs bonjour-ready, bonjour-ready-pair, lan-pair (not checked by --list)' in printed.getvalue(), printed.getvalue()
finally:
    gates.PREREQUISITES.clear(); gates.PREREQUISITES.update(saved[0]); gates.stale_reason = saved[1]; sys.argv[:] = saved[2]
    gates.test_host.require = saved[3]
# A run's passes are provisional: a failed check of any kind fails its gate and keeps no pass, and a run that ends
# abnormally (here an interruption during the second gate's checks) forgets every pass it recorded, then re-raises.
# The evidence folder is made absolute first, so a relative one means the same folder to the runner and each gate.
saved = {name: getattr(gates, name) for name in ('tree', 'inputs', 'clear_notifications', 'check_gate', 'built_uuids', 'crash_reports', 'update_ledger', 'late_crashes', 'GATES', 'ORDER')}
saved_require, saved_environment, saved_cwd = gates.test_host.require, dict(os.environ), os.getcwd()
with tempfile.TemporaryDirectory() as work:
    try:
        os.chdir(work)
        os.environ['CHECKMATE_EVIDENCE_DIR'] = 'relative-evidence'
        ledger, checked = [], []
        gates.test_host.require = lambda *arguments, **options: None
        gates.GATES = {name: {'name': name, 'run': 'true', 'result': 'none.json', 'key': 'none', 'inputs': []} for name in ('first', 'second', 'third')}
        gates.ORDER = ['first', 'second', 'third']
        gates.tree, gates.inputs = (lambda: {}), (lambda gate, hashes: {})
        gates.clear_notifications, gates.crash_reports, gates.late_crashes = (lambda: None), (lambda directory=None: set()), (lambda *arguments: False)
        gates.update_ledger = ledger.append
        def check(evidence, gate):
            checked.append(evidence)
            if gate['name'] == 'second':
                raise KeyboardInterrupt
        gates.check_gate, gates.built_uuids = check, (lambda root=None: set())
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                gates.run(['first', 'second', 'third'])
            raise AssertionError('an interrupted run returned')
        except KeyboardInterrupt:
            pass
        assert checked and all(evidence.is_absolute() and evidence == pathlib.Path(work).resolve() / 'relative-evidence' for evidence in checked), checked
        assert ledger[-1] == {'first': None, 'second': None}, f'an interrupted run kept a pass: {ledger}'
        ledger.clear()
        def failed_dwarfdump(root=None):
            raise gates.subprocess.CalledProcessError(1, 'dwarfdump')
        gates.built_uuids = failed_dwarfdump
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            assert gates.run(['first']) == 1, 'a failed crash check passed the gate'
        assert ledger == [{'first': None}] and 'FAILED first' in printed.getvalue(), (ledger, printed.getvalue())
        gates.built_uuids = lambda root=None: set()
        # A gate that fails after another passed still runs the late-crash check, which can take the earlier pass back.
        ledger.clear()
        late_calls = []
        def late(windows, seen, uuids, since):
            late_calls.append([name for name, _, _ in windows])
            gates.update_ledger({'first': None})
            return True
        def second_fails(evidence, gate):
            assert gate['name'] != 'second', 'second failed'
        gates.late_crashes, gates.check_gate = late, second_fails
        with contextlib.redirect_stdout(io.StringIO()):
            assert gates.run(['first', 'second']) == 1
        assert late_calls == [['first', 'second']], f'a failed gate skipped the late-crash check: {late_calls}'
        assert {'second': None} in ledger and {'first': None} in ledger, f'a late crash left a pass: {ledger}'
        gates.late_crashes, gates.check_gate = (lambda *arguments: False), (lambda evidence, gate: None)
        # The evidence folder has one reading, `~` included: the certificate a full run removes is the one it would write.
        home = pathlib.Path(work) / 'home'
        os.environ['HOME'], os.environ['CHECKMATE_EVIDENCE_DIR'] = str(home), '~/evidence'
        assert gates.evidence_path('~/evidence') == (home / 'evidence').resolve()
        certified = home / 'evidence'
        certified.mkdir(parents=True)
        (certified / 'acceptance.json').write_text('{}')
        (certified / 'none.json').write_text('kept')
        # A targeted run never touches a folder a full run certified: it refuses before anything there changes.
        ledger.clear()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
            assert gates.run(['first']) == 2
        assert (certified / 'acceptance.json').exists() and (certified / 'none.json').read_text() == 'kept' and ledger == [], ledger
        assert 'holds a full run' in errors.getvalue(), errors.getvalue()
        # A full run removes the earlier certificate first, even when it then fails.
        gates.check_gate = lambda evidence, gate: (_ for _ in ()).throw(AssertionError('failed'))
        with contextlib.redirect_stdout(io.StringIO()):
            assert gates.run(['first'], full=True) == 1
        assert not (certified / 'acceptance.json').exists(), 'a failed full run under a ~ path kept the earlier certificate'
        gates.check_gate = lambda evidence, gate: None
        os.environ['CHECKMATE_EVIDENCE_DIR'] = 'relative-evidence'
        # A failed preliminary build fails every selected gate that was to run on it; no earlier pass survives.
        gates.GATES['first']['prebuilt'] = True
        ledger.clear()
        saved_subprocess_run = gates.subprocess.run
        def build_fails(command, *arguments, **options):
            if command[:2] == ['bash', 'build.sh']:
                raise gates.subprocess.CalledProcessError(1, command)
            return saved_subprocess_run(command, *arguments, **options)
        gates.subprocess.run = build_fails
        try:
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                assert gates.run(['first', 'second']) == 1
        finally:
            gates.subprocess.run = saved_subprocess_run
            del gates.GATES['first']['prebuilt']
        assert ledger == [{'first': None, 'second': None}] and 'FAILED building' in printed.getvalue(), (ledger, printed.getvalue())
        # An interruption while a gate runs stops the gate's whole process group and still removes its scratch folder.
        ledger.clear()
        signals, scratches = [], []
        class Interrupted:
            def __init__(self, command, **options):
                self.pid, self.waits = 4242, 0
                scratches.append(pathlib.Path(options['env']['TMPDIR']))
            def wait(self, timeout=None):
                self.waits += 1
                if self.waits == 1:
                    raise KeyboardInterrupt
                return -15
        saved_popen, saved_killpg = gates.subprocess.Popen, gates.os.killpg
        gates.subprocess.Popen, gates.os.killpg = Interrupted, (lambda pid, number: signals.append((pid, number)))
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                gates.run(['first'])
            raise AssertionError('an interrupted gate returned')
        except KeyboardInterrupt:
            pass
        finally:
            gates.subprocess.Popen, gates.os.killpg = saved_popen, saved_killpg
        assert signals == [(4242, gates.signal.SIGTERM)], f'the gate\'s process group was not stopped: {signals}'
        assert scratches and not scratches[0].exists(), 'an interrupted gate left its scratch folder'
        assert ledger[-1] == {'first': None}, ledger
        # A matching report still being written when a gate ends is not set aside as seen: the late check reads it again.
        uuid = '1dba8679-7997-3af0-99bc-741872b92f67'
        writing = pathlib.Path(work) / 'CheckmateNative-writing.ips'
        writing.write_text(json.dumps({'app_name': 'CheckmateNative', 'slice_uuid': uuid}) + '\n{"captureTime": "2026-10')
        seen_by_late = []
        # It appears during the gate: the run's first look, before any gate, finds nothing.
        looks = []
        gates.crash_reports = lambda directory=None: looks.append(1) or ({writing} if len(looks) > 1 else set())
        gates.built_uuids = lambda root=None: {uuid}
        gates.late_crashes = lambda windows, seen, uuids, since: seen_by_late.append(set(seen)) or False
        with contextlib.redirect_stdout(io.StringIO()):
            assert gates.run(['first']) == 0
        assert seen_by_late and writing not in seen_by_late[0], f'a report still being written was set aside as seen: {seen_by_late}'
        gates.crash_reports, gates.built_uuids, gates.late_crashes = (lambda directory=None: set()), (lambda root=None: set()), (lambda *arguments: False)
    finally:
        for name, value in saved.items():
            setattr(gates, name, value)
        gates.test_host.require = saved_require
        os.environ.clear(); os.environ.update(saved_environment); os.chdir(saved_cwd)
# `--only ''` (an empty shell variable) is an empty selection, refused, never read as --changed.
saved = (list(sys.argv), gates.run, gates.test_host.require)
try:
    gates.run, gates.test_host.require = (lambda names, full=False: (_ for _ in ()).throw(AssertionError(f'ran {names}'))), (lambda *arguments, **options: None)
    for empty in ('', ' , '):
        sys.argv = ['run-gates.py', '--only', empty]
        with contextlib.redirect_stderr(io.StringIO()) as errors, contextlib.redirect_stdout(io.StringIO()):
            assert gates.main() == 2, f'--only {empty!r} was not refused'
        assert 'No gate named' in errors.getvalue(), errors.getvalue()
finally:
    sys.argv[:], gates.run, gates.test_host.require = saved
# A matching crash report still being written (header whole, body cut short) is read again, never set aside as seen;
# one still unreadable after the settle counts as a crash. A report whose header is not this checkout's is ignored.
with tempfile.TemporaryDirectory() as reports:
    reports = pathlib.Path(reports)
    ours = '1dba8679-7997-3af0-99bc-741872b92f67'
    (reports / 'CheckmateNative-writing.ips').write_text(json.dumps({'app_name': 'CheckmateNative', 'slice_uuid': ours}) + '\n{"captureTime": "2026-10')
    (reports / 'Other-writing.ips').write_text(json.dumps({'app_name': 'CheckmateNative', 'slice_uuid': '0'}) + '\n{"capt')
    (reports / 'Junk.ips').write_text('not a report')
    every_report = gates.crash_reports(reports)
    assert gates.crashes(every_report, {ours}) == []
    assert gates.unfinished(every_report, {ours}) == {reports / 'CheckmateNative-writing.ips'}, gates.unfinished(every_report, {ours})
    saved = (gates.crash_reports, gates.built_uuids, gates.update_ledger, gates.time.sleep)
    cleared = []
    try:
        gates.crash_reports, gates.built_uuids = (lambda directory=None: every_report), (lambda root=None: set())
        gates.update_ledger, gates.time.sleep = cleared.append, (lambda seconds: None)
        written = (reports / 'CheckmateNative-writing.ips').stat().st_mtime
        with contextlib.redirect_stdout(io.StringIO()):
            assert gates.late_crashes([('intel', written - 5, written + 5)], set(), {ours}, written - 10), 'an unreadable matching report passed'
        assert cleared == [{'intel': None}], cleared
    finally:
        gates.crash_reports, gates.built_uuids, gates.update_ledger, gates.time.sleep = saved
print(f'Gate selection self-test passed ({len(cases) + 35} cases).')
