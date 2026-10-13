# Unreleased

The control bar under the board is redesigned. In a lesson its four playback
buttons (from the start, previous, play, next) keep their places on every
step, the exercise step included, instead of shifting as buttons came and
went. Each symbol now has one meaning: chevrons step, a double chevron crosses
into the next or previous lesson (whose name the status line and the button
give), Undo and Restart no longer share a look-alike arrow, and actions an
icon cannot explain are said in words (New game…, Try a move, Return to game,
Resume your attempt, Back to The Pawn, Next puzzle). Whose turn it is, and
when Stockfish is thinking, are written beside the turn dot. In practice the
voice coach's Stop stays one click away and Disconnect moves into its menu.
When the window is too narrow, the bar takes a second row and the board stays
square. A new Lesson menu offers Play/Pause (⌘P), Previous and Next Step (⌘[
and ⌘]), Play Step from Start (⌘R) and Hint (⇧⌘H). ⌘Z now reaches the board,
where before it did nothing: it takes back a practice move, undoes a turn in a
lesson exercise, or takes back a training move. In lessons and puzzles the
details toggle is named Lesson Guidance, which replaces the book button.

# Checkmate 0.7.1

"Now try it yourself" is now a real turn inside the lesson. In the thirteen
lessons that end with an exercise (The Pawn, Castling, Castling Rules,
Promotion and En Passant, Scholar's Mate, the five tactics and the three basic
checkmates), the last step's own board is the learner's to play: click or drag
a White piece, with both drawers open or closed, and the computer answers.
Before, that board ignored every click and the drawer's "Try it against the
computer" left the lesson for a practice game that replaced the learner's own
game, with no way back. That button and its route are gone.

The title shows where the exercise stands (Your turn, Computer's turn, Try
again, Well done, Play on). The drawer lists what counts as doing it, two
hints about the starting position and then a move shown as an arrow, Undo turn
and Restart. A move that leaves the taught idea is called out and undone;
Castling Rules explains why the other side cannot castle; stalemate in a
checkmate lesson is explained rather than counted. The tactics follow an
authored line with the computer's best defence; a fixed-depth search checks
that the line wins its material against every defence and that no other
winning move of the same shape is refused. After success the learner may play
on against the beginner opponent. Leaving the step, the lesson or the app
keeps the attempt exactly where it was; the computer's turn waits for Resume,
as it does while the app is hidden. The practice game is never touched.
Narration ending on the exercise never moves on to the next lesson.

The Pin's exercise has a new position. In the old one no pin could win
material, so "Pin it, attack it, and win material" was not true there; the new
board keeps the knight on c6 and the king on e8, so the recorded narration
stays word for word.

Automated acceptance covered every gate on a second test Mac, including real
pointer clicks on the new exercises (castling by click and by drag with the
drawers closed, a refused castling explained, a tactic gone off track and
undone, the full Fork line and Play on, the promotion menu, and an attempt
restored after leaving and after a relaunch). A fixed-depth python-chess
search checked every tactic line, and Codex reviewed the change twice. No
beginner has yet played the exercises, and their new texts have not had an
editorial review. Live voice, translation and recording were not exercised for
this release.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.
# Checkmate 0.7.0

The beginner course is new. Every lesson, board, puzzle and recording was
written again from scratch: 39 lessons and 82 puzzles, with all 710 narration
clips recorded fresh. The order now follows the pieces first (each piece
lesson with its practice activity beside it), then the king, check and
checkmate, setting up the board, castling, the special moves and the rules of
play, and then openings, tactics, the basic checkmates and puzzles. It ends
with a famous short game, Réti against Tartakower, Vienna 1910.

Every board in the course is checked by machine: each move shown is a legal
move for that piece on that board, no move leaves its own king in check, every
check mark sits on a king that is really attacked, and every board puzzle's answer
is the complete set of correct moves. The same checks run again with an
independent chess library.

The practice games have new starting layouts and names: Pawn Duel, Rook Sweep,
Rooks and Pawns, Bishop Sweep, Bishops and Pawns, Queen Against Pawns, Knight
Capture and Knight Corners. Their rules are unchanged, except that Knight
Corners now visits a8, h8 and h1 before returning to a1.

