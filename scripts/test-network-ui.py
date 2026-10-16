"""Silent test-host acceptance for Play on Network over loopback (LAN-play plan, Verification: network-ui).

Three automation instances on one test host — a host, a guest and a spectator — each with its own data folder, find
one another through a shared loopback folder (no Bonjour, so no local-network prompt). Every step is a real pointer
or key event: host, join, watch, play, a refused spectator click, a pending move, a disconnect and resume through the
automation-only hook, Review hiding engine output while the spectator browses a library game, a draw offer and its
decline, a resignation, and Review on both players. The guest runs in dark
appearance and the others in light, and each window is captured at the key moments.
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
from network_gate import Instance, compile_helpers, host_game, join, open_network, wait  # noqa: E402

evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
helpers = compile_helpers(evidence)
shared = tempfile.mkdtemp(prefix="checkmate-network-ui-shared-")
results = {"steps": []}
ANALYSIS_HIDDEN = "Analysis is hidden during your network game"
started = time.monotonic()


def step(name):
    results["steps"].append({"step": name, "at": round(time.monotonic() - started, 2)})


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
