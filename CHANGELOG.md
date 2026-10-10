# Checkmate 0.3.3

The minimum macOS version is now 14. One universal app includes native Apple
Silicon and Intel slices in the application, MCP helper, and Stockfish engine.
Older macOS versions receive a generated icon fallback; newer versions retain
the layered Icon Composer artwork. A screenshot API introduced in macOS 14.4
now has an availability-checked fallback for macOS 14.0–14.3.

Automated verification on build-host: 249 tests per architecture, five optional skips
and zero failures each, native UI checks, and 19 MCP integration checks per
architecture. Intel execution was tested under Rosetta. Physical Intel and
macOS 14/15 runtime acceptance remain unverified.

# Checkmate 0.3.2

Entering a lesson opens the right sidebar for the transcript and learning tools.
Manually closing it keeps it closed while navigating that lesson. With Continue
Automatically enabled, finishing a lesson starts the next lesson at its first
transcript; the last lesson stops normally. Quizzes still wait for a correct
answer. The manual Continue to the next lesson button now starts playback.

Regression coverage checks all 40 lesson boundaries, disabled automatic playback,
the end of the course, and sidebar behavior through native UI interactions.

# Checkmate 0.3.1

Single-square lesson questions now check the answer immediately when the learner
clicks the board. Finding the white king in Introduction continues directly into
the explanation and narration, without a separate confirmation button. Wrong
clicks show feedback, and revisiting a previously answered question still responds.
All 16 single-square lesson questions use this behavior. Questions asking for
multiple squares keep their confirmation button; puzzles retain their explanation.
The native UI regression now sends a real mouse click instead of confirming the
answer programmatically.

# Checkmate 0.3.0

Native macOS 27 chess practice with offline Stockfish 19, 40 lessons, 83 quizzes,
87 puzzles and 947 Cedar narration clips. Lesson mini-games now provide computer
opponents by default. Piece inspection explains protection and attacks; board
highlights and move connectors follow the selected theme.

The opt-in game-review pilot imports PGN collections and FEN positions, preserves
recorded games, separates imagined lines, and supports practising from a reviewed
position. Custom skill and engine Elo controls extend opponent difficulty.
Audit fixes cover stale review work, promotion history, restore/resume safety,
visible errors, voice context and MCP pause-state reporting. Explicit MCP routing
keeps practice previews independent of review tools.

Automated acceptance on build-host: 238 tests executed across native suites, 233 passed, five optional skips,
zero failures. Native UI interaction, package/signature and cold/warm memory checks
were verified during remediation; final release packaging is verified separately.
Human review of the prepared corpus, novice play and audible/microphone acceptance
remain pending. Review, labels, review voice and beginner features remain opt-in.

Requires Apple Silicon and macOS 27. Back up native data and export imported games
before downgrading. Development and release data directories are separate.

The chess MCP companion is now a bundled native Swift executable. Settings provides Codex setup; Node and pnpm are no longer required.
