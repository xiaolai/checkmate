"""Silent test-host acceptance: the main window in a right-to-left language, with real pointer events.

The automation build runs with Arabic preferred and right-to-left writing forced. The window chrome mirrors: the
Sidebar drawer opens on the right and Details on the left, each outward, so the square board keeps its place and the
board-area title stays centred over it. The chessboard itself never mirrors: a1 stays at White's bottom left. A move
played by clicking two squares must play.
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import time

import test_host
test_host.require("native right-to-left acceptance")
root = pathlib.Path(__file__).resolve().parents[1]
evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
helpers = {}
for name in ("pointer-helper", "ax-helper", "board-click-helper"):
    helpers[name] = evidence / name
    subprocess.run(["xcrun", "swiftc", str(root / "Tools" / (name + ".swift")), "-o", str(helpers[name])], check=True)
# Xcode's Right-to-Left Pseudolanguage: AppleTextDirection mirrors the layout, NSForceRightToLeftWritingDirection the
# text. Arabic alone does nothing while the app has no Arabic localization.
right_to_left = ["-AppleLanguages", "(ar)", "-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"]
command = [str(root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"), "--automation"]
environment = {key: value for key, value in os.environ.items() if key != "CHECKMATE_AUTOMATION"}
state = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-rtl-state-"))
process = None
results = {"complete": False, "details": {}}


def run(helper, *arguments):
    return subprocess.check_output([str(helpers[helper]), str(process.pid), *arguments], text=True).strip()


def pointer(*arguments):
    return run("pointer-helper", *arguments)


def listing():
    return run("ax-helper", "list")


def frame(kind, name):
    """An element's screen frame (x, y from the top left, width, height), from its square name or accessible name."""
    x, y, w, h = (int(v) for v in run("board-click-helper", kind, name).split())
    return {"x": x, "y": y, "w": w, "h": h, "midX": x + w / 2, "maxX": x + w}


def wait(predicate, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(message)


def title_text():
    """The board-area title is the static text that names the activity and its players, as "Practice · …"; its
    accessibility label is "Current activity"."""
    found = re.findall(r"^AXStaticText: Current activity \| (Practice · [^|\n]+?)(?: \||$)", listing(), re.M)
    assert found, "The board-area title was not found"
    return found[0]


def check(name, condition, detail):
    results[name] = bool(condition)
    results["details"][name] = detail
    assert condition, name + ": " + json.dumps(detail)


def scenario():
    global process
    process = subprocess.Popen(command + ["--data-dir", str(state)] + right_to_left, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait(lambda: "Chessboard" in listing(), "Board did not appear")
    time.sleep(1)  # Allow initial AppKit window and drawer restoration to finish.
    for _ in range(3):
        run("board-click-helper", "activate")
        try:
            wait(lambda: run("board-click-helper", "active") == "true", "Checkmate did not become active", timeout=5)
            break
        except AssertionError:
            continue
    else:
        raise AssertionError("Checkmate did not become active")
    # Right-to-left took effect: the system mirrors the toolbar, so the Sidebar toggle stands right of Details.
    sidebar_toggle, details_toggle = frame("frame", "Sidebar"), frame("frame", "Details")
    check("toolbarMirrored", sidebar_toggle["midX"] > details_toggle["midX"], {"sidebarToggle": sidebar_toggle, "detailsToggle": details_toggle})
    closed = frame("frame", "Chessboard")
    # Open each drawer explicitly and wait for it, so a measurement never lands mid-animation.
    if "AXStaticText: The Pawn" not in listing():
        pointer("click", "Sidebar")
    wait(lambda: "AXStaticText: The Pawn" in listing(), "Lesson sidebar did not open")
    if "practice-heading" not in listing():
        pointer("click", "Details")
    wait(lambda: "practice-heading" in listing(), "Game details did not open")
    time.sleep(1)  # The drawer animation settles before the window is measured.
    board, window = frame("frame", "Chessboard"), frame("frame", "main")
    sidebar, details = frame("frame", "The Pawn"), frame("frame", "practice-heading")
    title = frame("frame", title_text())
    results["frames"] = {"boardClosed": closed, "board": board, "window": window, "sidebar": sidebar, "details": details, "title": title}
    # "Chessboard" is the board area around the grid; the eight-by-eight grid of squares is what stays square.
    a1, h1, a8 = frame("square-frame", "a1"), frame("square-frame", "h1"), frame("square-frame", "a8")
    grid = {"w": h1["maxX"] - a1["x"], "h": a1["y"] + a1["h"] - a8["y"]}
    check("boardSquare", abs(grid["w"] - grid["h"]) <= 1, grid)
    check("boardKeptItsPlace", abs(board["x"] - closed["x"]) <= 1 and abs(board["w"] - closed["w"]) <= 1, {"closed": closed, "open": board})
    check("sidebarOnTheRight", sidebar["x"] >= board["maxX"] and sidebar["maxX"] <= window["maxX"], {"sidebar": sidebar, "board": board})
    check("detailsOnTheLeft", details["maxX"] <= board["x"] and details["x"] >= window["x"], {"details": details, "board": board})
    check("titleCentred", abs(title["midX"] - board["midX"]) <= 2, {"title": title, "board": board})
    check("boardNotMirrored", a1["x"] < h1["x"] and a1["y"] > a8["y"] and a1["x"] <= board["x"] + a1["w"], {"a1": a1, "h1": h1, "a8": a8})
    subprocess.run(["screencapture", "-x", str(evidence / "rtl-window.png")], check=True)
    pointer("click-square", "e2")
    wait(lambda: "selected" in pointer("label", "e2"), "Clicking e2 did not select it")
    pointer("click-square", "e4")
    wait(lambda: pointer("label", "e4").startswith("e4, White, pawn"), "Clicking e4 after e2 did not play e2-e4")
    wait(lambda: re.search(r"^AXButton: (.* \| )?1\.\.\. \S+", listing(), re.M) is not None, "Stockfish did not reply after the clicked move")
    results["pointerMove"] = True


failure = None
try:
    scenario()
    results["complete"] = True
except Exception as error:
    failure = str(error)
    results["failure"] = failure
    # Diagnostics are best effort: their own failure is noted, never allowed to hide the scenario's.
    if process is not None and process.poll() is None:
        try:
            (evidence / "rtl-ax.txt").write_text(listing())
            subprocess.run(["screencapture", "-x", str(evidence / "rtl-failure.png")], check=False)
        except Exception as diagnostic:
            results["failure"] += f" (diagnostics failed: {diagnostic})"
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    shutil.rmtree(state, ignore_errors=True)
results["passed"] = failure is None and all(value for value in results.values() if isinstance(value, bool))
(evidence / "rtl-results.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
if not results["passed"]:
    raise SystemExit("Right-to-left acceptance failed: " + (failure or "a check failed"))
