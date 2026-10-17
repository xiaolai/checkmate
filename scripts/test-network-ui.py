"""Silent test-host acceptance for Play on Network over loopback (LAN-play plan, Verification: network-ui).

Three automation instances on one test host — a host, a guest and a spectator — each with its own data folder, find
one another through a shared loopback folder (no Bonjour, so no local-network prompt). Every step is a real pointer
or key event: host, join, watch, play, a refused spectator click, a pending move, a disconnect and resume through the
automation-only hook, Review hiding engine output while the spectator browses a library game, a draw offer and its
decline, a resignation, and Review on both players. The guest runs in dark
appearance and the others in light, and each window is captured at the key moments.

Then agreed assistance (assistance plan, Verification: network-ui): that first game, without assistance, shows no Hint
button and P inspects nothing. A second pair plays under hints for both: the list shows the badge, the guest declines
the Accept sheet once and then accepts, presses Hint, the arrow appears on its board, plays the hinted move and the host
counts it; P on the host's board shows protection. A third pair plays a handicap, which both players see as one, and
the side without help gets no Hint button and no inspector.
"""
import json
import os
import re
import pathlib
import shutil
import tempfile
import time

import test_host
test_host.require("network UI acceptance")
from network_gate import Instance, compile_helpers, game_row, host_game, join, open_network, wait, wait_for  # noqa: E402

evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
helpers = compile_helpers(evidence)
shared = tempfile.mkdtemp(prefix="checkmate-network-ui-shared-")
results = {"steps": []}
ANALYSIS_HIDDEN = "Analysis is hidden during your network game"
KEY_P, KEY_ESCAPE = "35", "53"
started = time.monotonic()


def step(name):
    results["steps"].append({"step": name, "at": round(time.monotonic() - started, 2)})


def inspect(instance, square):
    """Selects a piece with a real click and presses P with the board focused: the square's VoiceOver label then says
    what protects it, if the inspector opened (assistance plan A1)."""
    instance.square(square)
    instance.run("pointer-helper", "key", KEY_P)
    time.sleep(0.5)
    return instance.label(square)


def suggested(instance):
    """The hint's arrow as the board's squares read it: (from, to), from the square labelled "suggested move to"."""
    for line in instance.listing().splitlines():
        found = re.search(r"AXButton: ([a-h][1-8]),.*suggested move to ([a-h][1-8])", line)
        if found:
            return found.group(1), found.group(2)
    return None


