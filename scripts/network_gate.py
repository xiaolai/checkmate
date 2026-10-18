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
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
HELPERS = ("pointer-helper", "ax-helper", "board-click-helper")
INSTALLED = pathlib.Path.home() / "Applications" / "CheckmateAutomation.app"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
AUTOMATION_BUNDLE = "ai.xiaolai.checkmate.native-automation"
BUILT = root / "build/CheckmateAutomation.app"


def wait(predicate, message, timeout=15):
    """Polls `predicate` until it holds. An observation that fails (an unreadable listing raises AssertionError) is
    "not yet", and the last such failure is named if the wait times out."""
    wait_for(lambda: True if predicate() else None, message, timeout)


def wait_for(produce, message, timeout=15):
    """The first value `produce` returns that is not None, polled until `timeout`."""
    deadline, unreadable = time.monotonic() + timeout, None
    while time.monotonic() < deadline:
        try:
            value = produce()
        except AssertionError as error:
            value, unreadable = None, error
        if value is not None:
            return value
        time.sleep(0.25)
    raise AssertionError(message + (f" (last observation failed: {unreadable})" if unreadable else ""))


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


def process_pattern(data):
    """The pgrep/pkill pattern for the app started with `--data-dir data`. Its first letter is bracketed, so the shell
    on the pair running `pkill -f` (whose own command line holds the pattern text) never matches it and kills itself."""
    return "[d]ata-dir " + data


def private_remote_dir(prefix):
    """A fresh directory on the pair that only this account can use: mktemp -d makes it 0700, and it is checked to be a
    real directory owned by this account with that mode before anything is copied into it, so nothing another account
    planted in /tmp is ever extracted, run or launched."""
    path = on_pair(f"mktemp -d /tmp/{prefix}.XXXXXX")
    quoted = shlex.quote(path)
    on_pair(f"test -d {quoted} && test ! -L {quoted} && test -O {quoted} && test \"$(stat -f %Lp {quoted})\" = 700")
    return path


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
    remote_stage = None
    try:
        remote_stage = private_remote_dir("checkmate-install") if remote else None
        _install(remote, source, stage, remote_stage)
    finally:
        subprocess.run(["rm", "-rf", str(stage.parent)], check=False)
        if remote_stage:
            on_pair(f"rm -rf {shlex.quote(remote_stage)}", check=False)
    time.sleep(2)  # nehelper refreshes the registered executable's UUIDs after the registration notice
    return target


