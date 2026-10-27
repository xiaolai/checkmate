"""Shared driving for the gates that drive one automation app with real pointer events and accessibility reads.

The helpers (Tools/pointer-helper.swift, ax-helper.swift, board-click-helper.swift) are compiled once per source and
toolchain into ~/Library/Caches/checkmate-helpers and copied to where each gate keeps them in its evidence, so every
gate's evidence holds the same files as when it compiled them itself. A cached binary is used only while its digest
matches the one recorded when it was compiled: a missing, partial or damaged entry is compiled again, never skipped.
"""
import functools
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
HELPERS = ("pointer-helper", "ax-helper", "board-click-helper")
CACHE = pathlib.Path.home() / "Library/Caches/checkmate-helpers"


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@functools.lru_cache(maxsize=1)
def _toolchain() -> bytes:
    """What besides the source decides the binary: the compiler's version and the machine it builds for."""
    # `swiftc --version` exits leaving an empty TemporaryDirectory.* in TMPDIR, which a gate's leak check would report.
    with tempfile.TemporaryDirectory() as scratch:
        version = subprocess.run(["xcrun", "swiftc", "--version"], capture_output=True, check=True, env={**os.environ, "TMPDIR": scratch})
    return version.stdout + version.stderr + platform.machine().encode()


def _compiled(source: pathlib.Path) -> pathlib.Path:
    """The cached binary for this source, compiled into the cache first unless a sound entry is already there."""
    folder = CACHE / hashlib.sha256(source.read_bytes() + b"\0" + _toolchain()).hexdigest()
    binary, record = folder / source.stem, folder / (source.stem + ".sha256")
    if binary.is_file() and record.is_file() and record.read_text() == _sha256(binary):
        return binary
    folder.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=folder) as scratch:
        built = pathlib.Path(scratch) / source.stem
        subprocess.run(["xcrun", "swiftc", str(source), "-o", str(built)], check=True)
        digest = _sha256(built)
        os.replace(built, binary)
        # Recorded last, so an entry interrupted before this point has no record and is compiled again.
        (pathlib.Path(scratch) / "record").write_text(digest)
        os.replace(pathlib.Path(scratch) / "record", record)
    return binary


def compile_helpers(evidence: pathlib.Path, outputs: dict = None) -> dict:
    """Puts each helper in the evidence folder under the file name the gate gives it ({helper: file name}; by default
    the three helpers under their own names) and returns {helper: path}."""
    helpers = {}
    for name, output in (outputs or {name: name for name in HELPERS}).items():
        helpers[name] = evidence / output
        cached = _compiled(root / "Tools" / (name + ".swift"))
        # Copied beside its place and renamed over it, so a helper is never seen half written.
        partial = helpers[name].with_name(helpers[name].name + ".partial")
        shutil.copy2(cached, partial)
        os.replace(partial, helpers[name])
    return helpers


def without_automation(*also_removed: str) -> dict:
    """This process's environment without CHECKMATE_AUTOMATION (silence comes from --automation) or the other names."""
    removed = {"CHECKMATE_AUTOMATION", *also_removed}
    return {key: value for key, value in os.environ.items() if key not in removed}


def launch(command: list, environment: dict, stderr=subprocess.DEVNULL) -> subprocess.Popen:
    return subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=stderr)


def stop(process, timeout: float = 5, kill: bool = False) -> None:
    """Stops the app if it is still running. With `kill`, an app that outlives the timeout is killed and waited for."""
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if not kill:
                raise
            process.kill()
            process.wait(timeout=timeout)


def wait(predicate, message: str, timeout: float = 15, interval: float = 0.2) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise AssertionError(message)


def saved(state: pathlib.Path, missing_is_empty: bool = False) -> dict:
    """The app's saved state (state-v1.json in its data folder); with `missing_is_empty`, {} before the first save."""
    path = state / "state-v1.json"
    return json.loads(path.read_text()) if path.exists() or not missing_is_empty else {}


def coords(square: str) -> tuple:
    return ord(square[0]) - 97, int(square[1]) - 1


def name(file: int, rank: int):
    return chr(97 + file) + str(rank + 1) if 0 <= file < 8 and 0 <= rank < 8 else None


class App:
    """Helper calls on a driver's running app. `process` returns the driver's current subprocess.Popen: drivers
    relaunch their app, so its process id is looked up at every call."""

    def __init__(self, helpers: dict, process):
        self.helpers, self.process = helpers, process

    def run(self, helper: str, *arguments: str) -> str:
        """One helper call's output, stripped; a helper that fails raises CalledProcessError."""
        return subprocess.check_output([str(self.helpers[helper]), str(self.process().pid), *arguments], text=True).strip()

    def pointer(self, *arguments: str) -> str:
        return self.run("pointer-helper", *arguments)

    def listing(self) -> str:
        """The accessibility listing exactly as ax-helper prints it."""
        return subprocess.check_output([str(self.helpers["ax-helper"]), str(self.process().pid), "list"], text=True)

    def label(self, square: str) -> str:
        return self.pointer("label", square)

    def open_drawers(self, wait, sidebar_message: str, details_message: str) -> None:
        """Opens the lesson sidebar and the game details, each only when it is not showing (so a restored drawer is
        never closed), and waits for each with the driver's own `wait`."""
        if "AXStaticText: The Pawn" not in self.listing():
            self.pointer("click", "Sidebar")
        wait(lambda: "AXStaticText: The Pawn" in self.listing(), sidebar_message)
        if "practice-heading" not in self.listing():
            self.pointer("click", "Details")
        wait(lambda: "practice-heading" in self.listing(), details_message)
