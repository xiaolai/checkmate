"""Silent test-host acceptance for the training pilot with real pointer input.

Every action is a posted mouse event (accessibility presses bypass hit-testing): the library entries, square
selection with Submit and None, a clicked and a dragged move, Hint, Try again, Back to training, and Pawn Duel
opened from the library with its level picker (the levels calibration offers, shown as Gentle, Steady and Strong) and
"Start a new game at" the chosen level. The app runs with its own automation identifier and data directory, training enabled.
"""
import atexit
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
from collections import deque

import test_host
test_host.require("native pointer acceptance")
root = pathlib.Path(__file__).resolve().parents[1]
evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
state = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-training-pointer-state-"))
atexit.register(shutil.rmtree, state, ignore_errors=True)
helper = evidence / "training-pointer-helper"
lister = evidence / "training-pointer-ax-helper"
subprocess.run(["xcrun", "swiftc", str(root / "Tools/pointer-helper.swift"), "-o", str(helper)], check=True)
subprocess.run(["xcrun", "swiftc", str(root / "Tools/ax-helper.swift"), "-o", str(lister)], check=True)
command = [str(root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"), "--automation", "--data-dir", str(state)]
environment = {key: value for key, value in os.environ.items() if key != "CHECKMATE_AUTOMATION"}
environment["CHECKMATE_TRAINING_ENABLED"] = "1"
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


def saved():
    path = state / "state-v1.json"
    return json.loads(path.read_text()) if path.exists() else {}


def active():
    return (saved().get("training") or {}).get("active")


def summary(entry):
    return ((saved().get("training") or {}).get("summaries") or {}).get(entry, {})


# The movement-drill and attack geometry, mirrored from TrainingGeometry for an independent solution.
def coords(square):
    return ord(square[0]) - 97, int(square[1]) - 1


def name(file, rank):
    return chr(97 + file) + str(rank + 1) if 0 <= file < 8 and 0 <= rank < 8 else None


STRAIGHT = [(1, 0), (-1, 0), (0, 1), (0, -1)]
DIAGONAL = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
JUMPS = [(1, 2), (2, 1), (-1, 2), (-2, 1), (1, -2), (2, -1), (-1, -2), (-2, -1)]


def attacks(origin, board):
    piece = board[origin]
    file, rank = coords(origin)
    color, kind = piece[0], piece[1]
    result = set()

    def ray(directions, slide):
        for dx, dy in directions:
            x, y = file + dx, rank + dy
            while name(x, y):
                result.add(name(x, y))
                if not slide or name(x, y) in board:
                    break
                x, y = x + dx, y + dy

    if kind == "p":
        forward = 1 if color == "w" else -1
        for dx in (-1, 1):
            if name(file + dx, rank + forward):
                result.add(name(file + dx, rank + forward))
    else:
        ray({"n": JUMPS, "b": DIAGONAL, "r": STRAIGHT, "q": STRAIGHT + DIAGONAL, "k": STRAIGHT + DIAGONAL}[kind], kind in "brq")
    return result


def drill_moves(drill, square, captured):
    board = {k: v for k, v in drill["pieces"].items() if k not in captured}
    board[square] = drill["piece"]
    color = drill["piece"][0]
    file, rank = coords(square)
    enemy = lambda s: s in board and board[s][0] != color
    result = []
    if drill["piece"][1] == "p":
        forward, home = (1, 1) if color == "w" else (-1, 6)
        one = name(file, rank + forward)
        if one and one not in board:
            result.append((one, None))
            two = name(file, rank + 2 * forward)
            if rank == home and two and two not in board:
                result.append((two, None))
        result += [(s, s) for s in attacks(square, board) if enemy(s)]
    else:
        result = [(s, s if s in board else None) for s in sorted(attacks(square, board)) if s not in board or enemy(s)]
    if drill["piece"][1] != "k":
        return result
    safe = []
    for to, capture in result:
        after = dict(board)
        del after[square]
        after[to] = drill["piece"]
        if not any(v[0] != color and k != to and to in attacks(k, after) for k, v in after.items()):
            safe.append((to, capture))
    return safe


def drill_route(drill):
    start = (drill["start"], frozenset())
    parent = {start: None}
    queue = deque([start])
    while queue:
        current = queue.popleft()
        if current[0] == drill["target"]:
            route = []
            while parent[current] is not None:
                route.append(current[0])
                current = parent[current]
            return list(reversed(route))
        for to, capture in drill_moves(drill, current[0], current[1]):
            child = (to, current[1] | {capture} if capture else current[1])
            if child not in parent:
                parent[child] = current
                queue.append(child)
    raise AssertionError("fixture: the drill has no route")


def open_entry(title, identifier):
    if "training-entry-" + identifier not in listing():
        pointer("click", "Training library")
    wait(lambda: "training-entry-" + identifier in listing(), "The training library did not show " + title)
    pointer("click", "training-entry-" + identifier)


try:
    process = subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait(lambda: "Chessboard" in listing(), "Board did not appear")
    time.sleep(1)
    if "AXStaticText: The Pawn" not in listing():
        pointer("click", "Sidebar")
    wait(lambda: "AXStaticText: The Pawn" in listing(), "The sidebar did not open")
    pointer("click", "Training")
    wait(lambda: "training-entry-reach-target" in listing(), "Clicking Training did not open the library")
    pilot = all("training-entry-" + entry in listing() for entry in ("reach-target", "find-attackers", "mate-in-one", "pawn-duel"))
    assert pilot, "The library did not list the four pilot entries"

    # Reach the Target: a dragged first move, clicked moves after it, solved on the first try.
    pointer("click", "training-entry-reach-target")
    wait(lambda: active() is not None and active()["entry"] == "reach-target", "Reach the Target did not start")
    if "training-prompt" not in listing():
        pointer("click", "Details")
    wait(lambda: "training-prompt" in listing(), "The exercise drawer did not open")
    drill = active()["scenario"]["drill"]
    route = drill_route(drill)
    previous = drill["start"]
    for index, square in enumerate(route):
        if index == 0:
            pointer("drag-square", previous, square)
        else:
            pointer("click-square", previous)
            pointer("click-square", square)
        wait(lambda: label(square).startswith(square + ", " + ("White" if drill["piece"][0] == "w" else "Black")), f"The move {previous}-{square} did not land")
        previous = square
    wait(lambda: "Solved · first try · no recorded help" in listing(), "Reach the Target did not report a first-try solve")
    # The app saves 250 ms after a change, so the label can appear before the record reaches disk.
    wait(lambda: summary("reach-target").get("firstTryNoRecordedHelp") == 1, "The first-try solve was not saved")
    drill_dragged = True

    # Try again: the same board, practice only.
    pointer("click", "training-retry")
    wait(lambda: active() is not None and active().get("retry") is True, "Try again did not restart the same board as practice")
    wait(lambda: "training-result" not in listing(), "Try again kept the old result")

    # Find the Attackers: clicks select without grading, a second click deselects, Submit grades the answer.
    open_entry("Find the Attackers", "find-attackers")
    wait(lambda: active() is not None and active()["entry"] == "find-attackers", "Find the Attackers did not start")
    scenario = active()["scenario"]
    diagram, target = scenario["diagram"], scenario["target"]
    answer = sorted(s for s, p in diagram.items() if s != target and p[0] == scenario["learner"] and target in attacks(s, diagram))
    # A decoy is any square outside the answer: a non-attacking piece when the board has one, else an empty square
    # (selection accepts any square). Some boards have no non-attacking piece, so occupied squares alone can run out.
    decoys = [s for s in sorted(diagram) if s not in answer and s != target]
    decoy = decoys[0] if decoys else next(f + r for f in "abcdefgh" for r in "12345678" if f + r not in diagram)
    pointer("click-square", decoy)
    wait(lambda: "in your answer" in label(decoy), "Clicking a square did not select it")
    assert "training-result" not in listing(), "Selecting a square graded the answer"
    pointer("click-square", decoy)
    wait(lambda: "in your answer" not in label(decoy), "A second click did not deselect the square")
    for square in answer:
        pointer("click-square", square)
        wait(lambda: "in your answer" in label(square), "Clicking an attacker did not select it")
    pointer("click", "training-none" if not answer else "training-submit")
    wait(lambda: "Solved · first try · no recorded help" in listing(), "Submitting the attackers did not grade them correct")
    selection_submitted = True

    # None on a board that has attackers is a wrong answer, not a crash or a silent pass.
    pointer("click", "training-next")
    wait(lambda: active() is not None and active()["scenario"]["id"] != scenario["id"], "Next exercise did not start a new board")
    pointer("click", "training-none")
    wait(lambda: "training-result" in listing(), "None was not graded")

    # Mate in One: Hint marks recorded help; the mating move is dragged.
    open_entry("Mate in One", "mate-in-one")
    wait(lambda: active() is not None and active()["entry"] == "mate-in-one", "Mate in One did not start")
    mate = active()["scenario"]["expected"]["moves"][0]
    pointer("click", "training-hint-button")
    wait(lambda: "training-hint" in listing(), "Hint did not show a hint")
    pointer("drag-square", mate[:2], mate[2:4])
    if len(mate) == 5:
        # Training promotes through the board's promotion menu, as practice does.
        piece = {"n": "Knight", "b": "Bishop", "r": "Rook", "q": "Queen"}[mate[4]]
        wait(lambda: pointer("menu-open", piece) == "true", "The mating promotion did not open the promotion menu")
        pointer("choose-menu-item", piece)
    wait(lambda: "Solved with recorded help" in listing(), "The hinted mate was not labelled as recorded help")
    # Wait for the hinted solve itself to be saved; only then does a zero no-help count mean anything.
    wait(lambda: summary("mate-in-one").get("assistedCompletions") == 1, "The hinted solve was not saved as recorded help")
    assert summary("mate-in-one").get("firstTryNoRecordedHelp", 0) == 0, "A hinted solve counted as no recorded help"
    hint_recorded = True

    # Pawn Duel from the library: its own board and rules, and the way back to training.
    open_entry("Pawn Duel", "pawn-duel")
    wait(lambda: label("e2").startswith("e2, White, pawn"), "Pawn Duel did not open from the library")
    pointer("click-square", "e2")
    pointer("click-square", "e4")
    wait(lambda: label("e4").startswith("e4, White, pawn"), "A clicked Pawn Duel move did not land")

    # The level picker is per game: another level keeps the game in progress at its own and offers a new game at it.
    def duel():
        return (saved().get("miniGames") or {}).get("pawn-duel") or {}
    wait(lambda: len(duel().get("history", [])) == 2, "The computer did not reply in Pawn Duel")
    wait(lambda: (duel().get("level") or {}).get("profile") == "standard", "The Pawn Duel run did not freeze its level")
    if "mini-difficulty" not in listing():
        pointer("click", "Details")
    wait(lambda: "mini-difficulty" in listing(), "The mini-game drawer did not show the level picker")
    # Calibration (WI-016) decides the levels; Pawn Duel offers Gentle (stored as beginner), Steady and Strong.
    offered = next(v["offered"] for v in json.loads((root / "Content/calibration/mini-game-results.json").read_text())["verdicts"] if v["game"] == "pawn-duel")
    assert offered == ["beginner", "standard", "challenging"], f"Pawn Duel's calibrated levels changed to {offered}: update this gate"
    pointer("select-popup", "mini-difficulty", "Gentle")
    wait(lambda: "mini-new-level" in listing(), "Choosing a level during a game did not offer a new game at it")
    assert "Start a new game at Gentle" in listing() and "This game continues at Steady." in listing(), "The offer does not name the levels as shown"
    wait(lambda: (saved().get("settings") or {}).get("miniOpponentProfiles", {}).get("pawn-duel") == "beginner", "The per-game level was not saved")
    assert (duel().get("level") or {}).get("profile") == "standard" and len(duel().get("history", [])) == 2, "The game in progress changed level"
    pointer("click", "mini-new-level")
    wait(lambda: (duel().get("level") or {}).get("profile") == "beginner" and not duel().get("history"), "Start a new game at Gentle did not start one at it")
    wait(lambda: "mini-new-level" not in listing(), "The new game still offered another one")
    level_picker = True
    pointer("click", "Back to training")
    wait(lambda: "training-entry-pawn-duel" in listing(), "Back to training did not return to the library")
    legacy_from_library = True

    # The hinted mate is suggested for another try; following the suggestion replays that board as practice.
    wait(lambda: "training-suggestion-mate-in-one" in listing(), "The hinted board was not suggested")
    pointer("click", "training-suggestion-mate-in-one")
    wait(lambda: active() is not None and active()["entry"] == "mate-in-one" and active().get("retry") is True, "The suggestion did not start its board as practice")
    pointer("click", "Training library")
    wait(lambda: "training-entry-reach-target" in listing(), "The transport did not return to the library")
    suggestion_practised = True

    # Quit in the middle of an exercise and relaunch: Continue resumes the same board from the saved attempt.
    pointer("click", "training-entry-reach-target")
    wait(lambda: active() is not None and active()["entry"] == "reach-target" and not active()["actions"], "A new Reach the Target did not start")
    drill = active()["scenario"]["drill"]
    step = next(to for to, _ in drill_moves(drill, drill["start"], frozenset()) if to != drill["target"])
    pointer("click-square", drill["start"])
    pointer("click-square", step)
    wait(lambda: len(active()["actions"]) == 1, "The move before quitting was not saved")
    pointer("menu", "Checkmate", "Quit Checkmate")
    deadline = time.monotonic() + 15
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.2)
    assert process.poll() is not None, "Quit did not end the app during an exercise"
    process = subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait(lambda: "Chessboard" in listing(), "Board did not appear after relaunch")
    time.sleep(1)
    if "AXStaticText: The Pawn" not in listing():
        pointer("click", "Sidebar")
    wait(lambda: "AXStaticText: The Pawn" in listing(), "The sidebar did not open after relaunch")
    pointer("click", "Training")
    wait(lambda: "training-continue" in listing(), "The unfinished exercise was not offered as Continue after relaunch")
    pointer("click", "training-continue")
    wait(lambda: label(step).startswith(step + ", " + ("White" if drill["piece"][0] == "w" else "Black")), "Continue did not resume the saved board")
    resumed_after_quit = True

    result = {"passed": True, "pilotEntries": pilot, "drillDragAndClick": drill_dragged, "selectionSubmit": selection_submitted,
              "hintRecordedHelp": hint_recorded, "legacyFromLibrary": legacy_from_library, "levelPicker": level_picker, "suggestionPractised": suggestion_practised, "resumedAfterQuit": resumed_after_quit}
    (evidence / "training-pointer-results.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
except Exception:
    if process is not None and process.poll() is None:
        (evidence / "training-pointer-failure-ax.txt").write_text(listing())
        subprocess.run(["screencapture", "-x", str(evidence / "training-pointer-failure.png")], check=False)
    raise
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
