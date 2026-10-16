#!/bin/bash
# Readies a test host, or the LAN pair, for the Bonjour gates (LAN-play plan D14): run once per host, never inside
# acceptance. It builds the automation app, installs a copy signed with the stable local identity (D12) at the one
# fixed path in ~/Applications and registers it with LaunchServices (spike (c): the local-network permission is kept
# per bundle ID and enforced only for registered executables), then opens it through LaunchServices with
# --bonjour-self-check: the app hosts a game over real Bonjour, finds it, and joins its seat through the real
# transport. If macOS asks for local-network access, the prompt is answered Allow with a real click. The evidence,
# ~/.config/checkmate/bonjour-ready.json, names the identity, bundle ID, account and macOS build it holds for.
#   bash scripts/prepare-bonjour.sh            this test host
#   bash scripts/prepare-bonjour.sh --pair     the LAN pair (CHECKMATE_LAN_PAIR), with the app built and signed here
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test_host.py "Bonjour preparation" || exit 1
target=host
case "${1:-}" in "") ;; --pair) target=pair ;; *) echo "Usage: prepare-bonjour.sh [--pair]" >&2; exit 2 ;; esac
CHECKMATE_BUNDLE_ID=ai.xiaolai.checkmate.native-automation CHECKMATE_APP_NAME=CheckmateAutomation bash build.sh >/dev/null
fingerprint=$(bash scripts/automation-identity.sh fingerprint)
CHECKMATE_PREPARE_TARGET="$target" CHECKMATE_IDENTITY_FINGERPRINT="$fingerprint" python3 - <<'PY'
import datetime
import getpass
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, "scripts")
import network_gate as gate

remote = os.environ["CHECKMATE_PREPARE_TARGET"] == "pair"
work = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-prepare-bonjour-"))


def shell(command, check=False):
    if remote:
        return gate.on_pair(command, check=check)
    return subprocess.run(command, shell=True, capture_output=True, text=True, check=check).stdout.strip()


def asks_for_local_network(owner):
    """Whether the dialog UserNotificationCenter shows is this app's local-network prompt, so no other prompt is ever
    answered for it."""
    text = shell(f"{tools['ax-helper']} {owner} list 2>/dev/null")
    return "Checkmate" in text and "local network" in text


def cleanly(step, *args):
    """One cleanup step; a failure or timeout in it never skips the steps after it."""
    try:
        step(*args)
    except Exception as error:  # noqa: BLE001 - cleanup reports and carries on
        print(f"cleanup step failed: {error}", file=sys.stderr)


tools = {}
data = None
prompt = "not shown"
try:
    helpers = gate.compile_helpers(work)
    gate.install(remote=remote)
    tools = {name: (f"/tmp/checkmate-prepare-{name}" if remote else str(helpers[name])) for name in ("pointer-helper", "ax-helper")}
    if remote:
        for name, path in tools.items():
            subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", str(helpers[name]), f"{gate.pair()}:{path}"], check=True, timeout=120)
    helper = tools["pointer-helper"]
    data = shell("mktemp -d /tmp/checkmate-prepare-bonjour.XXXXXX", check=True)
    verdict = f"{data}/self-check.json"
    app = "~/Applications/CheckmateAutomation.app" if remote else shlex.quote(str(gate.INSTALLED))
    shell(f"open -n -a {app} --args --automation --data-dir {shlex.quote(data)} --bonjour-self-check {shlex.quote(verdict)}", check=True)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if shell(f"test -s {shlex.quote(verdict)} && echo done") == "done":
            break
        # The macOS prompt belongs to UserNotificationCenter. Once it shows the local-network question naming this
        # app, a real click on Allow answers it, as a person would; the button is looked up only inside the window
        # that names both Checkmate and the local network, so another prompt is never answered.
        if prompt == "not shown":
            owner = shell("pgrep -x UserNotificationCenter")
            if owner and asks_for_local_network(owner):
                shell(f"{helper} {owner} dialog-click Checkmate Allow 'local network'", check=True)
                prompt = "answered Allow"
        time.sleep(0.5)
    try:
        result = json.loads(shell(f"cat {shlex.quote(verdict)} 2>/dev/null") or "{}")
    except json.JSONDecodeError as error:
        result = {"passed": False, "message": f"the self-check wrote no readable verdict ({error})"}
finally:
    # The app, its data and the helpers go whatever happened above.
    if data:
        cleanly(shell, f"pkill -f {shlex.quote('data-dir ' + data)}; rm -rf {shlex.quote(data)}")
    if remote and tools:
        cleanly(shell, "rm -f " + " ".join(shlex.quote(path) for path in tools.values()))
    cleanly(subprocess.run, ["rm", "-rf", str(work)])
if not result.get("passed"):
    raise SystemExit(f"Bonjour self-check failed on the {'LAN pair' if remote else 'test host'}: {json.dumps(result)} (prompt {prompt})")
evidence = {"fingerprint": os.environ["CHECKMATE_IDENTITY_FINGERPRINT"], "bundleID": gate.AUTOMATION_BUNDLE,
            "account": shell("whoami") if remote else getpass.getuser(), "macOSBuild": shell("sw_vers -buildVersion"),
            "date": datetime.date.today().isoformat(), "prompt": prompt, "selfCheck": result}
text = json.dumps(evidence, indent=2, sort_keys=True)
if remote:
    gate.on_pair("mkdir -p ~/.config/checkmate && cat > ~/.config/checkmate/bonjour-ready.json << 'JSON'\n" + text + "\nJSON")
else:
    record = pathlib.Path.home() / ".config/checkmate/bonjour-ready.json"
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(text + "\n")
print(text)
PY
