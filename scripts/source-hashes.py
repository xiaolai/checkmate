"""Print the SHA-256 of every source input to the build and tests, as JSON keyed by path.

Acceptance records these before it builds anything and again at the end; release packaging requires a passing
acceptance run whose hashes match the tree being packaged.

  source-hashes.py [ROOT]                              print the hashes of ROOT (default .)
  source-hashes.py --compare FILE [--key KEY] [ROOT]   exit 1 listing the paths whose hash differs from those recorded in
                                                       FILE (or in its KEY, such as sourceHashes)
"""
import argparse
import hashlib
import json
import pathlib
import sys

FILES = ["Package.swift", "Package.resolved", "build.sh", "Version.env", "Release.entitlements"]
FOLDERS = ["Sources", "Tests", "scripts", "Tools", "Artwork", "companion", "Content"]


def hash_tree(root: pathlib.Path, files: list, folders: list) -> dict:
    """{path relative to root: SHA-256} of the named files and of every file under the named folders."""
    paths = [root / name for name in files]
    for folder in folders:
        paths += [f for f in (root / folder).rglob("*") if f.is_file() and "__pycache__" not in f.parts and f.name != ".DS_Store"]
    return {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(paths)}


def tree(root=".") -> dict:
    return hash_tree(pathlib.Path(root).resolve(), FILES, FOLDERS)


def changed(recorded: dict, current: dict) -> list:
    """The sorted paths whose hash differs between two records, including paths only one of them holds."""
    return sorted(k for k in recorded.keys() | current.keys() if recorded.get(k) != current.get(k))


def differs(recorded: dict, root=".") -> list:
    """The paths of the tree at root that differ from the recorded hashes."""
    return changed(recorded, tree(root))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--compare", metavar="FILE")
    parser.add_argument("--key")
    arguments = parser.parse_args()
    if arguments.compare is None:
        if arguments.key is not None:
            parser.error("--key needs --compare")
        print(json.dumps(tree(arguments.root), indent=1, sort_keys=True))
        return 0
    with open(arguments.compare) as file:
        recorded = json.load(file)
    if arguments.key is not None:
        if not isinstance(recorded, dict) or not isinstance(recorded.get(arguments.key), dict):
            print(f"{arguments.compare} records no {arguments.key}", file=sys.stderr)
            return 1
        recorded = recorded[arguments.key]
    found = differs(recorded, arguments.root)
    if found:
        print(f"{len(found)} path(s) differ from {arguments.compare}: {found[:20]}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
