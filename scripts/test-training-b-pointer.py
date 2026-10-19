"""Silent test-host acceptance for the Increment B beginner skills with real pointer input.

Every action is a posted mouse event (accessibility presses bypass hit-testing): the Beginner skills section and a
subskill chip, the promotion chooser cancelled and then answered, a normal-chess bridge opened from an existing game,
a Finish the Game move answered by the bundled offline Stockfish defender, then taken back, the position games listed
under the preview caption and one of them played, its move answered by Stockfish, the opponent level picker on a game
whose calibration offers several levels (a game with no move takes the level, one in progress keeps its own and offers
a new game at it) and none on one whose calibration offers one, the training game's voice coach connected from the bar
and disconnected from the drawer with the silent voice double (connecting records no help), a mixed case whose topic
appears only after the answer, a guided game played, ended and reviewed, and a related lesson read and left for
training. The app runs with its own automation identifier and data directory, with training, its B preview, position
games and the training voice coach enabled.
"""
import atexit
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

import test_host
test_host.require("native pointer acceptance")
root = pathlib.Path(__file__).resolve().parents[1]
evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
state = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-training-b-pointer-state-"))
atexit.register(shutil.rmtree, state, ignore_errors=True)
helper = evidence / "training-b-pointer-helper"
lister = evidence / "training-b-pointer-ax-helper"
subprocess.run(["xcrun", "swiftc", str(root / "Tools/pointer-helper.swift"), "-o", str(helper)], check=True)
subprocess.run(["xcrun", "swiftc", str(root / "Tools/ax-helper.swift"), "-o", str(lister)], check=True)
# The silent voice double stands in for the realtime service: nothing leaves the Mac, no audio plays, no microphone opens.
command = [str(root / "build/CheckmateAutomation.app/Contents/MacOS/CheckmateNative"), "--automation", "--data-dir", str(state), "--voice-double"]
environment = {key: value for key, value in os.environ.items() if key != "CHECKMATE_AUTOMATION"}
environment["CHECKMATE_TRAINING_ENABLED"] = "1"
environment["CHECKMATE_TRAINING_B"] = "1"
# Position games and opponent levels (mini-game plan WI-017), default off for users.
environment["CHECKMATE_POSITION_GAMES"] = "1"
# The voice coach in a standard-rule training game (mini-game plan WI-021), default off for users.
environment["CHECKMATE_TRAINING_VOICE"] = "1"
process = None
PIECES = {"n": "knight", "b": "bishop", "r": "rook", "q": "queen"}
COLOURS = {"w": "White", "b": "Black"}
# The position games (mini-game plan WI-020) and the levels calibration lets each offer, from its published results.
POSITION_ENTRIES = ("pawn-race", "pawn-war", "cut-down-chess", "two-bishop-mate")
OFFERED = {f"{v['entry']}/{v['variant']}": v["offered"] for v in json.loads((root / "Content/calibration/position-game-results.json").read_text())["verdicts"]}
TITLES = {"gentle": "Gentle", "steady": "Steady", "strong": "Strong"}


def pointer(action, *arguments):
    return subprocess.check_output([str(helper), str(process.pid), action, *arguments], text=True).strip()


def listing():
    return subprocess.check_output([str(lister), str(process.pid), "list"], text=True)


# NativeModel saves 250 ms after a change. A check that something was NOT saved waits this long first, or a stale
# file would pass it before the save it is meant to catch lands.
SAVE_SETTLE = 0.6


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


def attempts():
    return (saved().get("training") or {}).get("attempts") or []


def open_library():
    if "training-entry-save-your-piece" not in listing():
        pointer("click", "Training library")
    wait(lambda: "training-entry-save-your-piece" in listing(), "The library did not list the beginner skills")


def show_details():
    if "training-prompt" not in listing():
        pointer("click", "Toggle Game Details")
    wait(lambda: "training-prompt" in listing(), "The exercise drawer did not open")


# Lone-king geometry, enough to pick a quiet legal queen or rook move independently of the app.
def coords(square):
    return ord(square[0]) - 97, int(square[1]) - 1


def name(file, rank):
    return chr(97 + file) + str(rank + 1) if 0 <= file < 8 and 0 <= rank < 8 else None


def board_of(fen):
    board = {}
    for row, text in enumerate(fen.split()[0].split("/")):
        file = 0
        for ch in text:
            if ch.isdigit():
                file += int(ch)
            else:
                board[name(file, 7 - row)] = ("w" if ch.isupper() else "b") + ch.lower()
                file += 1
    return board


def slides(origin, kind, board):
    directions = [(1, 0), (-1, 0), (0, 1), (0, -1)] + ([(1, 1), (1, -1), (-1, 1), (-1, -1)] if kind == "q" else [])
    file, rank = coords(origin)
    for dx, dy in directions:
        x, y = file + dx, rank + dy
        while name(x, y):
            yield name(x, y)
            if name(x, y) in board:
                break
            x, y = x + dx, y + dy


