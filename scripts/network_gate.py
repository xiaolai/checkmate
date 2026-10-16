"""Shared driving for the Play on Network gates (LAN-play plan, Verification: network-ui, network-bonjour, network-lan).

An Instance is one running Checkmate automation app with its own data folder, driven only by real pointer and key
events through the repository's helpers. It runs in one of three ways:
  - direct: the binary launched from this process, for loopback runs (no local-network privacy applies);
  - installed: the app installed at one fixed path in ~/Applications, registered with LaunchServices and opened
    through it, so macOS treats it as the app it is (spike (c): local-network permission is per bundle ID and is
    enforced only for registered executables);
  - on the LAN pair: the same, over SSH to the host named by CHECKMATE_LAN_PAIR.
"""
import os
import pathlib
import re
import shlex
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
HELPERS = ("pointer-helper", "ax-helper", "board-click-helper")
INSTALLED = pathlib.Path.home() / "Applications" / "CheckmateAutomation.app"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
AUTOMATION_BUNDLE = "ai.xiaolai.checkmate.native-automation"
BUILT = root / "build/CheckmateAutomation.app"


def wait(predicate, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.25)
    raise AssertionError(message)


def wait_for(produce, message, timeout=15):
    """The first value `produce` returns that is not None, polled until `timeout`."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = produce()
        if value is not None:
            return value
        time.sleep(0.25)
    raise AssertionError(message)


def compile_helpers(evidence):
    helpers = {}
    for name in HELPERS:
        helpers[name] = evidence / name
        subprocess.run(["xcrun", "swiftc", str(root / "Tools" / (name + ".swift")), "-o", str(helpers[name])], check=True)
    return helpers


def pair():
    name = os.environ.get("CHECKMATE_LAN_PAIR", "").strip()
    if not name:
        raise SystemExit("No LAN pair configured: set CHECKMATE_LAN_PAIR in the test host's shell profile")
    return name


def on_pair(command, check=True, timeout=60):
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", pair(), command], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        raise AssertionError(f"on the LAN pair, {command!r} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def registered_paths(remote=False):
    """Every path LaunchServices holds for the automation bundle ID."""
    dump = on_pair(f"{LSREGISTER} -dump 2>/dev/null", check=False) if remote else subprocess.run([LSREGISTER, "-dump"], capture_output=True, text=True).stdout
    paths, current = [], None
    for line in dump.splitlines():
        if line.startswith("path:"):
            current = re.sub(r"\s*\(0x[0-9a-f]+\)$", "", line[5:].strip())
        elif re.match(r"^identifier:\s+" + re.escape(AUTOMATION_BUNDLE) + r"$", line.strip()) and current:
            paths.append(current)
    return sorted(set(paths))


def install(remote=False, source=BUILT):
    """Installs a copy of the built app, signed with the stable local identity (D12), at the one fixed path and
    registers it, unregistering every other copy of the bundle ID first, so the only executable macOS associates with
    the automation app is this one (spike (c)). The build folder's copy is left as built."""
    target = INSTALLED if not remote else "~/Applications/CheckmateAutomation.app"
    stage = pathlib.Path(tempfile.mkdtemp(prefix="checkmate-install-")) / source.name
    try:
        _install(remote, source, stage)
    finally:
        subprocess.run(["rm", "-rf", str(stage.parent)], check=False)
        if remote:
            on_pair("rm -rf /tmp/checkmate-automation-app /tmp/checkmate-automation-app.tgz", check=False)
    time.sleep(2)  # nehelper refreshes the registered executable's UUIDs after the registration notice
    return target


def _install(remote, source, stage):
    subprocess.run(["ditto", str(source), str(stage)], check=True)
    subprocess.run(["bash", str(root / "scripts/automation-identity.sh"), "sign", str(stage)], check=True, capture_output=True)
    if remote:
        archive = stage.parent / "app.tgz"
        subprocess.run(["tar", "czf", str(archive), "-C", str(stage.parent), stage.name], check=True)
        subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", str(archive), f"{pair()}:/tmp/checkmate-automation-app.tgz"], check=True, timeout=600)
        for path in registered_paths(remote=True):
            on_pair(f"{LSREGISTER} -u {shlex.quote(path)}", check=False)
        on_pair("rm -rf /tmp/checkmate-automation-app ~/Applications/CheckmateAutomation.app && mkdir -p ~/Applications /tmp/checkmate-automation-app"
                f" && tar xzf /tmp/checkmate-automation-app.tgz -C /tmp/checkmate-automation-app && ditto /tmp/checkmate-automation-app/{stage.name} ~/Applications/CheckmateAutomation.app"
                f" && rm -rf /tmp/checkmate-automation-app /tmp/checkmate-automation-app.tgz && {LSREGISTER} -f ~/Applications/CheckmateAutomation.app")
    else:
        for path in registered_paths():
            if path != str(INSTALLED):
                subprocess.run([LSREGISTER, "-u", path], check=False, capture_output=True)
        INSTALLED.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["rm", "-rf", str(INSTALLED)], check=True)
        subprocess.run(["ditto", str(stage), str(INSTALLED)], check=True)
        subprocess.run([LSREGISTER, "-f", str(INSTALLED)], check=True)