instances, failure = [], None
try:
    loopback = {"CHECKMATE_NETWORK_LOOPBACK_DIR": shared}
    host = Instance("host", evidence, helpers, environment=loopback)
    guest = Instance("guest", evidence, helpers, environment=loopback, arguments=["--dark-appearance"])
    watcher = Instance("spectator", evidence, helpers, environment=loopback)
    instances = [host, guest, watcher]
    for instance in instances:
        open_network(instance)
    step("three lobbies open")

    play_code, watch_code = host_game(host)
    host.capture("hosting")
    step("hosted")
    join(guest, "Ana's game", "Ben", play_code)
    join(watcher, "Ana's game", "Cy", watch_code, watching=True)
    wait(lambda: host.shows("Ben") and guest.shows("Ana") and watcher.shows("Ana"), "the guest and spectator never reached the game", 30)
    wait(lambda: host.shows("Cy is watching."), "the host never saw its spectator")
    step("joined and watching")

    host.square("e2")
    host.square("e4")
    for instance in instances:
        wait(lambda instance=instance: instance.label("e4").startswith("e4, White, pawn"), f"{instance.name} never showed 1. e4")
    step("host played e4")

    watcher.square("e7")
    wait(lambda: watcher.shows("You're watching"), "a spectator's click was not refused")
    assert watcher.label("e7").startswith("e7, Black, pawn"), "a spectator's click moved a piece"
    watcher.capture("watching")
    step("spectator click refused")

    # A pending move: the automation-only hook holds the guest's outgoing messages for 4 s, as a slow network would,
    # because loopback answers a move in milliseconds. The stall stays under the host's 6 s pong deadline, which it
    # would otherwise trip (the pongs wait too).
    guest.square("e7")
    guest.write_fault("stall 4")
    wait(guest.fault_taken, "the guest never took the stall hook")
    guest.square("e5")
    wait(lambda: guest.shows("Sending…"), "the guest's move did not show as pending", 3)
    assert not host.label("e5").startswith("e5, Black, pawn"), "a pending move reached the host early"
    guest.capture("pending")
    for instance in instances:
        wait(lambda instance=instance: instance.label("e5").startswith("e5, Black, pawn"), f"{instance.name} never showed 1... e5")
    wait(lambda: not guest.shows("Sending…"), "the pending notice stayed after the move was applied")
    step("pending move applied")

    # Drop and resume: the hook cuts the guest's connection and refuses reconnecting for 10 s (N13: the control
    # channel is untouched). The host holds the seat; the guest resumes it on its own.
    guest.write_fault("10")
    wait(guest.fault_taken, "the guest never took the disconnect hook")
    wait(lambda: guest.shows("Reconnecting to Ana's game…"), "the guest did not show that it is reconnecting")
    wait(lambda: host.shows("Ben is away."), "the host did not show the guest away", 10)
    guest.capture("reconnecting")
    host.capture("guest-away")
    wait(lambda: guest.shows("network-status") and not guest.shows("Reconnecting to"), "the guest never came back from the disconnect", 40)
    wait(lambda: host.shows("Your move."), "the host never saw the guest return", 20)
    step("dropped and resumed")
    host.square("g1")
    host.square("f3")
    for instance in instances:
        wait(lambda instance=instance: instance.label("f3").startswith("f3, White, knight"), f"{instance.name} never showed 2. Nf3")
    step("play continued after resuming")

    # Assistance plan A1 and A12 in a game without assistance: no Hint button, and P inspects nothing.
    assert not host.shows("network-hint-button") and not host.shows("network-terms"), "a game without assistance offered help"
    label = inspect(guest, "d7")
    assert "protected by" not in label, f"P inspected a piece in a game without assistance: {label}"
    guest.run("pointer-helper", "key", KEY_ESCAPE)
    step("no assistance: no Hint and no inspector")

    # D8 in Review: the spectator leaves the game's page for a library game; the review panes hide engine output while
    # it watches, and the game carries on meanwhile.
    watcher.click("Review game")
    wait(lambda: watcher.shows("library-search"), "the spectator did not reach the game library")
    if re.search(r"^AXPopUpButton: Show", watcher.listing(), re.M):
        watcher.run("pointer-helper", "select-popup", "library-scope", "Classics")
    else:
        watcher.click("Classics")
    row = "library-row-library:lasker-thomas"
    wait(lambda: watcher.shows(row), "the Classics segment did not list the King Hunt")
    watcher.click(row)
    wait(lambda: watcher.shows("AXButton: Save Review"), "a library row did not open in Review")
    wait(lambda: watcher.shows(ANALYSIS_HIDDEN), "Review showed engine output during the network game")
    watcher.capture("review-during-game")
    watcher.click("Play on Network")
    wait(lambda: watcher.shows("network-status") and watcher.label("f3").startswith("f3, White, knight"), "the spectator did not return to the game")
    step("review hid analysis during the game")

    guest.click("network-offer-draw")
    wait(lambda: host.shows("network-accept-draw"), "the host never saw the draw offer")
    host.capture("offer")
    host.click("network-decline-draw")
    wait(lambda: not host.shows("network-offer-received") and not guest.shows("network-offer-open"), "the declined offer stayed open")
    step("draw offered and declined")

    host.click("network-resign")
    wait(lambda: host.shows("network-resign-confirm"), "resigning did not ask first")
    host.click("network-resign-confirm")
    for instance in instances:
        wait(lambda instance=instance: instance.shows("network-review"), f"{instance.name} never offered Review", 20)
    for instance in instances:
        instance.capture("ended")
    step("host resigned")

    for instance in (guest, host):
        instance.click("network-review")
        wait(lambda instance=instance: instance.shows("review-document-actions"), f"{instance.name} did not open the game in Review")
        instance.capture("review")
    step("reviewed")
    for instance in instances:
        instance.stop()
    instances = []

    # Hints on request for both (A3, A6, A7, A12): a light host, a dark guest.
    host = Instance("assisted-host", evidence, helpers, environment=loopback)
    guest = Instance("assisted-guest", evidence, helpers, environment=loopback, arguments=["--dark-appearance"])
    instances = [host, guest]
    for instance in instances:
        open_network(instance)
    play_code, _ = host_game(host, "Dee", assistance="Hints on request")
    row = wait_for(lambda: game_row(guest, "Dee's game"), "the guest never listed Dee's game", 30)
    assert "Hints" in guest.line(row), f"the list showed no badge: {guest.line(row)}"
    guest.capture("assisted-lobby")
    guest.click(row)
    guest.type_into("network-name-field", "Eve")
    guest.type_into("network-code-field", play_code)
    guest.click("network-join-button")
    wait(lambda: guest.shows("network-accept-sheet"), "joining a game with assistance did not ask first")
    assert "allows hints on request for both players" in guest.listing(), "the Accept sheet did not say what is agreed"
    guest.capture("accept-sheet")
    guest.click("network-decline-assistance")
    wait(lambda: not guest.shows("network-accept-sheet") and guest.shows("network-join-button"), "Decline did not return to the list")
    assert not host.shows("Eve"), "declining still joined"
    step("assistance declined once")
    guest.click("network-join-button")
    wait(lambda: guest.shows("network-accept-sheet"), "the Accept sheet did not come back")
    guest.click("network-accept-assistance")
    wait(lambda: host.shows("Eve") and guest.shows("network-terms"), "accepting did not join the game", 30)
    assert host.shows("Assistance: hints on request for both players."), "the host did not show the terms"
    step("assistance accepted")

    host.square("e2")
    host.square("e4")
    wait(lambda: guest.label("e4").startswith("e4, White, pawn"), "the guest never showed 1. e4")
    wait(lambda: guest.shows("network-hint-button"), "the guest was not offered a hint on its move")
    guest.click("network-hint-button")
    arrow = wait_for(lambda: suggested(guest), "the hint's arrow never appeared", 20)
    assert guest.shows("network-hint-text"), "the hint was not described"
    assert suggested(host) is None, "the guest's hint reached the host's board"
    guest.capture("hint-dark")
    step("guest asked for a hint")
    guest.square(arrow[0])
    guest.square(arrow[1])
    wait(lambda: host.shows("Hints used: Dee 0 · Eve 1"), "the host did not count the guest's hint", 20)
    wait(lambda: guest.shows("Hints used: Dee 0 · Eve 1") and suggested(guest) is None, "the guest's board kept the hint after the move")
    step("the hinted move was counted")

    label = inspect(host, "d2")
    assert "protected by" in label, f"P did not show what protects d2: {label}"
    host.capture("inspector-light")
    host.run("pointer-helper", "key", KEY_ESCAPE)
    wait(lambda: "protected by" not in host.label("d2"), "Escape did not dismiss the inspector")
    step("P showed protection on the network board")
    for instance in instances:
        instance.stop()
    instances = []

    # A handicap (A2, A12): White gets hints, Black none; both see it called a handicap.
    host = Instance("handicap-host", evidence, helpers, environment=loopback)
    guest = Instance("handicap-guest", evidence, helpers, environment=loopback)
    instances = [host, guest]
    for instance in instances:
        open_network(instance)
    play_code, _ = host_game(host, "Fay", handicap=("Hints on request", "Off"))
    row = wait_for(lambda: game_row(guest, "Fay's game"), "the guest never listed Fay's game", 30)
    assert "Handicap" in guest.line(row), f"the list did not call it a handicap: {guest.line(row)}"
    # The earlier phases' hosts were stopped by a signal: their games went with them, as a Bonjour one would.
    stale = [title for title in ("Ana's game", "Dee's game") if game_row(guest, title)]
    assert not stale, f"a stopped instance's game is still listed: {stale}"
    join(guest, "Fay's game", "Gil", play_code, accept=True)
    wait(lambda: host.shows("Gil") and guest.shows("network-terms"), "the handicap game did not start", 30)
    for instance in instances:
        assert instance.shows("Handicap:"), f"{instance.name} did not call the terms a handicap"
    assert host.shows("network-hint-button"), "White, with hints, was not offered one"
    host.capture("handicap-host")
    host.square("e2")
    host.square("e4")
    wait(lambda: guest.label("e4").startswith("e4, White, pawn"), "the guest never showed 1. e4")
    assert not guest.shows("network-hint-button"), "Black, without help, was offered a hint"
    label = inspect(guest, "d7")
    assert "protected by" not in label, f"P inspected for the side without help: {label}"
    guest.capture("handicap-guest")
    step("handicap shown on both; the side without help gets none")
    results["passed"] = True
except Exception as error:
    failure = str(error)
    results["passed"] = False
    for instance in instances:
        try:
            (evidence / f"failure-{instance.name}-ax.txt").write_text(instance.listing())
            instance.capture("failure")
        except Exception as diagnostic:
            failure += f" (diagnostics for {instance.name} failed: {diagnostic})"
finally:
    for instance in instances:
        instance.stop()
    shutil.rmtree(shared, ignore_errors=True)
results["failure"] = failure
results["networkUI"] = results["passed"]
(evidence / "network-ui-results.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
if not results["passed"]:
    raise SystemExit("network-ui failed: " + (failure or "unknown"))
