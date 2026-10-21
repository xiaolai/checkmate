"""Sidebar lesson rows for the real-pointer gates.

A row is clicked by its identifier, never its title: the board-area title and a mini-game's own sidebar row repeat
lesson titles. A row far down the list has no frame until the list has scrolled near it, so a click that misses
scrolls the sidebar to the top once and then down step by step until the click lands.
"""
import json
import pathlib
import subprocess
import time

COURSE = json.loads((pathlib.Path(__file__).resolve().parents[1] / "Sources/CheckmateCore/Resources/course.json").read_text())


def row(title):
    """The accessibility identifier of the sidebar row for the lesson with this title."""
    return "sidebar-lesson-" + next(lesson["id"] for lesson in COURSE["lessons"] if lesson["title"] == title)


def click(pointer, title, attempts=24):
    """Clicks a lesson's sidebar row with the real pointer, scrolling it into view first when it is out of sight."""
    for attempt in range(attempts):
        try:
            pointer("click", row(title))
            return
        except subprocess.CalledProcessError:
            if attempt == attempts - 1:
                raise
            pointer("scroll-sidebar", "400" if attempt == 0 else "-10")
            time.sleep(0.3)