On a lesson's last step, the → arrow in the toolbar now goes on to the next
lesson, as the panel's Continue does; before, it only marked the lesson
explored. In reverse, ← on a lesson's first step goes back to the end of the
previous lesson, paused there. Both tooltips name the lesson, and both skip
practice activities (from Pawn Duel, ← goes back to The Pawn).

Your progress carries over: lessons you completed stay completed under their
new names, and you return to the lesson you were in. Because the narration
and puzzles are new, each lesson starts again from its first step, puzzle
results start fresh, and a practice game in progress restarts in its new
layout. Training history follows the renamed games. Saved lesson translations
need to be made again in Settings → Lessons.

Automated acceptance covered every gate on build-host and on a second test Mac,
including real pointer clicks on every practice game and the lesson arrows,
and tests of the saved-progress migration. Every course board and puzzle
passed the machine checks above. No person has yet listened to the 710 new recordings
or reviewed the new lessons as an editor or a beginner. Live voice,
translation and recording were not exercised for this release, and the
training library stays switched off.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

# Checkmate 0.6.2

The practice activities no longer sit between the lessons. Pawn Duel, Rook
Practice, Bishop Practice, Queen Practice, Knight Practice and Safe Squares now appear
indented under the piece lesson they practise. Continue goes straight to the
next lesson, so the path from The Pawn to The King is six lessons, and each
lesson offers a Practise button for its activity. With Pause for practice on,
continuous playback still stops at the end of a lesson to offer it. Saved
progress and lesson translations are unaffected, except The Queen: it gains a
takeaway giving the queen's starting square, so a saved translation of The
Queen needs to be redone in Settings → Lessons.

Short lesson arrows are now visible. An arrow one square long, such as each
of the king's eight moves, used to shrink to a sliver of arrowhead; it now
keeps a shaft and a whole head. The Knight lesson's counted routes (two
squares, then one sideways) draw as one bent arrow instead of two pieces.

Automated acceptance covered every gate on build-host and on a second test Mac,
including real pointer clicks on every practice activity, its Practise button
and the Continue button. Live voice, translation and recording were not
exercised for this release. Whether the indented activities read as practice
to a beginner, human review, novice play and live microphone checks are still
outstanding, and the training library stays switched off.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

# Checkmate 0.6.1

Lesson illustrations now follow the narration. When a lesson moves a piece,
its arrows and check marks appear once the piece has landed, not before it
starts moving. An attack arrow now stops at the piece it attacks: the
Introduction's checking rook and a mate-in-one bishop no longer point past
the king.

If you translated the Introduction into another language, that saved
translation no longer matches the corrected illustration. Translate the
Introduction again in Settings → Lessons to use it. The English narration is
unchanged.

Automated acceptance covered every gate on build-host, including real pointer
clicks that play the corrected lesson step. Live voice, translation and
recording were not exercised for this release. Human review, novice play and
live microphone checks are still outstanding, and the training library stays
switched off.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

# Checkmate 0.6.0

This release adds the groundwork for a training library: short, exactly
graded exercises between lessons and full games. They cover piece movement,
attacks and defence, check and mate, special moves, simple tactics and
finishing a won ending. The library is included but switched off. It stays
off until its content has had an editorial review and a beginner has been
observed using it, so nothing in the app changes for you yet.

Fixes you may notice:
- The voice coach's Stop button now works from the conversation's real state,
  including while a tool is still running after the coach finishes speaking.
- Leaving a draft review re-checks your answer if the review changed while the
  question was open.
- Move animations and promotion menus no longer act on a board that has since
  been replaced.
- Very long imported games are refused before they are replayed.

Automated acceptance covered every gate on build-host, including real pointer
clicks, fullscreen and Intel under Rosetta. Live voice, translation and
recording were not exercised for this release. Human review, novice play and
live microphone checks are still outstanding. The experimental review quality
labels, review voice and beginner opponent remain opt-in.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

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
