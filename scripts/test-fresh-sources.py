"""Self-test of scripts/fresh-sources.py; pure file checks in a temporary fixture, launches no build, runs on any Mac.

A sync (rsync -a) keeps each file's modification time, so a file can arrive with new content and an old time, even the
time of the version last built. The
helper must touch such a file before the build, so SwiftPM's time-based incremental build recompiles it, and must
leave every unchanged file alone, so builds stay incremental.
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
PAST = 978307200  # 2001-01-01, older than any build


def run(fixture: pathlib.Path, scratch: str, *command: str) -> int:
    return subprocess.run([sys.executable, '-I', str(fixture / 'scripts/fresh-sources.py'), scratch, '--', *command],
                          cwd=fixture, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def mtime(path: pathlib.Path) -> int:
    return path.stat().st_mtime_ns


with tempfile.TemporaryDirectory() as folder:
    fixture = pathlib.Path(folder)
    (fixture / 'scripts').mkdir()
    shutil.copy(root / 'scripts/fresh-sources.py', fixture / 'scripts/fresh-sources.py')
    files = {'Package.swift': 'let a = 1\n', 'Package.resolved': '{}\n', 'Version.env': 'V=1\n', 'Sources/A/a.swift': 'let x = 1\n',
             'Sources/A/b.swift': 'let y = 1\n', 'Tests/ATests/t.swift': 'let t = 1\n', 'Tools/Acceptance/main.swift': 'let m = 1\n',
             'scripts/other.sh': 'true\n'}
    for name, text in files.items():
        (fixture / name).parent.mkdir(parents=True, exist_ok=True)
        (fixture / name).write_text(text)
        os.utime(fixture / name, (PAST, PAST))
    scratch = fixture / '.build'
    manifest = scratch / 'checkmate-source-hashes.json'

    # No scratch folder yet: the build starts from nothing, so nothing is touched; the manifest records what was built.
    assert run(fixture, '.build', 'true') == 0
    assert all(mtime(fixture / name) == PAST * 10**9 for name in files), 'a first build must not touch any file'
    recorded = json.loads(manifest.read_text())
    assert set(recorded) == set(files) - {'scripts/other.sh'}, f'unexpected build inputs: {sorted(recorded)}'

    # A sync replaces b.swift with different content and an OLD time; the build must see it as newer than the last one.
    os.utime(manifest, (PAST + 10, PAST + 10))
    built = mtime(manifest)
    (fixture / 'Sources/A/b.swift').write_text('let y = 2\n')
    os.utime(fixture / 'Sources/A/b.swift', (PAST, PAST))
    (fixture / 'Tests/ATests/new.swift').write_text('let n = 1\n')
    os.utime(fixture / 'Tests/ATests/new.swift', (PAST, PAST))
    # The build command itself checks the time, so the touch is proven to happen before the build, not after.
    check = 'import os,sys; sys.exit(0 if min(os.stat(p).st_mtime_ns for p in sys.argv[2:]) > int(sys.argv[1]) else 7)'
    assert run(fixture, '.build', sys.executable, '-c', check, str(built), 'Sources/A/b.swift', 'Tests/ATests/new.swift') == 0, \
        'a changed or new file with an old time must be touched before the build'
    for name in files:
        if name != 'Sources/A/b.swift':
            assert mtime(fixture / name) == PAST * 10**9, f'{name} is unchanged and must keep its time'
    assert json.loads(manifest.read_text())['Sources/A/b.swift'] == hashlib.sha256(b'let y = 2\n').hexdigest(), 'the manifest records what was built'

    # A failed build keeps the old manifest and passes on its exit status; the next build touches the file again.
    (fixture / 'Sources/A/a.swift').write_text('let x = 2\n')
    os.utime(fixture / 'Sources/A/a.swift', (PAST, PAST))
    before = manifest.read_text()
    assert run(fixture, '.build', sys.executable, '-c', 'raise SystemExit(5)') == 5, 'the build status must pass through'
    assert manifest.read_text() == before, 'a failed build must not record its inputs as built'
    os.utime(fixture / 'Sources/A/a.swift', (PAST, PAST))
    assert run(fixture, '.build', sys.executable, '-c', check, str(built), 'Sources/A/a.swift') == 0, \
        'a file changed since the last successful build must be touched again after a failed one'

    # A scratch folder without a manifest (built before this helper, or by hand) cannot be trusted: every input is touched.
    other = fixture / '.build-intel'
    other.mkdir()
    for name in files:
        os.utime(fixture / name, (PAST, PAST))
    assert run(fixture, '.build-intel', 'true') == 0
    assert all(mtime(fixture / name) > PAST * 10**9 for name in recorded), 'an unrecorded scratch folder must touch every input'
    assert mtime(fixture / 'scripts/other.sh') == PAST * 10**9, 'a file that is no build input must keep its time'

    # A deleted input needs no touch and leaves the manifest.
    (fixture / 'Sources/A/b.swift').unlink()
    assert run(fixture, '.build', 'true') == 0
    assert 'Sources/A/b.swift' not in json.loads(manifest.read_text())

    # Called wrongly, it refuses instead of building without the check.
    assert run(fixture, '.build') != 0
    assert subprocess.run([sys.executable, '-I', str(fixture / 'scripts/fresh-sources.py'), '.build', 'true'], cwd=fixture,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0

# Every build entry point that keeps a scratch folder goes through the helper: a bare swift build could skip a synced file.
for entry in ['build.sh', 'scripts/test-unit.sh', 'scripts/test-intel.sh', 'scripts/live-voice.sh', 'Tools/verify-review-corpus.py',
              'Tools/calibrate-opponents.swift']:
    assert 'fresh-sources.py' in (root / entry).read_text(), f'{entry} builds without scripts/fresh-sources.py'
print('fresh-sources: synced files with old times are rebuilt; unchanged files keep their times')
