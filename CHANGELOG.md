# Checkmate 0.5.0

Under the hood, the app is now built from separate parts with enforced
boundaries: chess rules, the engine, lesson content and the Mac
interface each have their own module, and a build check rejects code
that crosses a boundary it should not. Nothing you see changes, and
saved progress, lessons and Codex connections work as before.

Lesson languages now include Gurmukhi and Vai scripts, and language,
region and script choices are checked against current system lists.
Lesson translation through Codex is safer when several requests overlap.

Automated acceptance covered every gate on build-host, including real pointer
clicks, fullscreen and Intel under Rosetta. Live voice, translation and
recording were not exercised for this release; human review, novice play
and live microphone checks are still outstanding, and the experimental
review quality labels, review voice and beginner opponent remain opt-in.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

# Checkmate 0.4.0

Lessons in your language. Settings → Lessons can translate a lesson and
record its narration through your Codex sign-in, then play it offline;
a lesson plays in English until all its recordings are complete.
Translation and recording run only when you choose them, can be
cancelled or resumed, and Settings → Usage reports what each one used.
The voice coach's reasoning effort is now a setting, and it uses the
newest compatible voice model your account offers.

The course was reworked so every spoken instruction matches the board
or activity it describes. Lessons with a practice position offer "Try it
against the computer", Continue opens the next lesson from its start,
and mini-games explain their draw rules. Settings has an About pane with
the version, content counts, privacy notes and license.

Reliability: a draft review asks before its imagined lines are lost, a
failed review save is kept and retried, and quitting warns about reviews
that could not be saved. Imports validate and back up before replacing
anything, and progress written by a newer version keeps the fields this
version does not know. Practice, lessons, puzzles and reviews now switch
through one path, so leaving a review always returns to the right place.
The board stays square on any screen and drawer width. Connections from
Codex retry safely, and disconnecting cancels work in progress.

Automated acceptance covered every gate on build-host, including real pointer
clicks. Live voice, translation and recording were checked silently
during development; human review, novice play and live microphone checks
are still outstanding, and the experimental review quality labels, review
voice and beginner opponent remain opt-in.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

# Checkmate 0.3.6

Clicks now do what they show. Buttons, toggles and disclosures in the game
details drawer were drawn but almost unclickable; they respond across their
whole area. A board click no longer fails when the pointer moves slightly while
pressing, and pieces can be dragged to their destination; an illegal drop
returns the piece.

Moves that cannot be played now look different: dots for the opponent's pieces,
or shown while Stockfish is thinking, are hollow, and your selected piece stays
selected through Stockfish's reply. Undo no longer leaves Stockfish waiting
forever, Restore Previous Game swaps your two games (with the side you played)
instead of discarding the current one, and engine, puzzle and voice messages
open the details drawer instead of staying hidden.

Lessons and review: Next puzzle works under the Unsolved filter, switching
pieces in a move puzzle is no longer graded as a wrong answer, the puzzle
library ends a mini-game, and a move on a reviewed game opens Test my idea.
A slow engine start no longer reports that Stockfish could not respond.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

# Checkmate 0.3.5

The knight lesson now demonstrates a jump from g1 to f3 over its own unmoved
pawns, with the full starting position visible. It explains that knights jump
over either team's pieces but cannot land on their own pieces.

All 40 lessons were audited. The update corrects move notation and the bishop
practice game's pawn-survival condition, clarifies movement, castling, promotion
and en passant, and restores context in explanations left after quiz removal.
Practice instructions match the available computer, shared-device and solo modes.

There are 63 revised Cedar recordings at speed 1.0. The other 801 recordings
retain their original audio bytes. Stable segment IDs and saved progress are
preserved. Independent rules checks cover all 340 authored moves and 20
mate/stalemate examples; human listening and child comprehension are separate
acceptance checks.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

# Checkmate 0.3.4

Lessons now play continuously without embedded quizzes. The 83 question segments
and their answer controls have been removed, leaving 864 offline Cedar recordings
across all 40 lessons. Explanations and board illustrations are retained. Saved
positions resume at the same explanation, or immediately after a removed question;
clicking the lesson board no longer interrupts narration. The 87 separate Quick
puzzles and lesson mini-games remain available.

Game review opens a workspace with visible Open PGN, Paste PGN or FEN, and Review
Current Game actions. Imported and current-game reviews remain drafts until Save
Review or Command-S; saved reviews can be deleted with confirmation. Standard
review no longer requires an internal rollout flag. Unknown player names receive
readable titles.

At startup, Checkmate can check Codex availability, connect the voice coach and
start its private MCP broker. Independent settings control both startup behaviors;
voice opt-outs and control ownership are respected.

Fullscreen drawer toggles now retain the correct board width, including when
both panes are open.

Requires macOS 14+; the app, bundled MCP helper and Stockfish engine include Apple
Silicon and Intel binaries. Automated verification and distribution checks are
reported with the GitHub release. Physical Intel, older macOS, novice usability
and live voice acceptance are not inferred from build or automated test results.

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
