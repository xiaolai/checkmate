"""Run a SwiftPM build so that every build input whose content changed since the last successful build is rebuilt.

Usage: python3 scripts/fresh-sources.py <scratch folder> -- swift build ...

Code reaches the test hosts by rsync -a, which keeps each file's modification time, in whole seconds. SwiftPM builds
incrementally by time, so a file synced in with new content but the time of the version last built (another branch, an
older commit) is skipped, and the build passes or crashes for reasons the source does not hold. This helper keeps, inside the scratch folder, the SHA-256
of every build input as of the last successful build there. Before the build it sets the time of every input whose
content differs from that record, or is new, to now; unchanged inputs keep their time, so builds stay incremental.
After the command succeeds it records the hashes it checked. A scratch folder that exists without a record cannot be
trusted, so every input is touched once; a missing scratch folder starts from nothing and needs no touch.
The command's exit status is this helper's exit status.
"""
import importlib.util
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Loaded by path, not by name: the helper also runs with python3 -I, which keeps its own folder off sys.path.
_spec = importlib.util.spec_from_file_location('source_hashes', pathlib.Path(__file__).resolve().with_name('source-hashes.py'))
source_hashes = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(source_hashes)
MANIFEST = 'checkmate-source-hashes.json'
# What Package.swift compiles or bundles: its targets live under Sources, Tests and Tools, and it reads Version.env.
FILES = ['Package.swift', 'Package.resolved', 'Version.env']
FOLDERS = ['Sources', 'Tests', 'Tools']


def build_inputs() -> dict:
    return source_hashes.hash_tree(ROOT, [name for name in FILES if (ROOT / name).is_file()], FOLDERS)


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != '--':
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    scratch, command = pathlib.Path(sys.argv[1]).resolve(), sys.argv[3:]
    manifest = scratch / MANIFEST
    current = build_inputs()
    if manifest.is_file():
        built = json.loads(manifest.read_text())
    elif scratch.exists():
        built = {}
    else:
        built = None
    changed = [] if built is None else [path for path, digest in current.items() if built.get(path) != digest]
    for path in changed:
        os.utime(ROOT / path)
    if changed:
        print(f'fresh-sources: {len(changed)} build input(s) changed since the last build in {scratch.name}; marked for rebuild', file=sys.stderr)
    status = subprocess.run(command).returncode
    if status == 0:
        scratch.mkdir(parents=True, exist_ok=True)
        pending = manifest.with_name(f'{MANIFEST}.{os.getpid()}')
        pending.write_text(json.dumps(current, indent=1, sort_keys=True))
        os.replace(pending, manifest)
    return status


if __name__ == '__main__':
    sys.exit(main())
