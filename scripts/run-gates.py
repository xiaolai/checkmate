"""Targeted acceptance: run only the gates a change touches, and remember which gates passed on which inputs.

  run-gates.py --changed            run every gate whose input files changed since it last passed (or never passed)
  run-gates.py --only pointer,unit  run the named gates
  run-gates.py --list               print each gate, whether it is current, and why (what --changed would run); runs nothing
  run-gates.py --check-map          fail if a tracked file belongs to no gate and is not listed as untested,
                                    or a gate pattern matches no file
  run-gates.py --full               every gate, then the release aggregate (what scripts/acceptance.sh runs)
  run-gates.py --record EVIDENCE    record every gate of a passing full run (--full does this itself)

A targeted run stops at the first failing gate and never writes acceptance.json: only scripts/acceptance.sh with no
arguments certifies a tree for release.

A gate may list "prerequisites" (LAN-play plan D14; "requires" already names the result keys gate_check.py expects): evidence a person prepares once per host, such as
bonjour-ready (scripts/prepare-bonjour.sh) or a reachable LAN pair. They are checked before anything is built. With
--changed a stale gate whose prerequisites are missing is reported as UNVERIFIED and the run exits 3, never skipped
quietly; with --only the run stops at once; a full run treats every prerequisite as required and refuses to certify. The ledger is per checkout, outside it, at
$CHECKMATE_GATE_LEDGER (default ~/Library/Caches/checkmate-gates/<checkout hash>.json).
"""
import argparse
import datetime
import fcntl
import fnmatch
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

import test_host

# First, before anything that can fail (even loading the gate map): a full run's reused evidence directory must not keep
# an earlier run's certificate, since only this run's aggregate may write one. Without the variable a run uses a fresh
# temporary directory.
if '--full' in sys.argv[1:] and os.environ.get('CHECKMATE_EVIDENCE_DIR'):
    (pathlib.Path(os.environ['CHECKMATE_EVIDENCE_DIR']) / 'acceptance.json').unlink(missing_ok=True)

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The result checks run from exactly the text that fingerprints them: an edit to gate_check.py after this process
# loaded it can never be recorded as the definition a pass was checked under.
GATE_CHECK_SOURCE = (ROOT / 'scripts/gate_check.py').read_text()
_checks = {'__name__': 'gate_check'}
exec(compile(GATE_CHECK_SOURCE, str(ROOT / 'scripts/gate_check.py'), 'exec'), _checks)
check_gate = _checks['check_gate']
MAP = json.loads((ROOT / 'scripts/gates.json').read_text())
GATES = {gate['name']: gate for gate in MAP['gates']}
ORDER = [gate['name'] for gate in MAP['gates']]


AUTOMATION_BUNDLE = 'ai.xiaolai.checkmate.native-automation'
UNVERIFIED = 3


def _identity_fingerprint() -> str:
    completed = subprocess.run(['bash', str(ROOT / 'scripts/automation-identity.sh'), 'fingerprint'], capture_output=True, text=True)
    return completed.stdout.strip() if completed.returncode == 0 else ''


def _evidence_problem(evidence: dict, fingerprint: str, account: str, build: str, where: str):
    """Why a bonjour-ready record no longer holds, or None: it names the identity, app, account and system it was made for."""
    if not isinstance(evidence, dict):
        return f'the bonjour-ready record on {where} is not a JSON object; run scripts/prepare-bonjour.sh there again'
    if not evidence:
        return f'no bonjour-ready evidence on {where}; run scripts/prepare-bonjour.sh there'
    for key, expected in (('fingerprint', fingerprint), ('bundleID', AUTOMATION_BUNDLE), ('account', account), ('macOSBuild', build)):
        if not expected:
            return f'cannot read the current {key} on {where}'
        if evidence.get(key) != expected:
            return f'bonjour-ready on {where} was made for another {key} ({evidence.get(key)!r}, now {expected!r}); run scripts/prepare-bonjour.sh again'
    return None


