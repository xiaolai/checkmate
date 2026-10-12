"""Silent build-host acceptance for real pointer input: board clicks, drags and drawer controls.

Accessibility presses bypass hit-testing, so every action here is a posted mouse event.
"""
import atexit
import json
import os
import re
import pathlib
import shutil
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
# Removed at exit, after the finally below has stopped the app (run-gates fails a gate that leaves temporary files).
atexit.register(shutil.rmtree, state, ignore_errors=True)
helper = evidence / "pointer-helper"
lister = evidence / "pointer-ax-helper"
subprocess.run(["xcrun", "swiftc", str(root / "Tools/pointer-helper.swift"), "-o", str(helper)], check=True)
subprocess.run(["xcrun", "swiftc", str(root / "Tools/ax-helper.swift"), "-o", str(lister)], check=True)
command = [str(root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"), "--automation", "--data-dir", str(state)]
environment = {key: value for key, value in os.environ.items() if key != "CHECKMATE_AUTOMATION"}
# The unsaved-reviews quit alert is shown (not auto-answered) so its buttons are clicked like a person's.
environment["CHECKMATE_QUIT_ALERT_FIXTURE"] = "1"
app_bundle = root / "build/CheckmateAutomation.app"
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


def dialog(text, button):
    """Clicks a button in the window showing text, so an alert's Cancel is never confused with another window's."""
    pointer("dialog-click", text, button)


def reviews():
    """Saved review records (not the index or cursor sidecars) and the cursor each persists."""
    folder = state / "Reviews"
    records = {}
    for path in folder.glob("*.json") if folder.exists() else []:
        if path.name == "index.json" or path.name.endswith(".cursor.json"):
            continue
        record = json.loads(path.read_text())
        cursor = record["cursor"]
        sidecar = path.with_name(path.stem + ".cursor.json")
        if sidecar.exists():
            metadata = json.loads(sidecar.read_text())
            if metadata.get("updatedAt", 0) >= record.get("updatedAt", 0):
                cursor = metadata["cursor"]
        records[path] = cursor
    return records


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
    wait(lambda: "Translate" in listing(), "Lesson translation controls are missing")
    fixture = environment.get("CHECKMATE_LESSON_FIXTURE") == "1"
    if fixture:
        pointer("select-popup", "lesson-language", "French")
        pointer("click", "Translate")
        wait(lambda: "French lesson:" in listing(), "Fixture translation did not populate text inspection")
        wait(lambda: "Completed. Matching" in listing(), "Fixture translation did not finish")
        pointer("click", "Generate preview")
        wait(lambda: "Preview ready." in listing(), "Fixture preview generation did not finish")
        pointer("click", "Record / Resume")
        wait(lambda: re.search(r"Lesson 1 of 1, clip [0-9]+ of 20", listing()) is not None, "Fixture recording progress is missing")
        # Control for the cleanup check below: a running lesson job's Cancel accepts clicks.
        assert pointer("enabled", "lesson-job-cancel") == "true", "Cancel was disabled during a cancellable recording"
        pointer("click", "lesson-job-cancel")
        wait(lambda: "Cancelled. Completed text and clips" in listing(), "Fixture recording cancellation failed")
        subprocess.run(["screencapture", "-x", str(evidence / "lesson-settings.png")], check=True)
        wait(lambda: "Incomplete lessons use English." in listing(), "Cancelled partial recording did not report English fallback")
        pointer("click", "Record / Resume")
        wait(lambda: "Complete offline lesson: 20 verified recordings." in listing(), "Fixture resumed recording did not complete", timeout=30)
        # Destructive confirmations: Cancel (and Return, the default) close them without acting.
        pointer("click", "Remove clip")
        wait(lambda: "Remove clip 1?" in listing(), "Clip removal confirmation did not open")
        dialog("Remove clip 1?", "Cancel")
        wait(lambda: "Remove clip 1?" not in listing(), "Cancel did not close the clip removal confirmation")
        time.sleep(0.5)
        assert "Clip 1 removed." not in listing() and "Complete offline lesson: 20 verified recordings." in listing(), "Cancel removed the clip"
        pointer("click", "Remove clip")
        wait(lambda: "Remove clip 1?" in listing(), "Clip removal confirmation did not reopen")
        pointer("return")
        wait(lambda: "Remove clip 1?" not in listing(), "Return did not close the clip removal confirmation")
        time.sleep(0.5)
        assert "Clip 1 removed." not in listing() and "Complete offline lesson: 20 verified recordings." in listing(), "Return (the default button) removed the clip"
        pointer("click", "Remove clip")
        wait(lambda: "Remove clip 1?" in listing(), "Clip removal confirmation did not open")
        dialog("Remove clip 1?", "Remove")
        wait(lambda: "Clip 1 removed." in listing(), "Confirmed clip removal failed")
        wait(lambda: "19 of 20 recordings stored" in listing(), "Removing one clip did not keep the other 19")
        pointer("click", "Record / Resume")
        wait(lambda: "Complete offline lesson: 20 verified recordings." in listing(), "Re-recording the removed clip did not complete", timeout=30)
        pointer("close-window", "Settings")
        pointer("click", "French lesson: Introduction")
        wait(lambda: "French lesson:" in listing() and "In this lesson" in listing(), "Offline translated lesson did not open")
        assert "This lesson is playing in English because" not in listing(), "Complete recording unexpectedly fell back to English"
        subprocess.run(["screencapture", "-x", str(evidence / "offline-lesson.png")], check=True)
        pointer("menu", "Checkmate", "Settings…")
        wait(lambda: "Remove stored lesson" in listing(), "Lessons settings did not reopen")
        pointer("click", "Remove stored lesson")
        wait(lambda: "Remove stored lesson language?" in listing(), "Recording removal confirmation did not open")
        dialog("Remove stored lesson language?", "Remove")
        wait(lambda: "Recordings removed." in listing(), "Confirmed recording removal failed")
        wait(lambda: "French lesson:" in listing(), "Recording removal discarded translated inspection text")
        pointer("close-window", "Settings")
        pointer("click", "Introduction")
        wait(lambda: "This lesson is playing in English because" in listing(), "Removed recording did not fall back to English")
        subprocess.run(["screencapture", "-x", str(evidence / "fallback-lesson.png")], check=True)
        pointer("menu", "Checkmate", "Settings…")
        wait(lambda: "Recording voice" in listing(), "Lessons settings did not reopen after fallback")
        # Discarding translated text: Cancel keeps it; Discard removes it and says so.
        pointer("click", "Discard translated text…")
        wait(lambda: "Discard translated text?" in listing(), "Discard confirmation did not open")
        dialog("Discard translated text?", "Cancel")
        wait(lambda: "Discard translated text?" not in listing(), "Cancel did not close the discard confirmation")
        time.sleep(0.5)
        assert "Translation and recordings discarded." not in listing() and "French lesson:" in listing(), "Cancel discarded the translated text"
        pointer("click", "Discard translated text…")
        wait(lambda: "Discard translated text?" in listing(), "Discard confirmation did not reopen")
        dialog("Discard translated text?", "Discard")
        wait(lambda: "Translation and recordings discarded." in listing(), "Confirmed discard did not report its result")
        # Outdated-translation cleanup: Cancel does nothing; once confirmed it runs to completion and cannot be cancelled.
        pointer("click", "Remove outdated translations…")
        wait(lambda: "Remove outdated translations?" in listing(), "Cleanup confirmation did not open")
        dialog("Remove outdated translations?", "Cancel")
        wait(lambda: "Remove outdated translations?" not in listing(), "Cancel did not close the cleanup confirmation")
        time.sleep(0.5)
        assert "Removing outdated translations" not in listing() and "outdated translations or recordings to remove" not in listing(), "Cancel started the cleanup"
        pointer("click", "Remove outdated translations…")
        wait(lambda: "Remove outdated translations?" in listing(), "Cleanup confirmation did not reopen")
        dialog("Remove outdated translations?", "Remove")
        wait(lambda: "Removing outdated translations" in listing(), "Confirmed cleanup did not start")
        assert pointer("enabled", "lesson-job-cancel") == "false", "Cancel was enabled while cleanup ran"
        wait(lambda: re.search(r"No outdated translations or recordings to remove\.|Removed [0-9]+ outdated file", listing()) is not None, "Cleanup did not report its result")
    pointer("click", "Usage")
    wait(lambda: "Checkmate activity" in listing(), "The Usage settings row did not respond to a click")
    pointer("select-popup", "usage-time-range", "All retained")
    wait(lambda: pointer("value", "usage-time-range") == "All retained", "The usage range did not respond to a click")
    # The activity rows always render; only their values show whether the range holds recorded operations.
    if fixture:
        wait(lambda: re.search(r"[1-9][0-9]* reported total tokens", listing()) is not None, "The usage range did not show the fixture's recorded tokens")
    else:
        wait(lambda: "No recorded Checkmate activity in this time range." in listing(), "An empty usage range did not say so")
    pointer("click", "Clear history…")
    wait(lambda: "Clear usage history?" in listing(), "Clear history confirmation did not open")
    pointer("click", "Cancel")
    wait(lambda: "Clear usage history?" not in listing(), "Clear history cancellation failed")
    if fixture:
        pointer("click", "Refresh account status")
        wait(lambda: "Automation fixture account status" in listing(), "Explicit fixture account refresh failed")
    pointer("click", "Export JSON…")
    # The closed menu bar always lists File ▸ Save Review, so wait for the panel's own Save button.
    wait(lambda: re.search(r"^AXButton: Save( \||$)", listing(), re.M) is not None, "Usage export save panel did not open")
    pointer("go-folder", str(state))
    # The Go to Folder sheet closes with an animation; a click on Save during it is dropped by the panel.
    wait(lambda: re.search(r"^AXPopUpButton: Where: \| " + re.escape(state.name), listing(), re.M) is not None and "Go to Folder" not in listing(), "The save panel did not move to the export folder")
    time.sleep(0.5)
    pointer("click", "Save")
    exported = state / "Checkmate-usage.json"
    wait(exported.exists, "Usage JSON export was not written")
    exported_usage = json.loads(exported.read_text())
    assert "records" in exported_usage, "Usage export has no record array"
    if fixture:
        assert any(record["activity"] == "translation" for record in exported_usage["records"]), "Fixture usage export lost translation activity"
    subprocess.run(["screencapture", "-x", str(evidence / "usage-settings.png")], check=True)
    # Codex setup explains itself instead of touching Codex in automation.
    pointer("click", "Connections")
    wait(lambda: "Remove Codex Setup…" in listing(), "The Connections settings row did not respond to a click")
    pointer("click", "Remove Codex Setup…")
    wait(lambda: "Codex setup is disabled during automation." in listing(), "Remove Codex Setup did not explain itself")
    pointer("click", "About")
    wait(lambda: "Copyright © 2026" in listing(), "The About settings row did not respond to a click")
    pointer("close-window", "Settings")

    # Several files opened at once (Finder's Open With): the learner picks one; Cancel opens none.
    games = {"alpha.pgn": '[White "Alpha"]\n\n1. e4 e5 2. Nf3 Nc6 *\n', "bravo.pgn": '[White "Bravo"]\n\n1. d4 d5 2. c4 dxc4 3. e3 *\n'}
    for name, text in games.items():
        (state / name).write_text(text)
    open_files = lambda: subprocess.run(["open", "-a", str(app_bundle), *(str(state / name) for name in games)], check=True)
    open_files()
    wait(lambda: "Choose a file to review" in listing(), "Opening two files did not ask which to review")
    dialog("Choose a file to review", "Cancel")
    wait(lambda: "Choose a file to review" not in listing(), "Cancel did not close the file chooser")
    # Without captures, a game's only listed moment is its final move: Nc6 for alpha, dxc4 and e3 for bravo.
    # A load takes well under this; any review opened by the cancelled chooser would be listed by now.
    time.sleep(3)
    assert "2, Black, dxc4" not in listing() and "2, Black, Nc6" not in listing(), "Cancel still opened a file"
    running = subprocess.run(["pgrep", "-f", str(app_bundle / "Contents/MacOS/CheckmateNative")], capture_output=True, text=True).stdout.split()
    assert running == [str(process.pid)], f"Opening files started another app instance: {running}"
    open_files()
    wait(lambda: "Choose a file to review" in listing(), "The file chooser did not reopen")
    pointer("select-popup", "File to review", "bravo.pgn")
    wait(lambda: pointer("value", "File to review") == "bravo.pgn", "The file chooser did not take the pointer's choice")
    dialog("Choose a file to review", "Review")
    wait(lambda: "2, Black, dxc4" in listing(), "The chosen file did not open for review")
    assert "2, Black, Nc6" not in listing(), "The chooser opened the file it was not given"

    # Quitting with a review that cannot be saved asks first; Cancel keeps the app and the review.
    pointer("menu", "File", "Save Review")
    wait(lambda: len(reviews()) == 1, "Save Review did not write the review")
    # The index is replaced atomically after the record: lock only once no temporary file is in flight and the
    # folder's contents are stable, or a temporary file renamed away between listing and chmod fails the run.
    def settled():
        first = sorted(path.name for path in (state / "Reviews").rglob("*") if path.is_file())
        time.sleep(0.5)
        second = sorted(path.name for path in (state / "Reviews").rglob("*") if path.is_file())
        return first == second and "index.json" in second and not any(".sb-" in name for name in second)
    wait(settled, "The review folder did not settle after Save Review")
    saved = reviews()
    # Read-only files and folder: neither an atomic replacement nor an in-place rewrite can save the review.
    locked = [path for path in (state / "Reviews").rglob("*") if path.is_file()]
    for path in locked:
        path.chmod(0o400)
    (state / "Reviews").chmod(0o500)
    try:
        pointer("click", "2, Black, dxc4")
        # Quit only once the review shows the new position: a quit queued before the click is applied has nothing unsaved.
        wait(lambda: pointer("label", "c4").startswith("c4, Black, pawn"), "Clicking dxc4 did not move the review there")
        pointer("menu", "Checkmate", "Quit Checkmate")
        wait(lambda: process.poll() is not None or "A review could not be saved." in listing(), "Quitting with an unsaved review did not ask")
        assert process.poll() is None, "Quitting with an unsaved review did not ask: the app quit"
        dialog("A review could not be saved.", "Cancel")
        wait(lambda: "A review could not be saved." not in listing(), "Cancel did not close the quit alert")
        time.sleep(1)
        assert process.poll() is None, "Cancel on the unsaved-reviews alert quit the app"
        assert "2, Black, dxc4" in listing(), "Cancel on the unsaved-reviews alert closed the review"
    finally:
        (state / "Reviews").chmod(0o700)
        for path in locked:
            path.chmod(0o600)
    # Once saving works again, quitting saves the latest position without asking.
    pointer("menu", "Checkmate", "Quit Checkmate")
    deadline = time.monotonic() + 15
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.2)
    assert process.poll() is not None, "Quit did not end the app once the review could be saved"
    after = reviews()
    assert list(after) == list(saved), "Quitting changed which reviews exist"
    assert list(after.values())[0] != list(saved.values())[0] and list(after.values())[0] == 4, f"Quit did not save the latest review position: {saved} -> {after}"

    result = {"passed": True, "clickWithDrift": True, "clickedMove": True, "draggedMove": True, "illegalDropSnapsBack": True,
              "drawerToggles": True, "drawerMenu": True, "lessonDisclosure": True, "aboutPane": True, "coachReasoningSettings": True, "lessonSettings": True, "usageSettings": True, "usageClearConfirmation": True, "usageExport": True, "lessonJobFixture": fixture,
              "lessonConfirmCancel": fixture, "lessonConfirmReturnCancels": fixture, "lessonDiscardConfirmed": fixture, "lessonCleanupCannotCancel": fixture,
              "codexSetupMessage": True, "reviewChooserCancel": True, "reviewChooserPicks": True, "quitAlertCancelKeepsReview": True, "quitSavesReview": True}
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
