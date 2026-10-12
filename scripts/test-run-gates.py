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
    (['Tools/pointer-helper.swift'], {'pointer', 'lesson-remediation', 'board-clicks', 'training-pointer', 'training-b-pointer'}),
    (['Tests/CheckmateNativeTests/BoardClickTests.swift'], {'architecture', 'unit'}),
    (['Sources/CheckmateNative/ReviewViews.swift'], {'architecture', 'ui', 'layout', 'review-ui', 'pointer', 'unit', 'package'}),
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
# Acceptance runs only on listed test hosts, matched by name: any other Mac is refused.
import test_host
assert all(test_host.is_test_host(h) for h in ['build-host', 'build-host', 'test-host'])
assert not any(test_host.is_test_host(h) for h in ['mac-mini', 'studio', 'laptop'])
# The review helper is Swift and cannot import test_host, so it repeats the list; it must not drift.
import re
helper = re.search(r'let testHosts=\[([^\]]*)\]', (root / 'Tools/ReviewScenario.swift').read_text())
assert helper and tuple(re.findall(r'"([^"]+)"', helper[1])) == test_host.TEST_HOSTS, 'Tools/ReviewScenario.swift test hosts differ from scripts/test_host.py'
print(f'Gate selection self-test passed ({len(cases) + 5} cases).')
