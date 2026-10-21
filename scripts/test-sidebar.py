"""Silent test-host acceptance for sidebar navigation and the review action menu."""
import atexit
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import uuid

import test_host
test_host.require("native sidebar acceptance")
root = pathlib.Path(__file__).resolve().parents[1]
evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
state = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-sidebar-state-"))
# Removed at exit, after the finally below has stopped the app (run-gates fails a gate that leaves temporary files).
atexit.register(shutil.rmtree, state, ignore_errors=True)
helper = evidence / "sidebar-ax-helper"
subprocess.run(["xcrun", "swiftc", str(root / "Tools/ax-helper.swift"), "-o", str(helper)], check=True)
command = [str(root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"),
           "--automation", "--data-dir", str(state)]
# Silence comes from --automation, not the environment flag that used to unlock review.
environment = dict(os.environ)
for flag in ("CHECKMATE_AUTOMATION", "CHECKMATE_REVIEW_ENABLED", "CHECKMATE_REVIEW_DISABLED"):
    environment.pop(flag, None)
process = None


def act(action, target=""):
    return subprocess.check_output([str(helper), str(process.pid), action, target], text=True)


def wait(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError("Sidebar acceptance condition timed out")


def launch(snapshot=None):
    global process
    args = command + (["--snapshot", str(snapshot)] if snapshot else [])
    process = subprocess.Popen(args, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait(lambda: "Chessboard" in act("list"))


def quit_app():
    act("quit")
    process.wait(timeout=5)


try:
    launch()
    quit_app()
    state_file = state / "state-v1.json"
    document = json.loads(state_file.read_text())
    document["window"].update(left=True, right=True)
    state_file.write_text(json.dumps(document))
    snapshot = evidence / "sidebar-practice.png"
    if snapshot.exists():
        snapshot.unlink()
    launch(snapshot)
    wait(snapshot.exists)
    listing = act("list")
    (evidence / "sidebar-initial-ax.txt").write_text(listing)
    assert "Review game" in listing
    assert "Saved reviews" not in listing
    assert "awaiting novice acceptance" not in listing

    def review_files():
        records = {}
        for path in (state / "Reviews").glob("*.json"):
            try:
                uuid.UUID(path.stem)
            except ValueError:
                continue
            records[path.name] = path.read_bytes()
        return records

    act("select", "Review game")
    wait(lambda: "Choose a game or position to explore." in act("list"))
    listing = act("list")
    for title in ("Open PGN…", "Paste PGN or FEN", "Review Current Game"):
        assert "AXButton: " + title in listing, title
    assert not review_files(), "Navigation created a saved review"
    act("select", "Practice a game")
    wait(lambda: "practice-heading" in act("list"))
    act("press", "e2, White, pawn")
    act("press", "e4, move destination")
    act("select", "Review game")
    wait(lambda: "Choose a game or position to explore." in act("list"))
    act("press", "Review Current Game")
    wait(lambda: "AXButton: Save Review" in act("list"))
    assert not review_files(), "Opening a draft saved it without user intent"
    act("press", "Save Review")
    wait(lambda: len(review_files()) == 1)
    wait(lambda: "Saved reviews" in act("list"))
    assert "AXStaticText: Current game" in act("list")
    # Choosing another game is in the review's action menu, the same two-step route as Delete below.
    act("press", "review-document-actions")
    wait(lambda: "Choose Another Game…" in act("list"))
    act("press", "Choose Another Game…")
    wait(lambda: "Choose a game or position to explore." in act("list"))
    assert len(review_files()) == 1
    act("press", "Review Current Game")
    wait(lambda: "AXButton: Save Review" in act("list"))
    assert len(review_files()) == 1
    act("press", "Save Review")
    wait(lambda: len(review_files()) == 2)

    # Cancel is the default; cancelling deletion leaves the active review intact.
    wait(lambda: "Saved reviews" in act("list"))
    before = review_files()
    act("press", "review-document-actions")
    act("press", "Delete Saved Review…")
    wait(lambda: "AXButton: Cancel" in act("list"))
    act("press", "Cancel")
    assert review_files().keys() == before.keys()
    assert "Return to game" in act("list")
    wait(lambda: "AXButton: Cancel" not in act("list"))
    act("press", "review-document-actions")
    act("press", "Delete Saved Review…")
    wait(lambda: "AXButton: Delete" in act("list"))
    act("press", "Delete")
    wait(lambda: "practice-heading" in act("list"))
    wait(lambda: len(review_files()) == len(before) - 1)
    removed = set(before) - set(review_files())
    assert len(removed) == 1
    removed_name = next(iter(removed))
    assert not (state / "Reviews" / (removed_name[:-5] + ".cursor.json")).exists()
    # Closing and relaunching must not flush a stale snapshot back to disk.
    quit_app()
    launch()
    assert not (state / "Reviews" / removed_name).exists()
    assert all(review_files()[name] == data for name, data in before.items() if name != removed_name)
    assert not (state / "companion/connection.json").exists()
    quit_app()
    result = {"passed": True, "reviewNavigation": True, "returnToPractice": True,
              "workspaceActionsVisible": True, "explicitSave": True, "navigationCreatesNoRecord": True, "emptyReviewsHidden": True, "deleteCancel": True,
              "deletePersistsAcrossRestart": True, "otherReviewsPreserved": True, "ordinaryReviewDefaults": True, "silent": True}
    (evidence / "sidebar-results.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
except Exception:
    if process is not None and process.poll() is None:
        (evidence / "sidebar-failure-ax.txt").write_text(act("list"))
    raise
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
