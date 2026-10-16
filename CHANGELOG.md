# Checkmate (next release, draft)

Play on Network lets two people on the same local network play each other.
One hosts a game from the sidebar and shares its play code; the other
picks it from the list and types the code. Others can watch with a separate
watch code, and their clicks never move a piece. Games can be untimed or
timed, from 3 + 2 to 30 minutes, and both players can offer, accept or claim
a draw, or resign. A player whose connection drops has up to two minutes to
come back to the same seat. When a game ends, Review opens it with both
players' names. If your clock runs out while your opponent has
only a king, the game is a draw. Otherwise it is lost on time, even in the
rare positions where no checkmate is possible, such as fully blocked pawn
chains. While you play or watch, the engine, hints and the coach are
paused everywhere in the app, and the companion only sees that a network
game is on. The first time, macOS asks to let Checkmate use the local
network. Play on Network appears on macOS 26 and later, and on macOS 14,
which was checked in a virtual machine; it does not appear on macOS 15.

Automated acceptance covered three copies of the app on the test Mac, real
Bonjour discovery between two copies, and a game between two Macs on the same
network, played to checkmate with real pointer clicks on both and reviewed on
both. In that game the joining Mac lost its connection, through a test-only
switch, and came back to its seat. A real cable or Wi-Fi loss was not tested
automatically. No person has yet played a network game, or used it with
VoiceOver.

# Checkmate 0.7.7

Review a game now has a library of famous games to explore. It holds 165:
two to four from every World Championship match from 1886 to 2024, and 14
classics. You can search by player, event, year or opening, with or without
accents, filter to championships, classics or your own games, and fold each
match away. Import Collection… adds your own PGN files under My games, and
Get More Games points to free PGN downloads. Each game's moves come from a
recorded source file. When the sources do not say how a decisive game ended,
the row says only who won.

The review pane has been redesigned with native controls. It shows an
evaluation graph once the whole game is analysed and marks only the moves
worth a second look. The voice coach now works in review by default.

Automated acceptance covered every gate on the test Mac, including real
pointer clicks and drags in the library and a search over 5,000 imported
games. A live check, with no microphone or speaker, ran a real coach turn in
English, Chinese and Spanish with every narrated segment verified, and a voice
preview. No person has yet listened to the coach in review or used the
library with VoiceOver.

# Checkmate 0.7.6

Two lesson steps now answer a question beginners ask at that moment. In
Removing the Defender, once White's pawn reaches e5, the narration explains that
Black's bishop on d5 cannot take it, because bishops only move diagonally. In
Two-Rook Checkmate, the step is now called "When Black's king comes close", and
it says why the king could take a rook on b6: nothing guards that square. Both
clips were recorded again in the same Cedar voice.

Automated acceptance covered every gate on the test Mac. A live check, with no
microphone or speaker, ran a real coach turn in English, Chinese and Spanish
with every narrated segment verified, and a voice preview. A person listened to
both new clips in the app. Interrupting the coach by voice, how it sounds, and
how it waits through real pauses have still not been checked by a person
listening.

# Checkmate 0.7.5

The voice coach is steadier and easier to talk to. A reply that fails or takes too
long now ends that reply instead of disconnecting, and a coach that keeps reaching
for its chess tools without speaking stops after three tries and says so, so a
guided game never waits on it. Questions asked while the coach is busy are
answered afterwards instead of being lost, and your words stay above its answer.

Where macOS echo cancellation is available you can interrupt the coach by
speaking; otherwise it keeps the floor and Stop still works. In a guided game it
gives one short idea after each of your moves, and speaks about Stockfish's move
only for a check, capture, promotion or the end of the game. It waits through a
pause while you think instead of answering half a question, and Settings → Voice
Coach has a Spoken language choice.

Voice reconnects when you come back to Practice or show the app again, and renews
itself before the provider's one-hour session limit. It uses your ChatGPT
subscription through Codex, never an API key, and says plainly when the sign-in
has expired, was not accepted or is rate-limited. Your saved coach volume now
applies from launch, and the launch check no longer runs when voice is set not to
connect on launch. A reasoning effort the voice model refuses returns to the one
in use. Preview voice plays the voice you selected, even while the coach uses
another. Settings → Usage counts narrated segments heard as written, shown as text
instead, or stopped.

Automated acceptance covered every gate on a second test Mac. A live check on the
build Mac, with no microphone or speaker, ran a real coach turn in English, Chinese
and Spanish with every narrated segment verified, and a voice preview; releases now
require it. Interrupting by voice, how the coach sounds, and how it waits through
real pauses have not yet been checked by a person listening.

# Checkmate 0.7.4

