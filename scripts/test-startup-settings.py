"""Silent native acceptance for independent startup preferences and MCP standby."""
import atexit
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

import test_host
test_host.require("native Settings acceptance")

root = pathlib.Path(__file__).resolve().parents[1]
evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
state = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-startup-settings-"))
# Removed at exit, after the finally below has stopped the app (run-gates fails a gate that leaves temporary files).
atexit.register(shutil.rmtree, state, ignore_errors=True)
state_file = state / "state-v1.json"
discovery = state / "companion/connection.json"
helper = evidence / "startup-ax-helper"
subprocess.run(["xcrun", "swiftc", str(root / "Tools/ax-helper.swift"), "-o", str(helper)], check=True)
environment = dict(os.environ, CHECKMATE_AUTOMATION="1")
launcher = []
architecture = os.environ.get("CHECKMATE_EXECUTION_ARCH")
if architecture:
    if architecture not in ("arm64", "x86_64"):
        raise SystemExit("Invalid execution architecture")
    launcher = ["/usr/bin/arch", "-" + architecture]
command = launcher + [str(root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"),
                      "--automation", "--data-dir", str(state)]
process = None


def act(action, target=""):
    try:
        return subprocess.check_output([str(helper), str(process.pid), action, target], text=True)
    except subprocess.CalledProcessError:
        listing = subprocess.check_output([str(helper), str(process.pid), "list"], text=True)
        (evidence / "startup-settings-ax.txt").write_text(listing)
        raise


def wait(predicate):
    end = time.monotonic() + 10
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("Startup Settings condition timed out")


def saved():
    return json.loads(state_file.read_text())


def launch():
    global process
    process = subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait(lambda: "Chessboard" in act("list"))
    assert not discovery.exists(), "Automation automatically started MCP"


def quit_app():
    act("quit")
    process.wait(timeout=5)


def category(name):
    document = saved()
    document["window"]["settingsCategory"] = name
    state_file.write_text(json.dumps(document))
    launch()
    act("press", "Settings…")
    wait(lambda: "Settings" in act("windows"))


try:
    launch()
    quit_app()
    # Voice is opt-in for a new install; MCP's startup preference stays on (it still needs Set Up Codex).
    assert not saved()["settings"]["voiceAutoConnect"]
    assert not saved()["settings"].get("voiceConsent")
    assert saved()["settings"]["companionAutoStart"]

    category("voice")
    listing = act("list")
    assert "Connect voice coach on launch" in listing and "Not checked" in listing
    act("press", "Connect voice coach on launch")
    wait(lambda: saved()["settings"]["voiceAutoConnect"])
    assert saved()["settings"]["companionAutoStart"]
    quit_app()

    category("connections")
    assert "Accept Codex connections at launch" in act("list")
    act("press", "Accept Codex connections at launch")
    wait(lambda: not saved()["settings"]["companionAutoStart"])
    assert saved()["settings"]["voiceAutoConnect"]
    # The manual switch works independently of the startup preference.
    act("press", "Allow Codex connections")
    wait(discovery.exists)
    assert discovery.stat().st_mode & 0o777 == 0o600
    assert not saved()["settings"]["companionAutoStart"]
    act("press", "Allow Codex connections")
    wait(lambda: not discovery.exists())
    # Saves land 250 ms after a change: let any the switch made arrive before checking it left the preference alone.
    time.sleep(0.6)
    assert not saved()["settings"]["companionAutoStart"]
    quit_app()

    launch()
    # The choice is kept, and still connects nothing until the learner agrees on a first Connect.
    assert saved()["settings"]["voiceAutoConnect"]
    assert not saved()["settings"].get("voiceConsent")
    assert not saved()["settings"]["companionAutoStart"]
    quit_app()
    result = {"passed": True, "independentToggles": True, "persistedOptOuts": True, "voiceOptIn": True,
              "manualMCP": True, "privateDiscovery": True, "silentStartup": True}
    (evidence / "startup-settings-results.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
finally:
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
