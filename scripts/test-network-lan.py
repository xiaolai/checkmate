"""Two-Mac acceptance for Play on Network (LAN-play plan, Verification: network-lan; prerequisites bonjour-ready,
bonjour-ready-pair and lan-pair).

The test host hosts and runs a spectator; the LAN pair, reached over SSH (CHECKMATE_LAN_PAIR), joins. Both run the
automation app the test host built and signed, installed at its fixed path and opened through LaunchServices. Every
step is a real pointer or key event on the Mac it concerns: discover, join with the code, play to checkmate, Review on
both. The game is played under agreed assistance, hints on request for both (assistance plan, Verification:
network-lan): the pair accepts the terms before joining, each player asks for a hint on one move, every Mac counts
both hints, and Review on both Macs shows the Assistance line. The pair's connection is cut through the automation-only hook (a file written over SSH), so the control channel
is never cut (N13). A real cable or Wi-Fi loss is not automated. Evidence is kept per Mac, in test-host/ and pair/:
screenshots, permission states and connection logs.
"""
import json
import os
import pathlib
import shlex
import subprocess
import time

import test_host
test_host.require("two-Mac network acceptance")
from network_gate import (Instance, compile_helpers, host_game, install, join, on_pair, open_network, pair,  # noqa: E402
                          permission, root, wait, wait_for)

evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
local_evidence, pair_evidence = evidence / "test-host", evidence / "pair"
for folder in (local_evidence, pair_evidence):
    folder.mkdir(parents=True, exist_ok=True)
helpers = compile_helpers(evidence)
results = {"steps": []}
started = time.monotonic()
# The pair's own scratch folder, made private (mktemp -d is 0700) for each run: the access check and the helpers are
# copied into it and run from it, never from a shared, predictable /tmp path another account could plant first.
remote_scratch = None
# The pair's crash reports of the automation app, before the run, so a crash there fails the gate as one here does
# (run-gates.py checks only this Mac's reports). The app quits by signal, so only its report shows a fault.
CRASH_LISTING = "ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -E '^CheckmateNative.*[.]ips$' || true"
# The pair runs natively, without Rosetta's delayed reports; this is how long its ReportCrash is given after the run.
PAIR_CRASH_SETTLE_SECONDS = 15


def scratch():
    global remote_scratch
    if remote_scratch is None:
        remote_scratch = on_pair("mktemp -d /tmp/checkmate-network-lan.XXXXXX")
    return remote_scratch


def step(name):
    results["steps"].append({"step": name, "at": round(time.monotonic() - started, 2)})


def access_problem():
    """Why a Mac cannot be driven (a locked console, no Accessibility or no Screen Recording), checked before anything
    runs so the gate fails with that message instead of timing out."""
    probe = evidence / "host-access"
    subprocess.run(["xcrun", "swiftc", str(root / "Tools/host-access.swift"), "-o", str(probe)], check=True, capture_output=True)
    local = subprocess.run([str(probe)], capture_output=True, text=True)
    copy = f"{scratch()}/host-access"
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", str(probe), f"{pair()}:{shlex.quote(copy)}"], check=True, timeout=120)
    remote = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", pair(), shlex.quote(copy)], capture_output=True, text=True, timeout=60)
    results["access"] = {"testHost": local.stdout.strip(), "pair": remote.stdout.strip()}
    problems = [f"{where}: {run.stdout.strip() or run.stderr.strip()}" for where, run in (("the test host", local), ("the LAN pair", remote)) if run.returncode != 0]
    return "; ".join(problems) or None


def ask_hint(player):
    """Presses Hint on the player's own move and waits for the hint's words (A6)."""
    wait(lambda: player.shows("network-hint-button"), f"{player.name} was not offered a hint on its move", 20)
    player.click("network-hint-button")
    wait(lambda: player.shows("network-hint-text"), f"{player.name}'s hint never arrived", 20)
    player.capture("hint")


def pair_helpers():
    """The helpers built here, copied to the pair (it does not build)."""
    copies = {}
    for name, path in helpers.items():
        copies[name] = f"{scratch()}/{name}"
        subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", str(path), f"{pair()}:{shlex.quote(copies[name])}"], check=True, timeout=120)
    return copies