Lessons now draw defence differently from attack. When a piece guards another,
a curved line runs from the guard to what it protects, with a ring on the guard,
the way the Inspector shows a protected piece; attacks and moves keep the dashed
arrow. VoiceOver reads it on both squares ("guards f7", "guarded by e8"). About
40 steps across 20 lessons changed: arrows that really showed a guard became
guard lines (the bishop guarding the queen in Scholar's Mate, rooks guarding
each other, the king beside its pawn), steps whose narration says a piece guards
another now draw it, and the discovered-attack setups draw the whole blocked line
through the piece in the way.

A guard appears when it becomes true: the king's guard of the queen when she
lands beside him, the d-pawn's guard of e4 when it reaches d3. In Chess Notation,
the other knight (or rook) that could have made the move is shown before the
move instead of after it. Scholar's Mate step 2 and Winning Material Puzzles step
4 reveal their guards sentence by sentence; when stepped to while paused they
show everything at once. Translated narration spaces those stages evenly rather
than by sentence.

Automated acceptance covered every gate on a second test Mac. A real-pointer
check opened Scholar's Mate step 2 and confirmed both guards while paused, only
Black's after Play, and White's with its sentence, with screenshots reviewed. An
independent python-chess audit checks every guard and stage. No narration was
re-recorded. The new illustrations have not yet been watched through by a
person beyond those screenshots. Saved translations of the twenty changed
lessons no longer match them and have to be made again; the other 19 lessons
keep theirs. Live voice and
translation were not exercised for this release.

# Checkmate 0.7.3

34 lesson recordings are re-recorded. In 21, the voice stopped before the last
sentence of the text, so the clip ended early and sometimes reversed its point:
"A side with no move on its turn" without "loses", several "Checkmate." endings,
and "Check before you land.", "Keep her safe." and "The board is ready." among
others. Three said a wrong square ("S six" for "F six", "D five" for "B five",
and an unclear "B two"), and nine slurred a word into another ("Whites came" for
"White's king", "coins" for "points", "slit" for "slip"). In Chess Notation, "On
the queen's side" had a faint second "queen" under the voice; its new take has
none. Two texts were reworded because the voice kept dropping or blurring them:
Playing in a Tournament no longer ends on "Check the rules.", and Queen Practice
says "a square that a pawn attacks".

Every recording is now transcribed before it is published, and a clip whose
ending, words or squares are not all heard is refused. A faint doubled word under
the voice cannot be caught this way; that still needs listening.

Automated acceptance covered every gate on a second test Mac, and the native
tests decode all 710 bundled clips. Every clip passed the coverage check
(whisper-1 on the full clip and on its last three seconds), and two local
whisper models agree on the 34 new takes. The new Chess Notation clip was played
once for review; the other 33 new takes have not yet been listened to, and the
remaining 676 clips have been checked by transcription only, which cannot hear a
faint doubled word. Live voice and translation were not exercised for this
release.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

# Checkmate 0.7.2

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

In Chess Notation, three transcript steps (a pawn capture, castling kingside
and castling queenside) stopped a clause before the narration did: the voice
went on to say how the notation is read ("read as e takes f6", "said as
castles queenside") while the text had already ended. The text now says it
too, and the content check fails if a transcript drops a pronunciation its
recording speaks.

Automated acceptance covered every gate on a second test Mac. Real pointer
clicks and key presses checked that the lesson playback buttons stay put on
every step with the drawers open and closed, the Lesson menu shortcuts and ⌘Z,
and training Take back from the bar and from ⌘Z; the layout gate measured every
bar control in practice, a lesson and an exercise from 780 down to 320 points,
with one row required from the 600-point minimum up. Codex reviewed the design
and twice reviewed the implementation. Nobody has yet listened to the new
controls with VoiceOver (their names are checked, not the speech), and live
voice, translation and recording were not exercised for this release.

Requires macOS 14+ with universal Apple Silicon and Intel binaries.

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

Automated acceptance covered every gate on the build host and on a second test Mac,
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

Automated acceptance covered every gate on the build host and on a second test Mac,
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

Automated acceptance covered every gate on the build host, including real pointer
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

Automated acceptance covered every gate on the build host, including real pointer
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

Automated acceptance covered every gate on the build host, including real pointer
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

Automated acceptance covered every gate on the build host, including real pointer
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

Automated verification on the build host: 249 tests per architecture, five optional skips
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

Automated acceptance on the build host: 238 tests executed across native suites, 233 passed, five optional skips,
zero failures. Native UI interaction, package/signature and cold/warm memory checks
were verified during remediation; final release packaging is verified separately.
Human review of the prepared corpus, novice play and audible/microphone acceptance
remain pending. Review, labels, review voice and beginner features remain opt-in.

Requires Apple Silicon and macOS 27. Back up native data and export imported games
before downgrading. Development and release data directories are separate.

The chess MCP companion is now a bundled native Swift executable. Settings provides Codex setup; Node and pnpm are no longer required.