class Instance:
    """One automation app instance. `mode` is "direct", "installed" or "pair"."""

    def __init__(self, name, evidence, helpers, mode="direct", environment=None, arguments=(), remote_helpers=None):
        self.name, self.evidence, self.mode = name, evidence, mode
        self.helpers = remote_helpers if mode == "pair" else helpers
        environment = dict(environment or {})
        if mode == "pair":
            self.data = on_pair("mktemp -d /tmp/checkmate-network-pair.XXXXXX")
        else:
            self.data = tempfile.mkdtemp(prefix=f"checkmate-network-{name}-")
        self.fault = f"{self.data}/fault"
        self.started = time.monotonic()
        environment["CHECKMATE_NETWORK_FAULT_FILE"] = self.fault
        app_arguments = ["--automation", "--data-dir", self.data, *arguments]
        if mode == "direct":
            env = {key: value for key, value in os.environ.items() if key != "CHECKMATE_AUTOMATION"}
            env.update(environment)
            self.process = subprocess.Popen([str(BUILT / "Contents/MacOS/CheckmateNative"), *app_arguments], env=env,
                                            stdout=open(evidence / f"app-{name}.log", "w"), stderr=subprocess.STDOUT)
            self.pid = self.process.pid
            return
        # Opened through LaunchServices, so the app runs as the registered app in the Aqua session.
        env_flags = [part for key, value in environment.items() for part in ("--env", f"{key}={value}")]
        command = ["open", "-n", *env_flags, "-a", "~/Applications/CheckmateAutomation.app" if mode == "pair" else str(INSTALLED), "--args", *app_arguments]
        self.process = None
        try:
            if mode == "pair":
                on_pair(" ".join(shlex.quote(part) if not part.startswith("~/") else part for part in command))
            else:
                subprocess.run(command, check=True, timeout=60)
            self.pid = wait_for(self._find_pid, f"{name} never started", 30)
        except (AssertionError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
            # No instance reaches the caller to be stopped, so whatever did start, and its data, go now.
            pattern = shlex.quote("data-dir " + self.data)
            if mode == "pair":
                on_pair(f"pkill -f {pattern}; rm -rf {shlex.quote(self.data)}", check=False)
            else:
                subprocess.run(["pkill", "-f", "data-dir " + self.data], check=False)
                subprocess.run(["rm", "-rf", self.data], check=False)
            raise

    def _find_pid(self):
        pattern = "data-dir " + self.data
        if self.mode == "pair":
            text = on_pair(f"pgrep -n -f {shlex.quote(pattern)}", check=False)
        else:
            text = subprocess.run(["pgrep", "-n", "-f", pattern], capture_output=True, text=True).stdout.strip()
        return int(text) if text.isdigit() else None

    def run(self, helper, *arguments, check=True, timeout=60):
        """One helper call, bounded so a stalled helper or SSH connection fails the gate instead of hanging it."""
        if self.mode == "pair":
            command = " ".join(shlex.quote(part) for part in [self.helpers[helper], str(self.pid), *arguments])
            call = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", pair(), command]
        else:
            call = [str(self.helpers[helper]), str(self.pid), *arguments]
        try:
            result = subprocess.run(call, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise AssertionError(f"{self.name}: {helper} {' '.join(arguments)} did not finish within {timeout} s") from None
        if check and result.returncode != 0:
            raise AssertionError(f"{self.name}: {helper} {' '.join(arguments)} failed: {result.stderr.strip() or result.stdout.strip()}")
        return result.stdout.strip()

    def listing(self):
        return self.run("ax-helper", "list", check=False)

    def shows(self, text):
        return text in self.listing()

    def line(self, identifier):
        """The accessibility listing's line for one element, or None."""
        return next((line for line in self.listing().splitlines() if identifier in line), None)

    def activate(self):
        for _ in range(3):
            self.run("board-click-helper", "activate", check=False)
            try:
                wait(lambda: self.run("board-click-helper", "active", check=False) == "true", f"{self.name} did not become active", 5)
                return
            except AssertionError:
                continue
        raise AssertionError(f"{self.name} did not become active")

    def click(self, target):
        self.activate()
        self.run("pointer-helper", "click", target)

    def square(self, square):
        self.activate()
        self.run("pointer-helper", "click-square", square)

    def label(self, square):
        return self.run("pointer-helper", "label", square, check=False)

    def type_into(self, field, text):
        """Clicks the field, selects whatever it holds with Command-A, and types over it."""
        self.click(field)
        self.run("pointer-helper", "shortcut", "0", "c")
        self.run("pointer-helper", "type", text)

    def write_fault(self, text):
        if self.mode == "pair":
            on_pair(f"printf %s {shlex.quote(text)} > {shlex.quote(self.fault)}")
        else:
            pathlib.Path(self.fault).write_text(text)

    def fault_taken(self):
        if self.mode == "pair":
            return on_pair(f"test -e {shlex.quote(self.fault)} && echo yes || echo no", check=False) == "no"
        return not pathlib.Path(self.fault).exists()

    def capture(self, name):
        target = self.evidence / f"{name}-{self.name}.png"
        if self.mode == "pair":
            remote = f"/tmp/checkmate-network-shot-{os.getpid()}.png"
            on_pair(f"screencapture -x {remote}", check=False)
            try:
                subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", f"{pair()}:{remote}", str(target)], check=False, timeout=60)
            except subprocess.TimeoutExpired:
                print(f"{self.name}: the screenshot could not be copied within 60 s")
        else:
            subprocess.run(["screencapture", "-x", str(target)], check=False)

    def connection_log(self):
        """This instance's network and app log lines since it started, kept with its evidence."""
        predicate = f'processID == {self.pid} AND (subsystem == "com.apple.network" OR subsystem == "ai.xiaolai.checkmate")'
        command = ["/usr/bin/log", "show", "--style", "compact", "--last", f"{int(time.monotonic() - self.started) + 30}s", "--predicate", predicate]
        try:
            if self.mode == "pair":
                text = on_pair(" ".join(shlex.quote(part) for part in command), check=False, timeout=120)
            else:
                text = subprocess.run(command, capture_output=True, text=True, timeout=120).stdout
        except subprocess.TimeoutExpired:
            text = "(the log could not be read within 120 s)"
        (self.evidence / f"connection-{self.name}.log").write_text(text)

    def stop(self):
        """Stops the instance and removes its data; a stalled SSH connection is reported, never left to end cleanup."""
        try:
            self._stop()
        except subprocess.TimeoutExpired as error:
            print(f"{self.name} may still be running: stopping it timed out ({error})")

    def _stop(self):
        if self.mode == "direct":
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        elif self.mode == "pair":
            on_pair(f"kill {self.pid} 2>/dev/null; sleep 2; kill -9 {self.pid} 2>/dev/null; rm -rf {shlex.quote(self.data)}", check=False)
        else:
            subprocess.run(["kill", str(self.pid)], check=False)
            time.sleep(2)
            subprocess.run(["kill", "-9", str(self.pid)], check=False, capture_output=True)
        if self.mode != "pair":
            subprocess.run(["rm", "-rf", self.data], check=False)


def permission(instance):
    """The local-network permission state the instance shows: "denied" when it asks for access (D13), else "allowed"
    (the spike showed a silent refusal never reaches a live game, so a game that went live was allowed)."""
    return "denied" if instance.shows("network-access-needed") or instance.shows("network-permission-sheet") else "allowed"


def code(instance, identifier):
    """A code as VoiceOver reads it from the host's pane ("Play code, E M 1 A, M V 2 Y"): eight symbols."""
    for line in instance.listing().splitlines():
        if identifier in line:
            found = re.search(r"code, ([0-9A-Z ,]+?) \|", line)
            symbols = re.sub(r"[ ,]", "", found.group(1)) if found else ""
            if len(symbols) == 8:
                return symbols
    raise AssertionError(f"{instance.name} shows no readable {identifier}")


def open_network(instance):
    wait(lambda: instance.label("e2").startswith("e2, White, pawn"), f"{instance.name} never showed its board", 40)
    if not instance.shows("Play on Network"):
        instance.click("Toggle Sidebar")
    wait(lambda: instance.shows("Play on Network"), f"{instance.name} has no Play on Network row")
    instance.click("Play on Network")
    wait(lambda: instance.shows("network-host-button"), f"{instance.name} did not open the network lobby")


def host_game(host, name="Ana"):
    host.click("network-host-button")
    wait(lambda: host.shows("network-host-sheet"), "the host sheet did not open")
    host.type_into("network-host-name", name)
    host.click("network-host-start")
    wait(lambda: host.shows("network-play-code"), "hosting did not start")
    return code(host, "network-play-code"), code(host, "network-watch-code")


def game_row(instance, title):
    """The identifier of the lobby row whose text starts with `title` ("Ana's game · K7QD")."""
    for line in instance.listing().splitlines():
        if title in line:
            found = re.search(r"(network-game-[0-9A-Z]{26})", line)
            if found:
                return found.group(1)
    return None


def join(instance, title, name, typed, watching=False, timeout=30):
    row = wait_for(lambda: game_row(instance, title), f"{instance.name} never listed {title}", timeout)
    instance.click(row)
    instance.type_into("network-name-field", name)
    instance.type_into("network-code-field", typed)
    instance.click("network-watch-button" if watching else "network-join-button")