def distance(a, b):
    (ax, ay), (bx, by) = coords(a), coords(b)
    return max(abs(ax - bx), abs(ay - by))


def quiet_move(fen, learner):
    board = board_of(fen)
    piece = next(s for s, p in board.items() if p[0] == learner and p[1] in "qr")
    kind = board[piece][1]
    mine = next(s for s, p in board.items() if p == learner + "k")
    theirs = next(s for s, p in board.items() if p[0] != learner)
    for to in sorted(slides(piece, kind, board)):
        if to in board or distance(to, theirs) < 2:
            continue
        after = {s: p for s, p in board.items() if s not in (piece, theirs)}
        after[to] = learner + kind
        covered = set(slides(to, kind, after))
        if theirs in covered:
            continue
        file, rank = coords(theirs)
        escapes = [name(file + dx, rank + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1) if (dx or dy) and name(file + dx, rank + dy)]
        if any(s not in covered and distance(s, mine) > 1 for s in escapes):
            return piece, to, kind
    raise AssertionError("fixture: no quiet move found in " + fen)


try:
    process = subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait(lambda: "Chessboard" in listing(), "Board did not appear")
    time.sleep(1)
    if "AXStaticText: The Pawn" not in listing():
        pointer("click", "Toggle Sidebar")
    wait(lambda: "AXStaticText: The Pawn" in listing(), "The sidebar did not open")
    pointer("click", "Training")
    wait(lambda: "training-entry-reach-target" in listing(), "Clicking Training did not open the library")
    tree = listing()
    beginner_library = all("training-entry-" + entry in tree for entry in ("save-your-piece", "capture-wisely", "special-moves", "simple-tactics", "finish-the-game")) and "Preview: these exercises" in tree
    assert beginner_library, "The Beginner skills section did not list its entries with the preview caption"

    # A subskill chip starts that variant: promotion.
    pointer("click", "training-variant-special-moves-promotion")
    wait(lambda: active() is not None and active()["scenario"]["variant"] == "promotion", "The promotion chip did not start a promotion exercise")
    show_details()
    scenario = active()["scenario"]
    learner = scenario["learner"]
    move = next(m for m in scenario["nodes"][0]["accepted"] if len(m) == 5)
    origin, target = move[:2], move[2:4]
    variant_chip = True

    # The chooser opens on the last rank; Cancel leaves the pawn and counts nothing.
    pointer("drag-square", origin, target)
    wait(lambda: "training-promotion-cancel" in listing(), "Reaching the last rank did not open the promotion chooser")
    pointer("click", "training-promotion-cancel")
    wait(lambda: "training-promotion-cancel" not in listing(), "Cancel did not close the chooser")
    assert label(origin).startswith(f"{origin}, {COLOURS[learner]}, pawn"), "Cancelling moved the pawn"
    time.sleep(SAVE_SETTLE)
    assert not active()["actions"] and not attempts(), "Cancelling the chooser was counted"
    promotion_cancelled = True

    # Choosing a knight is a legal promotion and solves it.
    pointer("drag-square", origin, target)
    wait(lambda: "training-promotion-cancel" in listing(), "The chooser did not reopen")
    pointer("click", "Knight")
    wait(lambda: label(target).startswith(f"{target}, {COLOURS[learner]}, knight"), "The knight promotion did not land")
    wait(lambda: "Solved · first try · no recorded help" in listing(), "The promotion was not graded correct")
    promotion_chosen = True

    # An existing game links its normal-chess bridge.
    open_library()
    pointer("click", "training-bridge-queen-vs-pawns")
    wait(lambda: active() is not None and active()["scenario"].get("bridge") == "pawn-duel", "The Queen Against Pawns bridge did not open its normal-chess case")
    bridge_opened = True

    # Finish the Game: a dragged move, answered by the offline defender, then taken back.
    open_library()
    pointer("click", "training-variant-finish-the-game-kqk")
    wait(lambda: active() is not None and active()["entry"] == "finish-the-game" and not active()["actions"], "The King and queen chip did not start an ending")
    show_details()
    scenario = active()["scenario"]
    learner = scenario["learner"]
    piece, to, kind = quiet_move(scenario["fen"], learner)
    pointer("drag-square", piece, to)
    wait(lambda: label(to).startswith(f"{to}, {COLOURS[learner]}, {PIECES[kind]}"), "The dragged ending move did not land")
    wait(lambda: any("reply" in action for action in active()["actions"]), "The defender did not answer", timeout=30)
    wait(lambda: "Your move." in listing(), "The board did not return to the learner after the reply")
    ending_reply = True
    pointer("click", "training-undo")
    wait(lambda: any("undo" in action for action in active()["actions"]), "Take back was not recorded")
    wait(lambda: label(piece).startswith(f"{piece}, {COLOURS[learner]}, {PIECES[kind]}"), "Take back did not restore the start")
    ending_take_back = True
    # The same take-back from the control bar's button and from ⌘Z (Edit ▸ Undo), each after a fresh reply.
    for how in ("bar", "command-z"):
        undone = sum("undo" in action for action in active()["actions"])
        pointer("drag-square", piece, to)
        wait(lambda: label(to).startswith(f"{to}, {COLOURS[learner]}, {PIECES[kind]}"), f"The ending move before the {how} take-back did not land")
        wait(lambda: "Your move." in listing() and sum("reply" in action for action in active()["actions"]) > undone, f"The defender did not answer before the {how} take-back", timeout=30)
        if how == "bar":
            pointer("click", "bar-trainingTakeBack")
        else:
            pointer("shortcut", "6", "c")
        wait(lambda: sum("undo" in action for action in active()["actions"]) > undone, f"The {how} take-back was not recorded")
        wait(lambda: label(piece).startswith(f"{piece}, {COLOURS[learner]}, {PIECES[kind]}"), f"The {how} take-back did not restore the start")
    bar_and_command_z_take_back = True
    # The stalemate trap offers only Strong: its attempt froze it, and there is no picker.
    assert (active().get("opponent") or {}).get("profile") == "strong", "The king-and-queen ending did not freeze Strong"
    assert "training-level" not in listing(), "The stalemate trap offered a level choice"

    # The rook ending offers exactly the levels its calibration passed: no picker when that is one.
    open_library()
    pointer("click", "training-variant-finish-the-game-krk")
    wait(lambda: active() is not None and active()["scenario"]["variant"] == "krk" and not active()["actions"], "The King and rook chip did not start an ending")
    show_details()
    time.sleep(SAVE_SETTLE)
    assert ("training-level" in listing()) == (len(OFFERED["finish-the-game/krk"]) > 1), "The rook ending's picker does not match its calibration"
    assert (active().get("opponent") or {}).get("profile") == "strong", "The rook ending did not freeze its fallback, Strong"

    # The position games (mini-game plan WI-020), listed under the preview caption, which says they are machine-checked.
    open_library()
    tree = listing()
    position_games_listed = all("training-entry-" + entry in tree for entry in POSITION_ENTRIES) and "Preview: these exercises" in tree
    assert position_games_listed, "The position games are not listed under the preview caption"

    # A cut-down game with several calibrated levels: a dragged pawn move answered by Stockfish, then the level picker.
    # A game with no move takes the chosen level; a game in progress keeps its own and offers a new game at the other.
    variant = next(key.split("/")[1] for key, levels in OFFERED.items() if key.startswith("cut-down-chess/") and len(levels) > 1)
    low, high = OFFERED["cut-down-chess/" + variant][0], OFFERED["cut-down-chess/" + variant][-1]
    pointer("click", f"training-variant-cut-down-chess-{variant}")
    wait(lambda: active() is not None and active()["entry"] == "cut-down-chess" and active()["scenario"]["variant"] == variant and not active()["actions"], f"The {variant} chip did not start a cut-down game")
    show_details()
    wait(lambda: "training-level" in listing(), "The cut-down game did not show the level picker")
    first = active()["id"]
    pointer("select-popup", "training-level", TITLES[low])
    wait(lambda: (saved().get("settings") or {}).get("positionGameLevels", {}).get("cut-down-chess") == low, "The chosen level was not saved")
    wait(lambda: (active().get("opponent") or {}).get("profile") == low and active()["id"] == first, "A game with no move did not take the chosen level")
    pointer("drag-square", "e2", "e4")
    wait(lambda: label("e4").startswith("e4, White, pawn"), "The dragged pawn move did not land")
    wait(lambda: any("reply" in action for action in active()["actions"]), f"{TITLES[low]} did not answer", timeout=30)
    wait(lambda: "Your move." in listing(), "The board did not return to the learner after the reply")
    opponent = active()["opponent"]
    assert opponent["limit"].get("nodes") and opponent["strategy"] == ("beginner" if low == "gentle" else "engine"), f"{TITLES[low]} is not its node-limited strategy"
    position_game_reply = True
    pointer("select-popup", "training-level", TITLES[high])
    wait(lambda: (saved().get("settings") or {}).get("positionGameLevels", {}).get("cut-down-chess") == high, "Choosing another level during a game was not saved")
    wait(lambda: "training-new-level" in listing(), "Choosing a level during a game did not offer a new game at it")
    assert active()["opponent"]["profile"] == low and active()["id"] == first, "The game in progress changed level"
    pointer("click", "training-new-level")
    wait(lambda: active()["id"] != first and (active().get("opponent") or {}).get("profile") == high and not active()["actions"], "Start a new game at this level did not start one at it")
    assert attempts()[-1]["outcome"] == "abandoned" and attempts()[-1].get("level") == low, "The game left was not recorded at its own level"
    wait(lambda: "training-new-level" not in listing(), "The new game still offered another one")
    level_picker = True

    # The training game's voice coach (mini-game plan WI-021), on this fresh game: the bar's microphone connects it,
    # connecting records no help, and the drawer's Disconnect Coach ends it.
    assert not active().get("recordedHelp"), "fixture: the new game already had recorded help"
    pointer("click", "bar-voiceConnect")
    wait(lambda: "training-voice-disconnect" in listing() and "training-voice-status" in listing(), "Connecting the training coach did not open its session")
    time.sleep(SAVE_SETTLE)
    assert not active().get("recordedHelp") and not active()["actions"], "Connecting the coach recorded help"
    pointer("click", "training-voice-disconnect")
    wait(lambda: "training-voice-connect" in listing() and "training-voice-disconnect" not in listing(), "Disconnect Coach did not end the session")
    time.sleep(SAVE_SETTLE)
    assert not active().get("recordedHelp"), "The coach's session recorded help"
    training_voice = True

    # Mixed practice: no topic before the answer; after it, the topic is shown.
    open_library()
    pointer("click", "training-entry-mixed-practice")
    wait(lambda: active() is not None and active()["entry"] == "mixed-practice", "Mixed practice did not start")
    show_details()
    assert "training-topic" not in listing(), "A mixed case showed its topic before the answer"
    pointer("click", "training-reveal")
    wait(lambda: "training-topic" in listing(), "The topic was not shown after the answer")
    mixed_topic_after_answer = True

    # A guided game: a developing move answered by the gentle opponent, then ended without a result.
    open_library()
    pointer("click", "training-variant-guided-games-short-start")
    wait(lambda: active() is not None and active()["entry"] == "guided-games" and not active()["actions"], "A guided short start did not begin")
    show_details()
    learner = active()["scenario"]["learner"]
    origin, target = ("b1", "c3") if learner == "w" else ("g8", "f6")
    pointer("drag-square", origin, target)
    wait(lambda: label(target).startswith(f"{target}, {COLOURS[learner]}, knight"), "The guided-game move did not land")
    wait(lambda: any("reply" in action for action in active()["actions"]), "The guided-game opponent did not answer", timeout=30)
    pointer("click", "training-end-game")
    wait(lambda: "Game ended · not counted" in listing(), "Ending the guided game did not show its neutral result")
    guided_game = True

    # Review this game opens the guided game itself as a draft review, never the practice game, and leads back here.
    time.sleep(SAVE_SETTLE)
    practice = saved().get("practice")
    pointer("click", "training-review-game")
    wait(lambda: "review-document-actions" in listing() and "Gentle opponent" in listing(), "Review this game did not open the guided game in Review")
    pointer("click", "Return to game")
    wait(lambda: "Game ended · not counted" in listing() and "training-review-game" in listing(), "Return to game did not lead back to the finished guided game")
    time.sleep(SAVE_SETTLE)
    assert saved().get("practice") == practice, "Reviewing a training game changed the practice game"
    guided_review = True

    # A related lesson opens without moving the course bookmark, and leads back to training.
    bookmark = (saved().get("course") or {}).get("lessonID")
    open_library()
    pointer("click", "training-lesson-simple-tactics-fork")
    wait(lambda: "Back to training" in listing() and "training-entry-save-your-piece" not in listing(), "The linked lesson did not open")
    pointer("click", "Back to training")
    wait(lambda: "training-entry-save-your-piece" in listing(), "Back to training did not return to the library")
    time.sleep(SAVE_SETTLE)
    assert (saved().get("course") or {}).get("lessonID") == bookmark, "Reading a linked lesson moved the course bookmark"
    lesson_link = True

    result = {"passed": True, "beginnerLibrary": beginner_library, "variantChip": variant_chip, "promotionCancelled": promotion_cancelled,
              "promotionChosen": promotion_chosen, "bridgeOpened": bridge_opened, "endingReply": ending_reply, "endingTakeBack": ending_take_back, "barAndCommandZTakeBack": bar_and_command_z_take_back, "levelPicker": level_picker, "trainingVoice": training_voice,
              "positionGamesListed": position_games_listed, "positionGameReply": position_game_reply,
              "mixedTopicAfterAnswer": mixed_topic_after_answer, "guidedGame": guided_game, "guidedReview": guided_review, "lessonLink": lesson_link}
    (evidence / "training-b-pointer-results.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
except Exception:
    if process is not None and process.poll() is None:
        (evidence / "training-b-pointer-failure-ax.txt").write_text(listing())
        subprocess.run(["screencapture", "-x", str(evidence / "training-b-pointer-failure.png")], check=False)
    raise
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
