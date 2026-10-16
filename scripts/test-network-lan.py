"""Two-Mac acceptance for Play on Network (LAN-play plan, Verification: network-lan; prerequisites bonjour-ready,
bonjour-ready-pair and lan-pair).

The test host hosts and runs a spectator; the LAN pair, reached over SSH (CHECKMATE_LAN_PAIR), joins. Both run the
automation app the test host built and signed, installed at its fixed path and opened through LaunchServices. Every
step is a real pointer or key event on the Mac it concerns: discover, join with the code, play to checkmate, Review on
both. The pair's connection is cut through the automation-only hook (a file written over SSH), so the control channel
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
                          permission, root, wait)

evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
local_evidence, pair_evidence = evidence / "test-host", evidence / "pair"
for folder in (local_evidence, pair_evidence):
    folder.mkdir(parents=True, exist_ok=True)
helpers = compile_helpers(evidence)
results = {"steps": []}
started = time.monotonic()


def step(name):
    results["steps"].append({"step": name, "at": round(time.monotonic() - started, 2)})


def access_problem():
    """Why a Mac cannot be driven (a locked console, no Accessibility or no Screen Recording), checked before anything
    runs so the gate fails with that message instead of timing out."""
    probe = evidence / "host-access"
    subprocess.run(["xcrun", "swiftc", str(root / "Tools/host-access.swift"), "-o", str(probe)], check=True, capture_output=True)
    local = subprocess.run([str(probe)], capture_output=True, text=True)
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", str(probe), f"{pair()}:/tmp/checkmate-host-access"], check=True, timeout=120)
    remote = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", pair(), "/tmp/checkmate-host-access"], capture_output=True, text=True, timeout=60)
    results["access"] = {"testHost": local.stdout.strip(), "pair": remote.stdout.strip()}
    problems = [f"{where}: {run.stdout.strip() or run.stderr.strip()}" for where, run in (("the test host", local), ("the LAN pair", remote)) if run.returncode != 0]
    return "; ".join(problems) or None


def pair_helpers():
    """The helpers built here, copied to the pair (it does not build)."""
    copies = {}
    for name, path in helpers.items():
        copies[name] = f"/tmp/checkmate-network-lan-{name}"
        subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", str(path), f"{pair()}:{shlex.quote(copies[name])}"], check=True, timeout=120)
    return copies


instances, failure = [], None
try:
    problem = access_problem()
    if problem:
        raise AssertionError("a Mac cannot be driven: " + problem)
    install()
    install(remote=True)
    host = Instance("host", local_evidence, helpers, mode="installed")
    watcher = Instance("spectator", local_evidence, helpers, mode="installed")
    guest = Instance("guest", pair_evidence, helpers, mode="pair", remote_helpers=pair_helpers())
    instances = [host, watcher, guest]
    for instance in instances:
        open_network(instance)
    step("lobbies open on both Macs")

    play_code, watch_code = host_game(host)
    step("hosted on the test host")
    join(guest, "Ana's game", "Ben", play_code)
    wait(lambda: host.shows("Ben") and guest.shows("Ana"), "the pair never reached the game", 40)
    join(watcher, "Ana's game", "Cy", watch_code, watching=True)
    wait(lambda: host.shows("Cy is watching."), "the host never saw its spectator")
    results["permission"] = {instance.name: permission(instance) for instance in instances}
    for instance in instances:
        instance.capture("joined")
    step("the pair joined with the code; a spectator watches")

    host.square("f2")
    host.square("f3")
    wait(lambda: guest.label("f3").startswith("f3, White, pawn"), "the pair never showed 1. f3")
    guest.square("e7")
    guest.square("e5")
    for instance in (host, watcher):
        wait(lambda instance=instance: instance.label("e5").startswith("e5, Black, pawn"), f"{instance.name} never showed 1... e5")
    step("first moves crossed the LAN")

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

    host.square("g2")
    host.square("g4")
    wait(lambda: guest.label("g4").startswith("g4, White, pawn"), "the pair never showed 2. g4")
    guest.square("d8")
    guest.square("h4")
    for instance in instances:
        wait(lambda instance=instance: instance.shows("network-review"), f"{instance.name} never saw the game end", 20)
        instance.capture("ended")
    results["result"] = {instance.name: instance.line("network-status") for instance in instances}
    step("played to checkmate")

    for instance in (guest, host):
        instance.click("network-review")
        wait(lambda instance=instance: instance.shows("review-document-actions"), f"{instance.name} did not open the game in Review")
        instance.capture("review")
    step("reviewed on both Macs")
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
    for instance in instances:
        instance.connection_log()
        instance.stop()
    if instances:
        on_pair("rm -f /tmp/checkmate-network-lan-* /tmp/checkmate-host-access", check=False)
results["failure"] = failure
results["networkLAN"] = results["passed"]
(evidence / "network-lan-results.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
if not results["passed"]:
    raise SystemExit("network-lan failed: " + (failure or "unknown"))
