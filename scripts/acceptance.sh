#!/bin/bash
# With no arguments: every gate, then the release aggregate (acceptance.json), which certifies this tree.
# With arguments: a targeted run, e.g. --changed, --only pointer,unit, --list (see scripts/run-gates.py).
set -euo pipefail
# Every Python check here is written with assert: an inherited PYTHONOPTIMIZE would silently skip them all.
unset PYTHONOPTIMIZE
cd "$(dirname "$0")/.."
case $(hostname) in *build-host*|*build-host*|build-host*) ;; *) [[ " $* " == *" --list "* || " $* " == *" --check-map "* ]] || { echo 'Run acceptance on build-host only.' >&2; exit 1; };; esac
if [[ $# -eq 0 ]]; then exec python3 scripts/run-gates.py --full; fi
exec python3 scripts/run-gates.py "$@"
