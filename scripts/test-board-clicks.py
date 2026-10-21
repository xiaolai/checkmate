"""Silent test-host acceptance: a click on a legal practice square must play, with real pointer events.

Covers the ways a second click used to be lost: drift across a square edge, a first click on an inactive
window, a click while piece inspection is on, and clicks under the storage error banner. Also drives the learner's
right-button arrows and circles (B-11) and the control bar's glass buttons (D-35) with real clicks.
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
    """Black's reply follows the move in the drawer's move list, where each move is a button named "1. e4", "1... e5"."""
    number = white_move.split(".")[0]
    def check():
        shown = listing()
        return re.search(r"^AXButton: (.* \| )?" + re.escape(white_move) + r"( \||$)", shown, re.M) is not None and re.search(r"^AXButton: (.* \| )?" + re.escape(number) + r"\.\.\. \S+", shown, re.M) is not None
    return check


def toggle(name):
    """A toggle's value, or None when the drawer no longer shows it. Any other failure, such as a name that picks out
    several elements, fails the gate rather than reading as a closed drawer."""
    result = subprocess.run([str(helpers["pointer-helper"]), str(process.pid), "value", name], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip()
    if result.stderr.startswith("Not found"):
        return None
    raise AssertionError(f"Reading {name} failed: {result.stderr.strip() or result.returncode}")


def select(square):
    pointer("click-square", square)
    wait(lambda: "selected" in label(square), "Clicking " + square + " did not select it")


def bmp_pixels(path):
    """The pixels of an uncompressed 24- or 32-bit BMP from screencapture, as (width, height, [(b, g, r), ...])."""
    data = path.read_bytes()
    if data[:2] != b"BM":
        raise AssertionError(f"{path.name} is not a BMP")
    offset = int.from_bytes(data[10:14], "little")
    width, height = int.from_bytes(data[18:22], "little", signed=True), int.from_bytes(data[22:26], "little", signed=True)
    bits, compression = int.from_bytes(data[28:30], "little"), int.from_bytes(data[30:34], "little")
    if bits not in (24, 32) or compression not in (0, 3) or width <= 0 or height == 0:
        raise AssertionError(f"{path.name}: unsupported BMP ({bits} bits, compression {compression}, {width}x{height})")
    step, stride = bits // 8, (bits * width + 31) // 32 * 4
    pixels = [tuple(data[offset + row * stride + column * step:offset + row * stride + column * step + 3]) for row in range(abs(height)) for column in range(width)]
    return width, abs(height), pixels


def snapshot(square):
    """The pixels of one square, 2 points in from its edges so a neighbour's mark or antialiasing never counts."""
    x, y, w, h = frame("square-frame", square)
    path = evidence / ("board-clicks-" + square + ".bmp")
    subprocess.run(["screencapture", "-x", "-t", "bmp", "-R", f"{x + 2},{y + 2},{w - 4},{h - 4}", str(path)], check=True)
    return bmp_pixels(path)


def changed(before, after):
    """The fraction of a square's pixels that differ clearly between two snapshots of it."""
    if before[:2] != after[:2]:
        raise AssertionError(f"The square's snapshot changed size from {before[:2]} to {after[:2]}, so it cannot be compared")
    return sum(1 for a, b in zip(before[2], after[2]) if max(abs(x - y) for x, y in zip(a, b)) > 48) / len(before[2])


# An arrow's shaft crosses a square in a band about 9% of its width; a circle's ring covers about a quarter of its square.
DRAWN, CLEAR = 0.04, 0.005


def launch(existing=None):
    """Starts the automation app on a new data directory, or on `existing` to relaunch over what an earlier run saved."""
    global process, state
    state = existing or pathlib.Path(tempfile.mkdtemp(prefix="checkmate-board-clicks-state-"))
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
        pointer("click", "Sidebar")
    wait(lambda: "AXStaticText: The Pawn" in listing(), "Lesson sidebar did not open")
    if "practice-heading" not in listing():
        pointer("click", "Details")
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


def play_e4():
    select("e2")
    pointer("click-square", "e4")
    wait(lambda: label("e4").startswith("e4, White, pawn"), "e2-e4 did not play")
    wait(replied("1. e4"), "Stockfish did not reply after e2-e4")


def sketch_marks():
    """B-11 with real right-button events: a right-drag draws an arrow and a right-click a circle, without selecting or
    playing; a left click on the board, a position change and a quit each leave the board clean. The marks are read
    from the screen: an arrow from a2 to a4 crosses a3, and a circle on h3 rings it. Black's first reply never reaches
    a3 or h3, so their pixels change only with the marks."""
    marked = ("a3", "h3")
    clean = {}

    def draw():
        clean.update({square: snapshot(square) for square in marked})
        pointer("right-drag", "board-square-a2", "board-square-a4")
        wait(lambda: changed(clean["a3"], snapshot("a3")) >= DRAWN, "A right-drag from a2 to a4 did not draw an arrow across a3")
        pointer("right-click", "board-square-h3")
        wait(lambda: changed(clean["h3"], snapshot("h3")) >= DRAWN, "A right-click on h3 did not draw a circle")
        assert label("a2").startswith("a2, White, pawn") and "selected" not in label("a2"), "The right button selected or moved the a2 pawn: " + label("a2")

    def cleared(why):
        wait(lambda: all(changed(clean[square], snapshot(square)) <= CLEAR for square in marked), why)

    draw()
    pointer("click-square", "h5")
    cleared("A left click on h5 did not clear the marks")
    play_e4()
    draw()
    # Take back changes the position from the control bar, away from the board, so only the position change clears them.
    pointer("click", "bar-takeBack")
    wait(lambda: label("e2").startswith("e2, White, pawn"), "Take back did not restore e2")
    cleared("A position change (Take back) did not clear the marks")
    # Marks are never saved: drawn, then a real quit and a relaunch on the same data leave a clean board. Relaunching
    # activates the window with a click in the board's margin, which is not a square and so clears nothing.
    draw()
    pointer("shortcut", "12", "c")  # Command-Q
    process.wait(timeout=20)
    launch(state)
    cleared("Marks drawn before quitting came back after a relaunch, so they reached saved state")


def glass_control_bar():
    """D-35: the control bar's Liquid Glass buttons take real clicks: a text button, a prominent one, an icon button,
    and a menu button with its item."""
    pointer("click", "bar-tryMove")
    wait(lambda: "bar-returnToGame" in listing(), "A click on the Try a Move glass button did not open the preview")
    pointer("click", "bar-returnToGame")
    wait(lambda: "bar-returnToGame" not in listing() and "bar-tryMove" in listing(), "A click on the prominent Return to Game glass button did not close the preview")
    play_e4()
    pointer("click", "bar-takeBack")
    wait(lambda: label("e2").startswith("e2, White, pawn") and not label("e4").startswith("e4, White, pawn"), "A click on the Take back glass button did not take the move back")
    assert frame("square-frame", "e1")[1] > frame("square-frame", "e8")[1], "fixture: White plays from the bottom"
    pointer("click", "bar-more")
    wait(lambda: pointer("menu-open", "Flip Board") == "true", "A click on the More glass button did not open its menu")
    pointer("choose-menu-item", "Flip Board")
    wait(lambda: frame("square-frame", "e1")[1] < frame("square-frame", "e8")[1], "Flip Board from the More menu did not turn the board over")


scenarios = [drift_across_edge, first_click_on_inactive_window, inspection_does_not_block_moves, rank8_clickable_under_banner, sketch_marks, glass_control_bar]
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
