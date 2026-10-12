#!/bin/bash
# With no arguments: every gate, then the release aggregate (acceptance.json), which certifies this tree.
# With arguments: a targeted run, e.g. --changed, --only pointer,unit, --list (see scripts/run-gates.py).
set -euo pipefail
# Every Python check here is written with assert: an inherited PYTHONOPTIMIZE would silently skip them all.
unset PYTHONOPTIMIZE
cd "$(dirname "$0")/.."
[[ " $* " == *" --list "* || " $* " == *" --check-map "* ]] || python3 "$(dirname "$0")/test_host.py" acceptance || exit 1
if [[ $# -eq 0 ]]; then exec python3 scripts/run-gates.py --full; fi
exec python3 scripts/run-gates.py "$@"
