"""Test-host acceptance for Play on Network over real Bonjour (LAN-play plan, Verification: network-bonjour).

Two automation instances, the app installed at its one fixed path and opened through LaunchServices with the stable
local identity (prerequisite bonjour-ready, from scripts/prepare-bonjour.sh), find each other through Bonjour and the
real TLS transport. Every step is a real pointer or key event: host, discover, join with the code, play, resign, and
Review on both. Each instance's local-network permission state is recorded with the readiness evidence it ran under.
"""
import json
import os
import pathlib
import time

import test_host
test_host.require("network Bonjour acceptance")
from network_gate import (Instance, cleanup_failure, compile_helpers, host_game, install, join, open_network, permission,  # noqa: E402
                          stop_all, wait)

evidence = pathlib.Path(os.environ["CHECKMATE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
helpers = compile_helpers(evidence)
ready = pathlib.Path.home() / ".config/checkmate/bonjour-ready.json"
results = {"steps": [], "bonjourReady": json.loads(ready.read_text()) if ready.exists() else None}
started = time.monotonic()


def step(name):
    results["steps"].append({"step": name, "at": round(time.monotonic() - started, 2)})


instances, failure = [], None
try:
    install()
    host = Instance("host", evidence, helpers, mode="installed")
    guest = Instance("guest", evidence, helpers, mode="installed")
    instances = [host, guest]
    for instance in instances:
        open_network(instance)
    step("two lobbies open")

    play_code, _ = host_game(host)
    step("hosted")
    join(guest, "Ana's game", "Ben", play_code)
    wait(lambda: host.shows("Ben") and guest.shows("Ana"), "the guest never reached the game over Bonjour", 30)
    results["permission"] = {instance.name: permission(instance) for instance in instances}
    for instance in instances:
        instance.capture("joined")
    step("discovered and joined over Bonjour")

    host.square("e2")
    host.square("e4")
    wait(lambda: guest.label("e4").startswith("e4, White, pawn"), "the guest never showed 1. e4")
    guest.square("e7")
    guest.square("e5")
    wait(lambda: host.label("e5").startswith("e5, Black, pawn"), "the host never showed 1... e5")
    step("played over Bonjour")

    guest.click("network-resign")
    wait(lambda: guest.shows("network-resign-confirm"), "resigning did not ask first")
    guest.click("network-resign-confirm")
    for instance in instances:
        wait(lambda instance=instance: instance.shows("network-review"), f"{instance.name} never offered Review", 20)
    step("guest resigned")
    for instance in instances:
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
            (evidence / f"failure-{instance.name}-ax.txt").write_text(instance.raw_listing())
            instance.capture("failure")
            results.setdefault("permission", {}).setdefault(instance.name, permission(instance))
        except Exception as diagnostic:
            failure += f" (diagnostics for {instance.name} failed: {diagnostic})"
finally:
    cleanup_errors = stop_all(instances, results, logs=True)
failure = cleanup_failure(results, failure, cleanup_errors)
results["failure"] = failure
results["networkBonjour"] = results["passed"]
(evidence / "network-bonjour-results.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
if not results["passed"]:
    raise SystemExit("network-bonjour failed: " + (failure or "unknown"))