def bonjour_ready():
    """This host's evidence that the automation app, signed with the stable local identity, browsed its own Bonjour
    advertisement without the local-network denial (D14)."""
    record = pathlib.Path.home() / '.config/checkmate/bonjour-ready.json'
    try:
        evidence = json.loads(record.read_text()) if record.exists() else {}
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return f'the test host\'s bonjour-ready.json cannot be read ({error}); run scripts/prepare-bonjour.sh again'
    if not isinstance(evidence, dict):
        return 'the test host\'s bonjour-ready.json is not a JSON object; run scripts/prepare-bonjour.sh again'
    build = subprocess.run(['sw_vers', '-buildVersion'], capture_output=True, text=True).stdout.strip()
    import getpass
    return _evidence_problem(evidence, _identity_fingerprint(), getpass.getuser(), build, 'the test host')


def _pair():
    return os.environ.get('CHECKMATE_LAN_PAIR', '').strip()


def _on_pair(command: str, timeout: int = 20):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', _pair(), command], capture_output=True, text=True, timeout=timeout)


def lan_pair():
    """The LAN pair answers over SSH and passes the same access check as a test host (Accessibility, Screen Recording,
    an unlocked console)."""
    if not _pair():
        return 'no LAN pair configured: set CHECKMATE_LAN_PAIR in the test host\'s shell profile'
    try:
        if _on_pair('true').returncode != 0:
            return f'the LAN pair does not answer over SSH'
        probe = pathlib.Path(tempfile.mkdtemp(prefix='checkmate-host-access.')) / 'host-access'
        try:
            built = subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Tools/host-access.swift'), '-o', str(probe)], capture_output=True, text=True)
            if built.returncode != 0:
                return f'could not build the access check for the LAN pair: {built.stderr.strip()[:300]}'
            remote = '/tmp/checkmate-host-access'
            if subprocess.run(['scp', '-q', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', str(probe), f'{_pair()}:{remote}'], capture_output=True, timeout=120).returncode != 0:
                return 'could not copy the access check to the LAN pair'
            access = _on_pair(remote)
        finally:
            shutil.rmtree(probe.parent, ignore_errors=True)
    except subprocess.TimeoutExpired:
        return 'the LAN pair timed out over SSH'
    if access.returncode != 0:
        return f'the LAN pair fails the access check: {access.stdout.strip() or access.stderr.strip()}'
    return None


def bonjour_ready_pair():
    """The pair's own bonjour-ready evidence, for the app the test host signed and copies to it."""
    if not _pair():
        return 'no LAN pair configured: set CHECKMATE_LAN_PAIR in the test host\'s shell profile'
    try:
        found = _on_pair('cat ~/.config/checkmate/bonjour-ready.json 2>/dev/null; echo; whoami; sw_vers -buildVersion')
    except subprocess.TimeoutExpired:
        return 'the LAN pair timed out over SSH'
    lines = found.stdout.strip().split('\n')
    if found.returncode != 0 or len(lines) < 2:
        return 'the LAN pair does not answer over SSH'
    account, build, text = lines[-2].strip(), lines[-1].strip(), '\n'.join(lines[:-2]).strip()
    try:
        evidence = json.loads(text) if text else {}
    except json.JSONDecodeError:
        return 'the LAN pair\'s bonjour-ready.json is not JSON; run scripts/prepare-bonjour.sh there again'
    return _evidence_problem(evidence, _identity_fingerprint(), account, build, 'the LAN pair')


# Each check returns None when met, or why not. Tests replace these; nothing here builds, and none runs inside a gate.
PREREQUISITES = {'bonjour-ready': bonjour_ready, 'bonjour-ready-pair': bonjour_ready_pair, 'lan-pair': lan_pair}


def unmet(names: list) -> dict:
    """{gate: [(prerequisite, why)]} for the gates among `names` whose prerequisites are not met; each check runs once."""
    results, found = {}, {}
    for name in names:
        for requirement in GATES[name].get('prerequisites', []):
            if requirement not in results:
                check = PREREQUISITES.get(requirement)
                results[requirement] = check() if check else f'unknown prerequisite {requirement!r}'
            if results[requirement]:
                found.setdefault(name, []).append((requirement, results[requirement]))
    return found


def report_unverified(blocked: dict) -> None:
    for name, problems in blocked.items():
        print(f"UNVERIFIED {name}: needs {', '.join(requirement for requirement, _ in problems)}", file=sys.stderr)
        for requirement, why in problems:
            print(f'  {requirement}: {why}', file=sys.stderr)


def tree() -> dict:
    return json.loads(subprocess.check_output([sys.executable, str(ROOT / 'scripts/source-hashes.py'), str(ROOT)], text=True))


def matches(path: str, patterns: list) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def inputs(gate: dict, hashes: dict) -> dict:
    patterns = MAP['shared'] + gate['inputs']
    return {path: digest for path, digest in hashes.items() if matches(path, patterns)}


def definition(name: str, checks: str = None) -> str:
    """Fingerprint of what a pass means: the gate's entry in the map, the shared inputs and the result checks
    (gate_check.py as it is on disk now, unless the checks' source is given)."""
    material = json.dumps([GATES[name], MAP['shared']], sort_keys=True) + (checks if checks is not None else (ROOT / 'scripts/gate_check.py').read_text())
    return hashlib.sha256(material.encode()).hexdigest()


def unmapped(hashes: dict) -> list:
    every = MAP['shared'] + [pattern for gate in MAP['gates'] for pattern in gate['inputs']]
    return sorted(path for path in hashes if not matches(path, every) and not matches(path, list(MAP['untested'])))


def dead_patterns(hashes: dict) -> list:
    """Patterns that match no tracked file: a path left behind by a move, which silently stops covering the file."""
    named = [('shared', pattern) for pattern in MAP['shared']] + [('untested', pattern) for pattern in MAP['untested']]
    named += [(gate['name'], pattern) for gate in MAP['gates'] for pattern in gate['inputs']]
    return [f'{owner}: {pattern}' for owner, pattern in named if not any(fnmatch.fnmatchcase(path, pattern) for path in hashes)]


def ledger_path() -> pathlib.Path:
    explicit = os.environ.get('CHECKMATE_GATE_LEDGER')
    if explicit:
        return pathlib.Path(explicit)
    return pathlib.Path.home() / 'Library/Caches/checkmate-gates' / (hashlib.sha256(str(ROOT).encode()).hexdigest()[:16] + '.json')


def load_ledger() -> dict:
    path = ledger_path()
    return json.loads(path.read_text()) if path.exists() else {}


def update_ledger(changes: dict) -> None:
    """Applies {gate: entry, or None to forget it} under an exclusive lock, re-reading the ledger inside the lock so
    concurrent runners never overwrite each other's records; the write goes through a unique temporary file."""
    path = ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_suffix('.lock'), 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ledger = load_ledger()
        for name, entry in changes.items():
            if entry is None:
                ledger.pop(name, None)
            else:
                ledger[name] = entry
        with tempfile.NamedTemporaryFile('w', dir=path.parent, prefix=path.name + '.', suffix='.tmp', delete=False) as temporary:
            temporary.write(json.dumps(ledger, indent=1, sort_keys=True))
        os.replace(temporary.name, path)


def stale_reason(name: str, hashes: dict, ledger: dict):
    """None when the gate last passed on exactly these inputs; otherwise why it must run."""
    entry = ledger.get(name)
    if entry is None:
        return 'never passed in this checkout'
    if entry.get('definition') != definition(name):
        return 'the gate definition or its result checks changed'
    current, passed = inputs(GATES[name], hashes), entry['inputs']
    changed = sorted(path for path in current.keys() | passed.keys() if current.get(path) != passed.get(path))
    if not changed:
        return None
    return f"{len(changed)} input(s) changed: {', '.join(changed[:4])}{' …' if len(changed) > 4 else ''}"


def temporary_leftovers(scratch: pathlib.Path) -> list:
    """What a gate left in its private TMPDIR; every test cleans up after itself, so anything here is a leak."""
    return sorted(str(path.relative_to(scratch)) for path in scratch.iterdir())


CRASH_REPORTS = pathlib.Path.home() / 'Library/Logs/DiagnosticReports'
# The executables a gate launches. A gate kills its apps with SIGTERM and accepts that status, so an app that faulted
# moments earlier still ends "Terminated: 15"; only its crash report shows the fault.
CRASHABLE = {'CheckmateNative', 'CheckmateMCP', 'CheckmateAcceptance'}
# ReportCrash writes the report of a process translated by Rosetta well after the crash (22 s seen), so the run waits
# this long after its last gate before the final check.
CRASH_SETTLE_SECONDS = 45


def crash_reports(directory: pathlib.Path = None) -> set:
    directory = directory or CRASH_REPORTS
    return set(directory.glob('*.ips')) if directory.is_dir() else set()


def built_uuids(root: pathlib.Path = ROOT) -> set:
    """The LC_UUID of every slice of every executable this checkout built, so another checkout's crash is not blamed here."""
    paths = [path for top in ['build', *(p.name for p in root.glob('.build*'))] for path in (root / top).rglob('*')
             if path.name in CRASHABLE and path.is_file() and not path.is_symlink()]
    uuids = set()
    for path in paths:
        listed = subprocess.run(['dwarfdump', '--uuid', str(path)], capture_output=True, text=True, check=True).stdout
        uuids.update(line.split()[1].lower() for line in listed.splitlines() if line.startswith('UUID: '))
    return uuids


def crashes(reports: set, uuids: set) -> list:
    """(capture time, report) for each crash report of an executable with one of these UUIDs."""
    found = []
    for report in sorted(reports):
        header, _, body = report.read_text(errors='replace').partition('\n')
        try:
            meta, detail = json.loads(header), json.loads(body)
        except json.JSONDecodeError:
            continue  # Not a crash report this check understands; anything ReportCrash writes for a crash parses.
        if meta.get('app_name') in CRASHABLE and str(meta.get('slice_uuid', '')).lower() in uuids:
            captured = datetime.datetime.strptime(detail['captureTime'], '%Y-%m-%d %H:%M:%S.%f %z').timestamp()
            found.append((captured, report))
    return found


def attribute(windows: list, found: list) -> dict:
    """Each crash goes to the last gate that had started when it happened: the gate whose apps were running."""
    blamed = {}
    for captured, report in found:
        started = [name for name, began, _ in windows if began <= captured]
        blamed.setdefault(started[-1] if started else windows[0][0], []).append(report.name)
    return blamed


def run(names: list, full: bool = False) -> int:
    test_host.require("acceptance gates")
    evidence = pathlib.Path(os.environ.get('CHECKMATE_EVIDENCE_DIR') or tempfile.mkdtemp(prefix='checkmate-gates.', dir='/tmp'))
    evidence.mkdir(parents=True, exist_ok=True)
    environment = {**os.environ, 'CHECKMATE_EVIDENCE_DIR': str(evidence)}
    # Inputs and gate definitions are fixed before anything is built: a source, gate command or check edited during the
    # build or any gate fails the gate, so a pass never certifies sources or checks newer than what actually ran.
    # The definitions fingerprint the checks this process loaded; each gate's end compares them with the disk.
    start, definitions = tree(), {name: definition(name, GATE_CHECK_SOURCE) for name in ORDER}
    if full:
        # Record the tree before anything is built; the aggregate rejects a run whose sources changed underneath it.
        (evidence / 'source-hashes-start.json').write_text(json.dumps(start, indent=1, sort_keys=True))
        # What each pass means is fixed with the run: --record trusts these, never the definitions current at record time.
        (evidence / 'gate-definitions.json').write_text(json.dumps(definitions, indent=1, sort_keys=True))
        print(f'Full acceptance run; evidence {evidence}', flush=True)
    else:
        print(f"Targeted run of {', '.join(names)}; evidence {evidence}. Not release evidence: run scripts/acceptance.sh for that.", flush=True)
    # Gates marked prebuilt launch build/CheckmateAutomation.app, which in a full run an earlier gate builds. Build it
    # first unless a selected gate that builds it ('builds') runs before the first gate that needs it.
    first_needing = next((i for i, name in enumerate(names) if GATES[name].get('prebuilt')), None)
    if first_needing is not None and not any(GATES[name].get('builds') for name in names[:first_needing]):
        print('Building CheckmateAutomation.app', flush=True)
        with open(evidence / 'build.log', 'w') as log:
            subprocess.run(['bash', 'build.sh'], cwd=ROOT, check=True, stdout=log, stderr=subprocess.STDOUT,
                           env={**environment, 'CHECKMATE_BUNDLE_ID': 'ai.xiaolai.checkmate.native-automation', 'CHECKMATE_APP_NAME': 'CheckmateAutomation'})
    # A crash report from this checkout's apps fails the gate it came from, however the gate itself exited.
    seen_reports, uuids, windows = crash_reports(), set(), []
    for name in names:
        gate = GATES[name]
        before = inputs(gate, start)
        (evidence / gate['result']).unlink(missing_ok=True)
        started, began = time.monotonic(), time.time()
        print(f'== {name}', flush=True)
        # Each gate gets its own TMPDIR: whatever it leaves there is a leak, reported instead of piling up in /tmp.
        scratch = pathlib.Path(tempfile.mkdtemp(prefix=f'checkmate-gate-{name}.'))
        completed = subprocess.run(['bash', '-c', 'set -euo pipefail; ' + gate['run']], cwd=ROOT, env={**environment, 'TMPDIR': str(scratch) + '/'})
        seconds = time.monotonic() - started
        windows.append((name, began, time.time()))
        leftovers = temporary_leftovers(scratch)
        shutil.rmtree(scratch, ignore_errors=True)
        uuids |= built_uuids()
        fresh = crash_reports() - seen_reports
        blamed, seen_reports = attribute(windows, crashes(fresh, uuids)), seen_reports | fresh
        try:
            assert completed.returncode == 0, f'exit {completed.returncode}'
            assert not blamed, 'an app crashed: ' + '; '.join(f"during {source}: {', '.join(reports)}" for source, reports in blamed.items())
            assert not leftovers, f'left temporary files: {leftovers[:10]}'
            check_gate(evidence, gate)
            after = inputs(gate, tree())
            assert after == before, f"inputs changed since the run started: {sorted(k for k in after.keys() | before.keys() if after.get(k) != before.get(k))[:10]}"
            assert definition(name) == definitions[name], 'the gate definition or its result checks changed since the run started'
        except (AssertionError, FileNotFoundError, json.JSONDecodeError) as failure:
            update_ledger({name: None, **{source: None for source in blamed}})
            print(f'FAILED {name} after {seconds:.0f}s: {failure}', flush=True)
            return 1
        update_ledger({name: {'inputs': before, 'definition': definitions[name], 'passedAt': time.time(), 'evidence': str(evidence), 'full': False}})
        print(f'PASSED {name} in {seconds:.0f}s', flush=True)
    time.sleep(max(0.0, windows[-1][2] + CRASH_SETTLE_SECONDS - time.time()) if windows else 0.0)
    late = attribute(windows, crashes(crash_reports() - seen_reports, uuids | built_uuids()))
    if late:
        update_ledger({name: None for name in late})
        for name, reports in late.items():
            print(f"FAILED {name}: an app crashed and its report arrived after the gate passed: {', '.join(reports)}", flush=True)
        return 1
    if full:
        subprocess.run([sys.executable, str(ROOT / 'scripts/aggregate-evidence.py'), str(evidence)], cwd=ROOT, check=True)
        return record(evidence)
    print(f"All {len(names)} selected gate(s) passed.")
    return 0


def record(evidence: pathlib.Path) -> int:
    """Records a passing full run: its acceptance.json certifies the tree it started with."""
    certified = json.loads((evidence / 'acceptance.json').read_text())['sourceHashes']
    definitions_file = evidence / 'gate-definitions.json'
    if not definitions_file.exists():
        sys.exit(f'{evidence} does not record the gate definitions it ran under; run the full suite again to record it.')
    definitions = json.loads(definitions_file.read_text())
    changes = {}
    for name in ORDER:
        check_gate(evidence, GATES[name])
        # A gate whose definition has changed since the run is recorded as passed under its old one, so it stays stale.
        changes[name] = {'inputs': inputs(GATES[name], certified), 'definition': definitions.get(name, 'not recorded'), 'passedAt': time.time(), 'evidence': str(evidence), 'full': True}
    update_ledger(changes)
    print(f'Recorded {len(ORDER)} gates from {evidence} in {ledger_path()}')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--full', action='store_true')
    mode.add_argument('--changed', action='store_true')
    mode.add_argument('--only')
    mode.add_argument('--check-map', action='store_true')
    mode.add_argument('--record', type=pathlib.Path)
    mode.add_argument('--list', action='store_true')
    arguments = parser.parse_args()
    if arguments.record:
        return record(arguments.record)
    # Running gates, and the prerequisite checks before them (which compile a probe and reach the LAN pair), happen on
    # the test host only, however this file is started; listing and the map check are read-only.
    if not (arguments.list or arguments.check_map):
        test_host.require('acceptance')
    hashes = tree()
    missing = unmapped(hashes)
    if missing:
        print('Files that belong to no gate (add them to a gate in scripts/gates.json, or to "untested" with a reason):', file=sys.stderr)
        print('\n'.join('  ' + path for path in missing), file=sys.stderr)
        return 2
    dead = dead_patterns(hashes)
    if dead:
        print('Patterns in scripts/gates.json that match no file (moved or deleted; point them at the current path):', file=sys.stderr)
        print('\n'.join('  ' + entry for entry in dead), file=sys.stderr)
        return 2
    if arguments.full:
        # A release cannot certify a tree whose prerequisite-bound gates (the LAN gate) could not run.
        blocked = unmet(ORDER)
        if blocked:
            report_unverified(blocked)
            print('Full run refused: prerequisites are missing, so this tree cannot be certified. Nothing was built.', file=sys.stderr)
            return UNVERIFIED
        return run(ORDER, full=True)
    if arguments.check_map:
        print(f'Every one of {len(hashes)} tracked files belongs to a gate or is listed as untested, and every pattern matches a file.')
        return 0
    ledger = load_ledger()
    if arguments.list:
        stale = [name for name in ORDER if stale_reason(name, hashes, ledger) is not None]
        # Listing is read-only and runs on any Mac; the prerequisite checks compile a probe and reach the LAN pair, so
        # they run only where the gates themselves may.
        blocked = unmet(stale) if 'test' in test_host.host_roles() else {}
        if 'test' not in test_host.host_roles():
            print('(not the test host: prerequisites are not checked here)')
        for name in ORDER:
            reason = stale_reason(name, hashes, ledger)
            status = 'current' if reason is None else (f"UNVERIFIED: needs {', '.join(r for r, _ in blocked[name])}; " if name in blocked else 'RUN: ') + reason
            print(f"{name:17} {status}")
        return 0
    if arguments.only:
        names = [name.strip() for name in arguments.only.split(',') if name.strip()]
        unknown = [name for name in names if name not in GATES]
        if unknown or not names:
            print(f"Unknown gate(s) {unknown}; gates are: {', '.join(ORDER)}", file=sys.stderr)
            return 2
        names = [name for name in ORDER if name in names]
        blocked = unmet(names)
        if blocked:
            report_unverified(blocked)
            return UNVERIFIED
        return run(names)
    else:
        names = [name for name in ORDER if stale_reason(name, hashes, ledger) is not None]
        for name in names:
            print(f'{name}: {stale_reason(name, hashes, ledger)}')
        if not names:
            print('Every gate already passed on the current inputs; nothing to run.')
            return 0
        # A stale gate that cannot run is never skipped quietly: it is reported, the rest run, and the run fails.
        blocked = unmet(names)
        report_unverified(blocked)
        runnable = [name for name in names if name not in blocked]
        status = run(runnable) if runnable else 0
        if blocked:
            print(f"{len(blocked)} stale gate(s) UNVERIFIED: {', '.join(blocked)}", file=sys.stderr)
            return status or UNVERIFIED
        return status


if __name__ == '__main__':
    sys.exit(main())
