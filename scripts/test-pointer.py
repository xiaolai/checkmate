"""Silent build-host acceptance for real pointer input: board clicks, drags and drawer controls.

Accessibility presses bypass hit-testing, so every action here is a posted mouse event.
"""
import json
import os
import re
import pathlib
import socket
import subprocess
import tempfile
import time

if not any(name in socket.gethostname().lower() for name in ("build-host", "build-host")):
    raise SystemExit("Run native pointer acceptance on build-host only.")
root = pathlib.Path(__file__).resolve().parents[1]
evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
state = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-pointer-state-"))
helper = evidence / "pointer-helper"
lister = evidence / "pointer-ax-helper"
subprocess.run(["xcrun", "swiftc", str(root / "Tools/pointer-helper.swift"), "-o", str(helper)], check=True)
subprocess.run(["xcrun", "swiftc", str(root / "Tools/ax-helper.swift"), "-o", str(lister)], check=True)
command = [str(root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"), "--automation", "--data-dir", str(state)]
environment = {key: value for key, value in os.environ.items() if key != "CHECKMATE_AUTOMATION"}
process = None


def pointer(action, *arguments):
    return subprocess.check_output([str(helper), str(process.pid), action, *arguments], text=True).strip()


def listing():
    return subprocess.check_output([str(lister), str(process.pid), "list"], text=True)


def wait(predicate, message):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(message)


def label(square):
    return pointer("label", square)


def replied(white_move):
    """Black's reply follows the move in the drawer's move list."""
    return lambda: re.search(r"(^|\s)" + re.escape(white_move) + r"  \S+", listing()) is not None


try:
    process = subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait(lambda: "Chessboard" in listing(), "Board did not appear")
    # Drawers opened with their toolbar buttons, as a person does, rather than restored at launch.
    pointer("click", "Toggle Sidebar")
    pointer("click", "Toggle Game Details")
    wait(lambda: "Your next move." in listing(), "Game details did not open")

    # A trackpad press that drifts within its square is still a click.
    pointer("drift-square", "f2", "12")
    wait(lambda: "selected" in label("f2"), "A click with pointer drift did not select f2")
    pointer("click-square", "f4")
    wait(lambda: label("f4").startswith("f4, White, pawn"), "Clicking a destination did not play f2-f4")
    wait(replied("1. f4"), "Stockfish did not reply after a clicked move")

    # Dragging a piece plays the move; an illegal drop returns the piece and keeps it selected.
    pointer("drag-square", "g1", "f3")
    wait(lambda: label("f3").startswith("f3, White, knight"), "Dragging g1 to f3 did not play the move")
    wait(replied("2. Nf3"), "Stockfish did not reply after a dragged move")
    pointer("drag-square", "b1", "b4")
    wait(lambda: "selected" in label("b1"), "An illegal drop did not keep the piece selected")
    # Guided hints may annotate squares; only the piece matters here.
    assert "White" not in label("b4") and label("b1").startswith("b1, White, knight"), "An illegal drop moved the piece"

    # SwiftUI controls in the game details drawer receive clicks across the drawn control.
    pointer("click-square", "e2")
    wait(lambda: "White pawn on e2" in listing(), "Selecting e2 did not update the drawer")
    pointer("click", "Protected by")
    wait(lambda: pointer("value", "Protected by") == "1", "Protected by did not respond to a click")
    pointer("click", "Protected by")
    wait(lambda: pointer("value", "Protected by") == "0", "Protected by did not turn off with a second click")
    pointer("click", "Attacked by")
    wait(lambda: pointer("value", "Attacked by") == "1", "Attacked by did not respond to a click")
    pointer("click", "Attacked by")
    wait(lambda: pointer("value", "Attacked by") == "0", "Attacked by did not turn off with a second click")
    pointer("click", "Skill")
    wait(lambda: pointer("menu-open", "Level 1") == "true", "The Skill menu did not open")
    pointer("escape")

    # Lesson drawer controls take the same path.
    pointer("click", "The Pawn")
    wait(lambda: "In this lesson" in listing(), "The lesson did not open")
    before = pointer("value", "In this lesson")
    pointer("click", "In this lesson")
    wait(lambda: pointer("value", "In this lesson") != before, "The lesson disclosure did not respond to a click")

    # About opens from the app menu as a Settings pane, and its links receive clicks.
    # Automation records each open request instead of launching a browser or Finder.
    opened = state / "opened-urls.txt"
    requested = lambda text: opened.exists() and text in opened.read_text()
    pointer("menu", "Checkmate", "About Checkmate")
    wait(lambda: "Copyright © 2026" in listing(), "About Checkmate did not open the About pane")
    pointer("click", "License")
    wait(lambda: requested("Checkmate-COPYING.txt"), "The License link did not respond to a click")
    pointer("click", "Show in Finder")
    wait(lambda: requested(state.resolve().as_uri()) or requested(state.as_uri()), "Show in Finder did not respond to a click")
    pointer("click", "Sound")
    wait(lambda: "Piece and move sounds" in listing(), "The Sound settings row did not respond to a click")
    pointer("click", "About")
    wait(lambda: "Copyright © 2026" in listing(), "The About settings row did not respond to a click")

    result = {"passed": True, "clickWithDrift": True, "clickedMove": True, "draggedMove": True, "illegalDropSnapsBack": True,
              "drawerToggles": True, "drawerMenu": True, "lessonDisclosure": True, "aboutPane": True, "silent": True}
    (evidence / "pointer-results.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
except Exception:
    if process is not None and process.poll() is None:
        (evidence / "pointer-failure-ax.txt").write_text(listing())
        subprocess.run(["screencapture", "-x", str(evidence / "pointer-failure.png")], check=False)
    raise
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
