"""Silent test-host acceptance: a click on a legal practice square must play, with real pointer events.

Covers the ways a second click used to be lost: drift across a square edge, a first click on an inactive
window, a click while piece inspection is on, and clicks under the storage error banner.
"""
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import tempfile
import time

import test_host
test_host.require("native pointer acceptance")
root = pathlib.Path(__file__).resolve().parents[1]
evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
state = None
helpers = {}
for name in ("pointer-helper", "ax-helper", "board-click-helper"):
    helpers[name] = evidence / name
    subprocess.run(["xcrun", "swiftc", str(root / "Tools" / (name + ".swift")), "-o", str(helpers[name])], check=True)
command = [str(root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"), "--automation"]
environment = {key: value for key, value in os.environ.items() if key != "CHECKMATE_AUTOMATION"}
process = None
results = {}


def run(helper, *arguments):
    return subprocess.check_output([str(helpers[helper]), str(process.pid), *arguments], text=True).strip()


def pointer(*arguments):
    return run("pointer-helper", *arguments)


def board(*arguments):
    return run("board-click-helper", *arguments)


def listing():
    return run("ax-helper", "list")


def wait(predicate, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(message)


def label(square):
    return pointer("label", square)


def frame(*arguments):
    x, y, w, h = (int(v) for v in board(*arguments).split())
    return x, y, w, h


def replied(white_move):
    return lambda: re.search(r"(^|\s)" + re.escape(white_move) + r"  \S+", listing()) is not None


def toggle(name):
    """A toggle's value, or None when the drawer no longer shows it."""
    try:
        return pointer("value", name)
    except subprocess.CalledProcessError:
        return None


def select(square):
    pointer("click-square", square)
    wait(lambda: "selected" in label(square), "Clicking " + square + " did not select it")


def launch():
    global process, state
    state = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-board-clicks-state-"))
    process = subprocess.Popen(command + ["--data-dir", str(state)], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait(lambda: "Chessboard" in listing(), "Board did not appear")
    time.sleep(1)  # Allow initial AppKit window and drawer restoration to finish.
    # A process launched from a shell may start inactive, and an inactive window's toolbar takes a first click
    # only to activate; activate it first with a click in the board's empty margin.
    for _ in range(3):
        board("activate")
        try:
            wait(lambda: board("active") == "true", "Checkmate did not become active", timeout=5)
            break
        except AssertionError:
            continue
    else:
        raise AssertionError("Checkmate did not become active")
    # Open each drawer explicitly and wait for it, so a toggle never lands mid-animation or closes a restored drawer.
    if "AXStaticText: The Pawn" not in listing():
        pointer("click", "Toggle Sidebar")
    wait(lambda: "AXStaticText: The Pawn" in listing(), "Lesson sidebar did not open")
    if "practice-heading" not in listing():
        pointer("click", "Toggle Game Details")
    wait(lambda: "practice-heading" in listing(), "Game details did not open")


def drift_across_edge():
    """The second click drifts past the destination's edge before release: it still plays that destination."""
    select("e2")
    width = frame("square-frame", "e4")[2]
    pointer("drift-square", "e4", str(int(width * 0.75)))  # from the centre, three quarters of a square ends in the next file
    wait(lambda: label("e4").startswith("e4, White, pawn"), "A destination click that drifted across the square edge did not play e2-e4")
    wait(replied("1. e4"), "Stockfish did not reply after the drifted click")


def first_click_on_inactive_window():
    """The second click lands while another app is active: the click that activates the window also plays."""
    select("d2")
    holder = subprocess.Popen([str(helpers["board-click-helper"]), str(process.pid), "hold-focus", "8"])
    try:
        wait(lambda: board("active") == "false", "Checkmate did not become inactive")
        board("click-in", "d4", "0.5")  # pointer-helper would activate Checkmate first; this click must do it
        wait(lambda: label("d4").startswith("d4, White, pawn"), "The first click on an inactive window did not play d2-d4")
    finally:
        holder.terminate()
        holder.wait(timeout=5)
    wait(replied("1. d4"), "Stockfish did not reply after the first-click move")


def inspection_does_not_block_moves():
    """Piece inspection is on (as after pressing P): a playable destination leaves inspection and plays."""
    select("g1")
    pointer("click", "Protected by")
    wait(lambda: pointer("value", "Protected by") == "1", "Protected by did not turn on")
    pointer("click-square", "f3")
    wait(lambda: label("f3").startswith("f3, White, knight"), "A legal destination clicked during inspection did not play g1-f3")
    # Playing clears the selection, so the inspection toggle is off or no longer shown at all.
    wait(lambda: toggle("Protected by") in ("0", None), "Playing a move did not leave piece inspection")
    wait(replied("1. Nf3"), "Stockfish did not reply after the move from inspection")


def rank8_clickable_under_banner():
    """A failed save shows the storage error banner at the top of the board area; the board must yield to it, so
    rank-8 squares are never covered and take clicks right up to their top edge."""
    os.chmod(state, stat.S_IRUSR | stat.S_IXUSR)
    select("b1")
    pointer("click-square", "c3")
    wait(lambda: label("c3").startswith("c3, White, knight"), "b1-c3 did not play")
    wait(lambda: "storage-error-banner" in listing(), "A failed save did not show the storage error banner")
    # The reply keeps a selection only on a White piece (GameSession.commitBlack), so clicking the black queen first
    # would race it.
    wait(replied("1. Nc3"), "Stockfish did not reply after b1-c3")
    banner, rank8 = frame("frame", "storage-error-banner"), frame("square-frame", "d8")
    results["bannerFrame"], results["rank8Frame"] = banner, rank8
    results["bannerOverlapPoints"] = max(0, banner[1] + banner[3] - rank8[1])
    subprocess.run(["screencapture", "-x", str(evidence / "board-clicks-banner.png")], check=True)
    assert results["bannerOverlapPoints"] == 0, "The storage error banner covers the eighth rank by %d points" % results["bannerOverlapPoints"]
    board("click-in", "d8", "0.1")
    wait(lambda: "selected" in label("d8"), "A click near the top of d8 under the error banner did not reach the board")


scenarios = [drift_across_edge, first_click_on_inactive_window, inspection_does_not_block_moves, rank8_clickable_under_banner]
# A filtered run is for debugging one scenario: an unknown name fails, and the result is marked incomplete so the
# acceptance gate (gate_check: any false flag fails) can never take a partial run for a pass.
selected_names = [name for name in os.environ.get("CHECKMATE_BOARD_CLICK_SCENARIOS", "").split(",") if name]
unknown = sorted(set(selected_names) - {scenario.__name__ for scenario in scenarios})
if unknown:
    raise SystemExit("Unknown board click scenarios: " + ", ".join(unknown))
results["complete"] = not selected_names
failures = []
for scenario in scenarios:
    if selected_names and scenario.__name__ not in selected_names:
        continue
    try:
        launch()
        scenario()
        results[scenario.__name__] = "passed"
    except Exception as error:
        results[scenario.__name__] = "failed: " + str(error)
        failures.append(scenario.__name__)
        # Diagnostics are best effort: their own failure is noted, never allowed to hide the scenario's or stop the rest.
        if process is not None and process.poll() is None:
            try:
                (evidence / ("board-clicks-" + scenario.__name__ + "-ax.txt")).write_text(listing())
                subprocess.run(["screencapture", "-x", str(evidence / ("board-clicks-" + scenario.__name__ + ".png"))], check=False)
            except Exception as diagnostic:
                results[scenario.__name__] += f" (diagnostics failed: {diagnostic})"
    finally:
        os.chmod(state, stat.S_IRWXU)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        # Each scenario's state goes once its app has stopped (run-gates fails a gate that leaves temporary files).
        shutil.rmtree(state, ignore_errors=True)
results["passed"] = not failures
(evidence / "board-click-results.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
if failures:
    raise SystemExit("Board click scenarios failed: " + ", ".join(failures))
