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


def wait(predicate, message, timeout=15):
    deadline = time.monotonic() + timeout
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
    time.sleep(1)  # Allow initial AppKit window and drawer restoration to finish.
    # Explicitly open drawers, tolerating window restoration from previous automation runs.
    if "AXStaticText: The Pawn" not in listing():
        pointer("click", "Toggle Sidebar")
    wait(lambda: "AXStaticText: The Pawn" in listing(), "Lesson sidebar did not open at launch")
    if "Your next move." not in listing():
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

    # Window drawer restoration can survive across automation runs. Open explicitly if needed.
    if "AXStaticText: The Pawn" not in listing():
        pointer("click", "Toggle Sidebar")
    wait(lambda: "AXStaticText: The Pawn" in listing(), "Lesson sidebar did not open")
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
    pointer("click", "Voice Coach")
    wait(lambda: "Reasoning effort" in listing(), "Voice Coach reasoning settings did not appear")
    for title, effort in [("Low", "low"), ("Medium", "medium"), ("High", "high"), ("Extra high", "xhigh"), ("Minimal", "minimal")]:
        pointer("select-popup", "coach-reasoning-effort", title)
        wait(lambda: json.loads((state / "state-v1.json").read_text())["settings"]["coachReasoningEffort"] == effort, "Reasoning effort did not persist: " + effort)
    subprocess.run(["screencapture", "-x", str(evidence / "voice-reasoning-settings.png")], check=True)
    pointer("click", "Lessons")
    wait(lambda: "Recording voice" in listing(), "The Lessons settings row did not respond to a click")
    pointer("click", "Search languages")
    wait(lambda: "Translate" in listing(), "Lesson translation controls are missing")
    fixture = environment.get("CHECKMATE_LESSON_FIXTURE") == "1"
    if fixture:
        pointer("select-popup", "lesson-language", "French")
        pointer("click", "Translate")
        wait(lambda: "French lesson:" in listing(), "Fixture translation did not populate text inspection")
        wait(lambda: "Completed. Matching" in listing(), "Fixture translation did not finish")
        pointer("click", "Generate preview")
        wait(lambda: "Preview ready." in listing(), "Fixture preview generation did not finish")
        pointer("click", "Play preview")
        pointer("click", "Record / Resume")
        wait(lambda: re.search(r"Lesson 1 of 1, clip [0-9]+ of 20", listing()) is not None, "Fixture recording progress is missing")
        pointer("click", "Cancel")
        wait(lambda: "Cancelled. Completed text and clips" in listing(), "Fixture recording cancellation failed")
        subprocess.run(["screencapture", "-x", str(evidence / "lesson-settings.png")], check=True)
        wait(lambda: "Incomplete lessons use English." in listing(), "Cancelled partial recording did not report English fallback")
        pointer("click", "Record / Resume")
        wait(lambda: "Complete offline lesson: 20 verified recordings." in listing(), "Fixture resumed recording did not complete", timeout=30)
        pointer("close-window", "Settings")
        pointer("click", "French lesson: Introduction")
        wait(lambda: "French lesson:" in listing() and "In this lesson" in listing(), "Offline translated lesson did not open")
        assert "This lesson is playing in English because" not in listing(), "Complete recording unexpectedly fell back to English"
        subprocess.run(["screencapture", "-x", str(evidence / "offline-lesson.png")], check=True)
        pointer("menu", "Checkmate", "Settings…")
        wait(lambda: "Remove stored lesson" in listing(), "Lessons settings did not reopen")
        pointer("click", "Remove stored lesson")
        wait(lambda: "Remove stored lesson language?" in listing(), "Recording removal confirmation did not open")
        pointer("click", "Remove")
        wait(lambda: "Recordings removed." in listing(), "Confirmed recording removal failed")
        wait(lambda: "French lesson:" in listing(), "Recording removal discarded translated inspection text")
        pointer("close-window", "Settings")
        pointer("click", "Introduction")
        wait(lambda: "This lesson is playing in English because" in listing(), "Removed recording did not fall back to English")
        subprocess.run(["screencapture", "-x", str(evidence / "fallback-lesson.png")], check=True)
        pointer("menu", "Checkmate", "Settings…")
        wait(lambda: "Recording voice" in listing(), "Lessons settings did not reopen after fallback")
    pointer("click", "Usage")
    wait(lambda: "Checkmate activity" in listing(), "The Usage settings row did not respond to a click")
    pointer("select-popup", "usage-time-range", "All retained")
    wait(lambda: ("Lesson translation" if fixture else "No recorded Checkmate activity") in listing(), "The usage range did not respond to a click")
    pointer("click", "Clear history…")
    wait(lambda: "Clear usage history?" in listing(), "Clear history confirmation did not open")
    pointer("click", "Cancel")
    wait(lambda: "Clear usage history?" not in listing(), "Clear history cancellation failed")
    if fixture:
        pointer("click", "Refresh account status")
        wait(lambda: "Automation fixture account status" in listing(), "Explicit fixture account refresh failed")
    pointer("tab")  # Posted keyboard navigation reaches a native control.
    pointer("click", "Export JSON…")
    wait(lambda: "Save" in listing(), "Usage export save panel did not open")
    pointer("go-folder", str(state))
    pointer("click", "Save")
    exported = state / "Checkmate-usage.json"
    wait(exported.exists, "Usage JSON export was not written")
    exported_usage = json.loads(exported.read_text())
    assert "records" in exported_usage, "Usage export has no record array"
    if fixture:
        assert any(record["activity"] == "translation" for record in exported_usage["records"]), "Fixture usage export lost translation activity"
    subprocess.run(["screencapture", "-x", str(evidence / "usage-settings.png")], check=True)
    pointer("click", "About")
    wait(lambda: "Copyright © 2026" in listing(), "The About settings row did not respond to a click")

    result = {"passed": True, "clickWithDrift": True, "clickedMove": True, "draggedMove": True, "illegalDropSnapsBack": True,
              "drawerToggles": True, "drawerMenu": True, "lessonDisclosure": True, "aboutPane": True, "coachReasoningSettings": True, "lessonSettings": True, "usageSettings": True, "usageClearConfirmation": True, "usageExport": True, "lessonJobFixture": fixture, "silent": True}
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
