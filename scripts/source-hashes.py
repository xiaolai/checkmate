"""Print the SHA-256 of every source input to the build and tests, as JSON keyed by path.

Acceptance records these before it builds anything and again at the end; release packaging requires a passing
acceptance run whose hashes match the tree being packaged.
"""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
files = [root / "Package.swift", root / "Package.resolved", root / "build.sh", root / "Version.env", root / "Release.entitlements"]
for folder in ["Sources", "Tests", "scripts", "Tools", "Artwork", "companion", "Content"]:
    files += [f for f in (root / folder).rglob("*") if f.is_file() and "__pycache__" not in f.parts and f.name != ".DS_Store"]
print(json.dumps({str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(files)}, indent=1, sort_keys=True))
