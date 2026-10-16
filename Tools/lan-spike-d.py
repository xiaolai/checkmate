"""LAN-play spike (d): two automation instances on one host take real pointer events in turn.

The network-ui gate will drive a host and a guest window on one test host. This proves the precondition: two copies
of the automation app, each with its own data folder, accept posted clicks alternately, each keeps its own selection
while the other is clicked, and a move made in one never appears in the other.
    python3 Tools/lan-spike-d.py <evidence-dir>     (after build.sh has made build/CheckmateAutomation.app)
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "scripts"))
import test_host  # noqa: E402
test_host.require("the LAN spike")
evidence = pathlib.Path(sys.argv[1])
evidence.mkdir(parents=True, exist_ok=True)
helper = evidence / "pointer-helper"
subprocess.run(["xcrun", "swiftc", str(root / "Tools/pointer-helper.swift"), "-o", str(helper)], check=True)
binary = root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"
environment = {key: value for key, value in os.environ.items() if key != "CHECKMATE_AUTOMATION"}
instances, folders, steps = [], [], []


def pointer(pid, action, *arguments):
    return subprocess.check_output([str(helper), str(pid), action, *arguments], text=True).strip()


def wait(predicate, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(message)


def label(pid, square):
    """The square's accessibility label; empty while the window is still opening (the helper exits 2 then)."""
    result = subprocess.run([str(helper), str(pid), "label", square], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


passed, failure = False, None
try:
    for name in ("a", "b"):
        folder = pathlib.Path(tempfile.mkdtemp(prefix=f"checkmate-spike-d-{name}-"))
        folders.append(folder)
        process = subprocess.Popen([str(binary), "--automation", "--data-dir", str(folder)], env=environment,
                                   stdout=open(evidence / f"app-{name}.log", "w"), stderr=subprocess.STDOUT)
        instances.append(process)
    a, b = (process.pid for process in instances)
    for pid in (a, b):
        wait(lambda pid=pid: label(pid, "e2").startswith("e2, White, pawn"), f"Instance {pid} never showed its board", 40)
    # Interleaved: a selects e2, b selects d2, a completes e2-e4, b completes d2-d4. Each click is a posted event
    # aimed at the instance's own window; the helper brings that window forward first, as a person's click would.
    for pid, square, check in [(a, "e2", lambda: "selected" in label(a, "e2")),
                               (b, "d2", lambda: "selected" in label(b, "d2")),
                               (a, "e4", lambda: label(a, "e4").startswith("e4, White, pawn")),
                               (b, "d4", lambda: label(b, "d4").startswith("d4, White, pawn"))]:
        pointer(pid, "click-square", square)
        wait(check, f"Instance {pid} did not take the click on {square}")
        steps.append({"pid": pid, "click": square, "a_e4": label(a, "e4"), "b_d4": label(b, "d4")})
    # Neither move leaked into the other instance. Each read must succeed (an empty label is a failed read, not an
    # empty square), and each pawn the other instance moved is still at home here.
    for pid, moved, home in [(b, "e4", "e2"), (a, "d4", "d2")]:
        landing, origin = label(pid, moved), label(pid, home)
        assert landing.startswith(moved) and origin.startswith(home), f"instance {pid} could not be read: {landing!r}, {origin!r}"
        # An empty square reads as its name alone (BoardView's label lists a piece only when one stands there).
        assert landing == moved, f"the other instance's move appeared in {pid}: {landing!r}"
        assert origin.startswith(f"{home}, White, pawn"), f"instance {pid} lost its {home} pawn"
    subprocess.run(["screencapture", "-x", str(evidence / "two-instances.png")], check=True)
    passed = True
except Exception as error:  # the verdict file records the failure; the exit status reports it
    failure = repr(error)
finally:
    for process in instances:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
    for folder in folders:
        shutil.rmtree(folder, ignore_errors=True)
(evidence / "probe-d.json").write_text(json.dumps({"probe": "d", "passed": passed, "failure": failure, "steps": steps}, indent=1))
print("probe-d passed" if passed else f"probe-d FAILED: {failure}")
sys.exit(0 if passed else 1)