instances, failure = [], None
pair_reports = set(on_pair(CRASH_LISTING).split())
try:
    problem = access_problem()
    if problem:
        raise AssertionError("a Mac cannot be driven: " + problem)
    install()
    install(remote=True)
    # Each instance is registered for cleanup as soon as it starts, so one that fails to start leaves none running.
    host = Instance("host", local_evidence, helpers, mode="installed")
    instances.append(host)
    watcher = Instance("spectator", local_evidence, helpers, mode="installed")
    instances.append(watcher)
    guest = Instance("guest", pair_evidence, helpers, mode="pair", remote_helpers=pair_helpers())
    instances.append(guest)
    for instance in instances:
        open_network(instance)
    step("lobbies open on both Macs")

    play_code, watch_code = host_game(host, assistance="Hints on request")
    step("hosted on the test host, hints on request for both")
    join(guest, "Ana's game", "Ben", play_code, accept="Ana's game allows hints on request for both players.")
    wait(lambda: host.shows("Ben") and guest.shows("Ana"), "the pair never reached the game", 40)
    for instance in (host, guest):
        wait(lambda instance=instance: instance.shows("Assistance: hints on request for both players."), f"{instance.name} did not show the agreed terms")
    step("the pair accepted the terms and joined")
    join(watcher, "Ana's game", "Cy", watch_code, watching=True)
    wait(lambda: host.shows("Cy is watching."), "the host never saw its spectator")
    results["permission"] = {instance.name: permission(instance) for instance in instances}
    for instance in instances:
        instance.capture("joined")
    step("the pair joined with the code; a spectator watches")

    host.square("f2")
    host.square("f3")
    wait(lambda: guest.label("f3").startswith("f3, White, pawn"), "the pair never showed 1. f3")
    # A hint shown counts whether or not it is followed (A7): the pair asks, then plays the scripted move.
    ask_hint(guest)
    guest.square("e7")
    guest.square("e5")
    for instance in (host, watcher):
        wait(lambda instance=instance: instance.label("e5").startswith("e5, Black, pawn"), f"{instance.name} never showed 1... e5")
    for instance in instances:
        wait(lambda instance=instance: instance.shows("Hints used: Ana 0 · Ben 1"), f"{instance.name} did not count the pair's hint", 20)
    step("first moves crossed the LAN; the pair's hint counted on every Mac")

    # The disconnect hook on the pair cuts its game connection and refuses reconnecting for 10 s; SSH is untouched.
    guest.write_fault("10")
    wait(guest.fault_taken, "the pair never took the disconnect hook")
    wait(lambda: guest.shows("Reconnecting to Ana's game…"), "the pair did not show that it is reconnecting")
    wait(lambda: host.shows("Ben is away."), "the host did not show the pair away", 10)
    guest.capture("reconnecting")
    host.capture("guest-away")
    wait(lambda: not guest.shows("Reconnecting to"), "the pair never came back from the disconnect", 40)
    wait(lambda: host.shows("Your move."), "the host never saw the pair return", 20)
    step("the pair dropped and resumed")

    ask_hint(host)
    host.square("g2")
    host.square("g4")
    for instance in instances:
        wait(lambda instance=instance: instance.shows("Hints used: Ana 1 · Ben 1"), f"{instance.name} did not count the host's hint", 20)
    wait(lambda: guest.label("g4").startswith("g4, White, pawn"), "the pair never showed 2. g4")
    guest.square("d8")
    guest.square("h4")
    for instance in instances:
        wait(lambda instance=instance: instance.shows("network-review"), f"{instance.name} never saw the game end", 20)
        instance.capture("ended")
    results["result"] = {instance.name: instance.line("network-status") for instance in instances}
    # Review is offered for an interrupted game too, so the result itself is checked: Black's queen mates on h4.
    for instance in instances:
        assert instance.read_label("h4").startswith("h4, Black, queen"), f"{instance.name} does not show the mating queen on h4"
        assert "Checkmate" in (results["result"][instance.name] or ""), f"{instance.name} did not end in checkmate: {results['result'][instance.name]}"
    step("played to checkmate")

    for instance in (guest, host):
        instance.click("network-review")
        wait(lambda instance=instance: instance.shows("review-document-actions"), f"{instance.name} did not open the game in Review")
        line = wait_for(lambda instance=instance: instance.line("review-assistance"), f"{instance.name} showed no Assistance line in Review")
        assert "White: Hints on request; Black: Hints on request" in line, f"{instance.name} reviewed the wrong terms: {line}"
        instance.capture("review")
    results["reviewAssistance"] = True
    step("reviewed on both Macs, with the agreed assistance")
    results["passed"] = True
except Exception as error:
    failure = str(error)
    results["passed"] = False
    for instance in instances:
        try:
            (instance.evidence / f"failure-{instance.name}-ax.txt").write_text(instance.listing())
            instance.capture("failure")
            results.setdefault("permission", {}).setdefault(instance.name, permission(instance))
        except Exception as diagnostic:
            failure += f" (diagnostics for {instance.name} failed: {diagnostic})"
finally:
    # A diagnostic that fails never skips an instance's stop, nor the rest of the cleanup; its failure is kept.
    for instance in instances:
        try:
            instance.connection_log()
        except Exception as diagnostic:
            results.setdefault("cleanupErrors", []).append(f"{instance.name} connection log: {diagnostic}")
        finally:
            instance.stop()
    if remote_scratch:
        on_pair(f"rm -rf {shlex.quote(remote_scratch)}", check=False)
    time.sleep(PAIR_CRASH_SETTLE_SECONDS if instances else 0)
    crashed = sorted(set(on_pair(CRASH_LISTING, check=False).split()) - pair_reports)
    results["pairCrashReports"] = crashed
    if crashed and results["passed"]:
        results["passed"] = False
        failure = f"the app crashed on the LAN pair: {', '.join(crashed)}"
results["failure"] = failure
results["networkLAN"] = results["passed"]
(evidence / "network-lan-results.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
if not results["passed"]:
    raise SystemExit("network-lan failed: " + (failure or "unknown"))