def _install(remote, source, stage, remote_stage):
    subprocess.run(["ditto", str(source), str(stage)], check=True)
    subprocess.run(["bash", str(root / "scripts/automation-identity.sh"), "sign", str(stage)], check=True, capture_output=True)
    if remote:
        archive = stage.parent / "app.tgz"
        subprocess.run(["tar", "czf", str(archive), "-C", str(stage.parent), stage.name], check=True)
        # Copied, extracted and installed only inside the pair's private directory (row 60/80 of the audit).
        remote_archive, extracted = f"{remote_stage}/app.tgz", f"{remote_stage}/app"
        subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", str(archive), f"{pair()}:{shlex.quote(remote_archive)}"], check=True, timeout=600)
        for path in registered_paths(remote=True):
            on_pair(f"{LSREGISTER} -u {shlex.quote(path)}", check=False)
        on_pair(f"rm -rf ~/Applications/CheckmateAutomation.app && mkdir -p ~/Applications {shlex.quote(extracted)}"
                f" && tar xzf {shlex.quote(remote_archive)} -C {shlex.quote(extracted)} && ditto {shlex.quote(extracted + '/' + stage.name)} ~/Applications/CheckmateAutomation.app"
                f" && {LSREGISTER} -f ~/Applications/CheckmateAutomation.app")
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
            log = None
            try:
                log = open(evidence / f"app-{name}.log", "w")
                self.process = subprocess.Popen([str(BUILT / "Contents/MacOS/CheckmateNative"), *app_arguments], env=env, stdout=log, stderr=subprocess.STDOUT)
            except BaseException:
                # No instance reaches the caller to be stopped, so its data goes now.
                if log:
                    log.close()
                subprocess.run(["rm", "-rf", self.data], check=False)
                raise
            log.close()  # the child holds its own descriptor
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
            if mode == "pair":
                on_pair(f"pkill -f {shlex.quote(process_pattern(self.data))}", check=False)
                on_pair(f"rm -rf {shlex.quote(self.data)}", check=False)
            else:
                subprocess.run(["pkill", "-f", process_pattern(self.data)], check=False)
                subprocess.run(["rm", "-rf", self.data], check=False)
            raise

    def _find_pid(self):
        pattern = process_pattern(self.data)
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

    def raw_listing(self):
        """Whatever the accessibility helper prints, unchecked: for failure diagnostics only."""
        return self.run("ax-helper", "list", check=False)

    def listing(self):
        """The app's accessibility listing, which must be a complete read: a helper failure, a walk cut short or a child
        list that could not be read (ax-helper's `list-complete` exits non-zero), or a listing without the main window
        raises AssertionError, so an absence check can never pass on a partial observation (wait and wait_for treat
        that as "not yet"). A read the app interrupted is tried again twice first."""
        for attempt in range(3):
            try:
                text = self.run("ax-helper", "list-complete")
                break
            except AssertionError:
                if attempt == 2:
                    raise
                time.sleep(0.3)
        assert re.search(r"^AXWindow: .*\bmain\b", text, re.M), f"{self.name}: the accessibility listing did not include the main window"
        return text

    def shows(self, text):
        return text in self.listing()

    def absent(self, text, within):
        """True when `text` is not shown in a listing that does show `within`, an element of the view being checked
        (such as "network-status"): the absence is observed on the right view, not on a sheet or another page."""
        listing = self.listing()
        assert within in listing, f"{self.name}: {within} is not showing, so the absence of {text!r} cannot be checked"
        return text not in listing

    def line(self, identifier):
        """The accessibility listing's line for one element, or None."""
        return next((line for line in self.listing().splitlines() if identifier in line), None)

    def names(self, identifier):
        """The names the listing gives the element with this identifier (its title, description and value), or None."""
        line = self.line(identifier)
        if line is None:
            return None
        return [part for part in line.split(": ", 1)[-1].split(" | ") if part != identifier]

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

    def read_label(self, square):
        """The square's label, which must be a real read: an unreadable square fails instead of reading as empty, so a
        check that something is absent cannot pass on a failed observation."""
        text = self.run("pointer-helper", "label", square)
        # BoardView labels a square with its name, then ", "-joined facts; an empty square with no marks is the bare name.
        assert text == square or text.startswith(f"{square},"), f"{self.name}: {square} read as {text!r}, not as a board square"
        return text

    def type_into(self, field, text):
        """Clicks the field, selects whatever it holds with Command-A, and types over it."""
        self.click(field)
        self.run("pointer-helper", "shortcut", "0", "c")
        self.run("pointer-helper", "type", text)

    def write_fault(self, text):
        """Writes the hook's file whole: written beside it and renamed over it, so the app's poll never reads it half
        written and falls back to the default disconnect."""
        partial = self.fault + ".partial"
        if self.mode == "pair":
            on_pair(f"printf %s {shlex.quote(text)} > {shlex.quote(partial)} && mv -f {shlex.quote(partial)} {shlex.quote(self.fault)}")
        else:
            pathlib.Path(partial).write_text(text)
            os.replace(partial, self.fault)

    def fault_taken(self):
        if self.mode == "pair":
            return on_pair(f"test -e {shlex.quote(self.fault)} && echo yes || echo no", check=False) == "no"
        return not pathlib.Path(self.fault).exists()

    def capture(self, name):
        """A screenshot kept as evidence. A capture or copy that fails fails the gate, never leaves an older picture in
        its place; the pair's copy is taken under a name of its own and removed afterwards."""
        target = self.evidence / f"{name}-{self.name}.png"
        target.unlink(missing_ok=True)
        if self.mode == "pair":
            remote = f"{self.data}/shot-{uuid.uuid4().hex}.png"
            try:
                on_pair(f"screencapture -x {remote}")
                subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", f"{pair()}:{remote}", str(target)], check=True, timeout=60)
            except subprocess.TimeoutExpired:
                raise AssertionError(f"{self.name}: the screenshot {name} could not be copied within 60 s") from None
            except subprocess.CalledProcessError as error:
                raise AssertionError(f"{self.name}: the screenshot {name} could not be copied ({error})") from None
            finally:
                on_pair(f"rm -f {remote}", check=False)
        else:
            try:
                subprocess.run(["screencapture", "-x", str(target)], check=True, timeout=60, capture_output=True)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                target.unlink(missing_ok=True)
                raise AssertionError(f"{self.name}: the screenshot {name} could not be captured ({error})") from None
        with open(target, "rb") as picture:
            header = picture.read(8)
        if header != b"\x89PNG\r\n\x1a\n":
            target.unlink(missing_ok=True)
            raise AssertionError(f"{self.name}: the screenshot {name} is not a picture")

    def connection_log(self):
        """This instance's network and app log lines since it started, kept with its evidence."""
        predicate = f'processID == {self.pid} AND (subsystem == "com.apple.network" OR subsystem == "ai.xiaolai.checkmate")'
        command = ["/usr/bin/log", "show", "--style", "compact", "--last", f"{int(time.monotonic() - self.started) + 30}s", "--predicate", predicate]
        target = self.evidence / f"connection-{self.name}.log"
        target.unlink(missing_ok=True)
        call = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", pair(), " ".join(shlex.quote(part) for part in command)] if self.mode == "pair" else command
        try:
            result = subprocess.run(call, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            raise AssertionError(f"{self.name}: its connection log could not be read within 120 s") from None
        # Evidence that was never collected fails cleanup (stop_all records it), instead of passing as an empty log.
        if result.returncode != 0:
            raise AssertionError(f"{self.name}: its connection log could not be read: {result.stderr.strip() or result.returncode}")
        target.write_text(result.stdout)

    def stop(self):
        """Stops the instance, confirms it is gone and removes its data. A stop that times out or leaves the app running
        raises AssertionError, so the gate cannot pass with an automation app left behind to disturb the next one."""
        try:
            self._stop()
        except subprocess.TimeoutExpired as error:
            raise AssertionError(f"{self.name} may still be running: stopping it timed out ({error})") from None
        if self._alive():
            raise AssertionError(f"{self.name} (pid {self.pid}) was still running after it was stopped")

    def _alive(self):
        if self.mode == "direct":
            return self.process.poll() is None
        if self.mode == "pair":
            return on_pair(f"kill -0 {self.pid} 2>/dev/null && echo alive || echo gone", timeout=30) == "alive"
        return subprocess.run(["kill", "-0", str(self.pid)], capture_output=True).returncode == 0

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
            on_pair(f"kill {self.pid} 2>/dev/null; sleep 2; kill -9 {self.pid} 2>/dev/null; sleep 0.5; rm -rf {shlex.quote(self.data)}", timeout=60)
        else:
            subprocess.run(["kill", str(self.pid)], check=False)
            time.sleep(2)
            subprocess.run(["kill", "-9", str(self.pid)], check=False, capture_output=True)
            time.sleep(0.5)
        if self.mode != "pair":
            subprocess.run(["rm", "-rf", self.data], check=False)


def stop_all(instances, results, logs=False):
    """Stops every instance whatever happens to the others; with `logs`, keeps each one's connection log first. Every
    failure is recorded in results["cleanupErrors"] and returned, so the caller fails a gate that left an app running
    or could not confirm it stopped."""
    errors = []
    for instance in instances:
        if logs:
            try:
                instance.connection_log()
            except Exception as error:  # noqa: BLE001 - a log that cannot be read never skips the stop
                errors.append(f"{instance.name} connection log: {error}")
        try:
            instance.stop()
        except Exception as error:  # noqa: BLE001 - every instance is stopped; each failure is kept
            errors.append(f"{instance.name}: {error}")
    if errors:
        results.setdefault("cleanupErrors", []).extend(errors)
    return errors


def cleanup_failure(results, failure, errors):
    """The gate's failure once cleanup is done: a run that passed fails when cleanup did not finish."""
    if errors and results.get("passed"):
        results["passed"] = False
        return "cleanup failed: " + "; ".join(errors)
    return failure


def permission(instance):
    """The local-network permission state the instance shows: "denied" when it asks for access (D13); "allowed" only
    when a connection is established, which the status line shows by naming whose move it is ("Your move.", "Ana's
    move.": NetworkGameController.statusText's live state; the spike showed a silent refusal never reaches it);
    otherwise "unknown": connecting, waiting, reconnecting, stopped, or a window that cannot be read. Nothing is
    inferred from the absence of the denial UI, or from a status line or play code alone."""
    try:
        listing = instance.listing()
    except AssertionError:
        return "unknown"
    if "network-access-needed" in listing or "network-permission-sheet" in listing:
        return "denied"
    status = next((line for line in listing.splitlines() if "network-status" in line), "")
    return "allowed" if re.search(r"(?:^|[|:] )(?:Your move|.+'s move)\.(?: \||$)", status) else "unknown"


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


# The lobby's badge for an advertised mini-game (protocol 1.3): each competitive kind's title, as MiniGameKind words it.
MINI_GAME_TITLES = ("Pawn Duel", "Rook Sweep", "Rooks and Pawns", "Bishop Sweep", "Bishops and Pawns", "Queen Against Pawns", "Knight Capture")


def host_game(host, name="Ana", assistance=None, handicap=None, side=None, start=None, mini_game=None):
    """Hosts from the sheet. `assistance` picks one level for both sides; `handicap` is (White's, Black's) levels,
    set through the Handicap switch (assistance plan A2). Each is a level's title, such as "Hints on request".
    `side` picks the host's side by its title ("White", "Black"). `start` is a game-library position, (the game's
    title, the move it follows, such as "After 5. Nxe5"), each the menu item's whole title, chosen in the sheet's start picker (mini-games plan
    D7; the app runs with CHECKMATE_NETWORK_POSITIONS=1). Without one, a start picker the sheet shows is set back to the
    standard position, since the sheet keeps the form between games. `mini_game` is a mini-game's title, chosen in the
    sheet's Play picker (protocol 1.3; the app runs with CHECKMATE_NETWORK_MINI_GAMES=1); it has its own start and no
    assistance, so it takes neither `start` nor an assistance choice. Without one, a Play picker the sheet shows is set
    back to Chess."""
    assert not (mini_game and (start or assistance or handicap)), "a mini-game has its own start and no assistance"
    host.click("network-host-button")
    wait(lambda: host.shows("network-host-sheet"), "the host sheet did not open")
    host.type_into("network-host-name", name)
    if mini_game:
        host.run("pointer-helper", "select-popup", "network-host-game", mini_game)
        wait(lambda: host.shows("network-host-mini-note"), f"the sheet did not choose {mini_game}")
        assert not host.shows("network-host-assistance") and not host.shows("network-host-start-position"), "the sheet still offers assistance or a start for a mini-game"
    elif host.shows("network-host-game"):
        host.run("pointer-helper", "select-popup", "network-host-game", "Chess")
        wait(lambda: not host.shows("network-host-mini-note"), "the Play picker did not go back to chess")
    if side:
        host.run("pointer-helper", "select-popup", "network-host-side", side)
    if start:
        game, move = start
        host.run("pointer-helper", "select-popup", "network-host-start-position", "A library game's position")
        wait(lambda: host.shows("network-host-library-game"), "the host sheet offered no library games", 30)
        host.run("pointer-helper", "select-popup", "network-host-library-game", game)
        wait(lambda: host.shows("network-host-library-move"), f"{game} offered no positions", 30)
        host.run("pointer-helper", "select-popup", "network-host-library-move", move)
        wait(lambda: move in (host.names("network-host-library-move") or []), f"the sheet did not choose {move}")
        assert host.shows("network-host-start-note"), "the sheet did not say the game is ordinary chess from the position"
    elif host.shows("network-host-start-position"):
        host.run("pointer-helper", "select-popup", "network-host-start-position", "Standard position")
        wait(lambda: not host.shows("network-host-library-game"), "the start picker did not go back to the standard position")
    # The Handicap switch's state is read from what it shows (a level for each side when on), since the sheet keeps
    # the form between games: it is turned off for one level for both and on for a handicap, never toggled blindly.
    if assistance and host.shows("network-host-assistance-white"):
        host.click("network-host-handicap")
        wait(lambda: host.shows("network-host-assistance") and not host.shows("network-host-assistance-white"), "the handicap switch did not turn off")
    if assistance:
        host.run("pointer-helper", "select-popup", "network-host-assistance", assistance)
    if handicap:
        if not host.shows("network-host-assistance-white"):
            host.click("network-host-handicap")
        wait(lambda: host.shows("network-host-assistance-white"), "the handicap switch did not show a level for each side")
        host.run("pointer-helper", "select-popup", "network-host-assistance-white", handicap[0])
        host.run("pointer-helper", "select-popup", "network-host-assistance-black", handicap[1])
    host.click("network-host-start")
    wait(lambda: host.shows("network-play-code"), "hosting did not start")
    return code(host, "network-play-code"), code(host, "network-watch-code")


def game_row(instance, title):
    """The identifier of the lobby row named `title`: the row's label is the title, its game-ID suffix and an optional
    badge ("Ana's game · K7QD", "Dee's game · WA48, Hints", "Ana's game · K7QD, Pawn Duel"), never a longer name that
    merely contains the title ("Not Ana's game · K7QD")."""
    badges = "|".join(re.escape(badge) for badge in ("Board insight", "Hints", "Guided", "Handicap") + MINI_GAME_TITLES)
    exact = re.compile(re.escape(title) + r"(?: · [0-9A-Z]{4})?(?:, (?:" + badges + r"))?")
    for line in instance.listing().splitlines():
        found = re.search(r"(network-game-[0-9A-Z]{26})", line)
        if found and any(exact.fullmatch(part) for part in line.split(": ", 1)[-1].split(" | ")):
            return found.group(1)
    return None


def join(instance, title, name, typed, watching=False, timeout=30, accept=None):
    """Picks the game, types the name and code, and joins or watches. `accept`: the game has assistance, so the Accept
    sheet appears (assistance plan A3), must say exactly these terms (the sheet's sentence, as NetworkWording.offer
    words it), and is accepted: what the joiner agreed to is checked, not only the game's terms afterwards."""
    row = wait_for(lambda: game_row(instance, title), f"{instance.name} never listed {title}", timeout)
    instance.click(row)
    instance.type_into("network-name-field", name)
    instance.type_into("network-code-field", typed)
    instance.click("network-watch-button" if watching else "network-join-button")
    if accept:
        wait(lambda: instance.shows("network-accept-sheet"), f"{instance.name} was not asked to accept the assistance")
        terms = instance.names("network-accept-terms") or []
        assert accept in terms, f"{instance.name} was asked to accept {terms!r}, not exactly {accept!r}"
        instance.click("network-accept-assistance")
