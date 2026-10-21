# Checkmate development

macOS 14+ AppKit/SwiftUI application for Apple Silicon and Intel. Practice with bundled Stockfish, 34 lessons with 5 practice activities,
82 puzzles, reversible candidate previews and demonstrations, native
settings, local MCP companion and native live voice transport. No web view or
JavaScript UI runtime. JavaScriptCore runs the existing chess.js rules only.

## Module boundaries

See [architecture.md](architecture.md) for target ownership, service contracts and the remaining Windows work.
`CheckmateCore` is a compatibility facade. New shared code imports its owning module; application workflows
cannot depend on the Stockfish implementation or macOS services. Domain, application/service integration,
native UI and MCP tests have separate test targets. The architecture gate rejects dependency regressions.

## Build and run

Every test runs on the test host, never the main Mac: unit tests, acceptance gates, live-service checks and performance
measurements. The build host only builds releases, imports recordings and builds Stockfish; one Mac may be both. Each
host is marked by a file, not by its name: `~/.config/checkmate/host-role` names `test`, `build`, or both (`mkdir -p
~/.config/checkmate && echo test build > ~/.config/checkmate/host-role`). `scripts/test_host.py` reads it, and acceptance refuses a Mac without the test
role, so no machine name appears in this repository. The test host needs Xcode 27 selected with its licence accepted, Rosetta for the Intel gate,
a logged-in GUI session whose display never sleeps, and Accessibility and Screen Recording permission for the remote
login session that drives the pointer. From the repository root:

```sh
bash build.sh
open build/CheckmateNative.app
```

`bash scripts/acceptance.sh --only unit` runs all four test suites silently. Build through `build.sh` or the gate scripts rather than a bare `swift build` or `swift test`: they run `scripts/fresh-sources.py`, which rebuilds a synced file whose content changed but whose time did not. `bash scripts/acceptance.sh` runs silent isolated
native tests, packaged UI scenarios, the existing MCP adapter against the native
broker, a temporary WebKit legacy-store exporter test, and resource checks.
The WebKit helper is a test executable, never part of the application. Its export is reimported by the deterministic migration test. The aggregate includes 483 sampled layout frames, constrained/fullscreen checks, lifecycle/restart tests, 1000 command transitions and 20 connection cycles. Automation does not enable VoiceOver or change accessibility preferences.
The build bundles the native MCP adapter. UI/integration gates use its actual stdio protocol; neither the application nor its companion requires Node.

While developing, run only the gates a change touches. `scripts/gates.json` maps every tracked file to the gates
that exercise it, and a per-checkout ledger remembers the inputs each gate last passed on:
`bash scripts/acceptance.sh --changed` runs the gates whose inputs changed (or that never passed),
`--only pointer,unit` runs named gates, and `--list` shows what would run and why. A targeted run stops at the
first failure and never writes `acceptance.json`; only the full run (no arguments) certifies a tree for release.
`--check-map` fails if a file belongs to no gate or a gate pattern matches no file (a path left behind by a move); `python3 scripts/test-run-gates.py` (also run by the unit gate) checks the
selection, that every test program runs in some gate, and the leak check: each gate runs with a private `TMPDIR`
and fails if it leaves anything there.

## Piece inspection

Select a piece, then press `P` for **Protected by** or `A` for **Attacked by**
while the board has keyboard focus. The Game menu also provides these commands
with `Command-Shift-P` and `Command-Shift-A`. The right drawer lists the related
pieces and explains king-safety restrictions and conditional recaptures.
Curved connectors have no arrowheads: teal indicates protection, red indicates
attacks, and dashed connections indicate restricted or conditional relationships.
During inspection, a click on a playable destination of the inspected piece leaves
inspection and plays the move, so an accidental P or A never makes a legal move
unplayable; any other click inspects. Escape dismisses inspection first; a second
Escape clears selection. A changed position or presentation clears the inspection.

Practice, previews and demonstrations use the displayed full position. En passant,
promotion captures and actual legal recaptures are evaluated without changing the
game. Partial lesson and puzzle diagrams explicitly show square coverage only.
Protection is not a guarantee of safety or a favorable exchange.

## Data and connection isolation

Development data lives in `~/Library/Application Support/ai.xiaolai.checkmate.native-development`.
Automation supplies `--data-dir` and uses a separate bundle identifier.
The native MCP discovery file lives in that data directory's `companion` folder.
The existing adapter accepts its path through `BrokerClient`; registered production
MCP discovery remains separate from development connections. Connections are local,
private and exclusive. The MCP broker may wait in standby while live voice is connected;
it rejects external claims until voice disconnects. A connected external MCP client
prevents voice from taking control.

Live voice uses AVAudioEngine and URLSession WebSocket with ephemeral credentials
minted from the existing account flow. Settings distinguishes local sign-in from
an actual availability check and an established live connection. Supported Realtime
WebSocket protocol: https://developers.openai.com/api/docs/guides/voice-websockets.
No voice credentials, microphone access, or audible output are used by automation.
Real account/device acceptance remains a separate, user-owned check.

## Import and backup

Data → Import Progress accepts a native state export or a legacy archive.
For the legacy app, run `Tools/legacy-export.js` in that window's Web Inspector,
save the returned JSON as a file, then import it. It reads exactly seven progress
and settings keys, never credentials. Imports are validated before mutation and
idempotent by archive hash. The confirmation lists recovered, adjusted and skipped fields. Each replacement preserves a separate pre-import archive; Data → Show Backups reveals the backup folder. Data → Export Progress writes a native export. Each
state write also retains an atomic previous backup. Unsupported/corrupt files are
preserved; opening a bad state never overwrites it.

Development builds remain isolated; signed release packaging is documented in [release packaging](releases.md). See bundled
THIRD_PARTY_NOTICES.txt for engine, rules, artwork and content provenance.

## App icon

`Artwork/Checkmate.icon` is the macOS Icon Composer document. Its full-bleed graphite background is rendered by the system; `Assets/Knight.svg` preserves the existing grayscale artwork with a larger, centered silhouette. `build.sh` requires Xcode 27 and compiles it using `actool` into `Assets.car`, registering the compiled `CFBundleIconName`. The package checker requires both an actual `IconImageStack` for newer macOS and the generated `.icns` fallback for macOS 14/15. Apple-rendered preview and package/relocated launch evidence are in `evidence/icon-20261008/`.

## Rewritten lesson scripts

All 39 lesson entries (34 lessons and 5 practice activities) use the native-owned British-English course and 710 bundled OpenAI Cedar recordings at speed 1.0. [Content/lesson-scripts.en-GB.md](../Content/lesson-scripts.en-GB.md) is the script book; [Content/README.md](../Content/README.md) documents recording, verification and publication. Text, compressed audio, transcript titles, lesson projections and timing are published together. Progress saved by the previous course edition is carried over on load (`ProgressMigration`). Playback is offline.

Thirteen lessons end with an exercise: their last step says "Now try it yourself" and its board is the learner's to play, as White, against the computer. The lesson's `practice` definition gives the position, an optional authored opening (the moves that follow the taught idea, with the computer's answers), checkpoints that count in any order (castle, en passant, promote, a pawn advance and capture, chase the queen, checkmate, or finish the opening), the opponent before success (beginner, or the full-strength defender for the basic checkmates), two hints and the feedback texts. A move that leaves the idea is called out and undone with Undo turn; stalemate, a lost game or a castling that is no longer possible is a recoverable failure with its reason. After success the learner may play on against the beginner opponent. Attempts are saved per lesson (`lessonAttempts`), separately from the practice game, mini-games and training, and replayed on load, so a saved attempt can never claim more than its moves show; `course.practised` records each exercise done. Narration ending on the exercise step never moves on. Elsewhere in the lesson, Go to your turn (or Resume your attempt) leads to the step.

Each practice activity (`practiceFor` in the course content) sits indented under its piece lesson in the sidebar and is off the main path: Continue and automatic continuation go to the next lesson, and the lesson offers a Practise button instead. Pause for practice stops at the end of a lesson that has a game or activity. Lesson mini-games default to human White versus computer Black: Pawn Duel, Rook Sweep, Rooks and Pawns, Bishop Sweep, Bishops and Pawns, Queen Against Pawns, and Knight Capture. Their opponent uses a bounded variant-aware search, without standard-chess king/check rules. Knight Capture's targets are every opposing piece except the knight: taking the knight still ends the game for its owner, and clearing every other piece wins. Counting the knight among the targets made the game a chase that one colour won from every start tested (23 start changes, no exception); excluding it makes the game a race the first player can win, and matches the lesson's "every other piece is a target that stays still" (`MiniGameRules.version` 2). The inspector offers a two-player option and a Difficulty per game, listing only the levels `MiniGameOffering` allows, shown as Gentle, Steady and Strong (stored as `beginner`, `standard` and `challenging`). A game keeps the level it started at (`MiniGameState.level`, checked against its run and a save-time witness); choosing another level during a game offers "Start a new game at" that level. A run at a level its game no longer offers finishes at it, labelled.

The offered levels come from calibration (plan WI-016). `Content/calibration/mini-game-manifest.json` fixes the games, start, sides, reference players (random, greedy, the next level down), 400 games per pairing (the fewest at which a 10-point difference always separates 95% Wilson intervals is 386), half a point per draw and each game's accessibility criterion; `MiniGameCalibration.problems` checks it before any game. On the test host, `swift run -c release CheckmateMiniGameCalibration` plays it with the search deadline off (reproducible: `outcomesDigest`), then plays each level with the production deadline beside a busy thread per core and counts how often the deadline cut the search and changed its move, and writes `Content/calibration/mini-game-results.json` with binary and source identity. A level is offered when its pair with Steady passes (Gentle also needs greedy to score at least 30% against it): either the upper level scores at least 10 points more against greedy with disjoint intervals, or greedy is saturated for the lower level (it scores at least 90% against greedy) and the upper level scores at least 60% against it head-to-head with the interval's lower bound above 50%. `MiniGameCalibrationTests` keeps `MiniGameOffering` equal to those verdicts, fails once a profile is retuned, and re-hashes the source files the results record (`MiniGameCalibration.sourceFiles` and the manifest), so editing any of them means calibrating again. Standard-rule training games are the second entry kind, `standard`, with their own manifest (below). Games are saved separately and Undo takes back a complete human/computer turn. Knight Corners is a solo ordered-corner challenge.

When a competitive mini-game finishes, a sheet lists what a proof search established about it: "you had a forced win in N moves here" and "this move let the opponent force a win in N". Nothing is said during play. `MiniGameProof` (Domain) is separate from the opponent's search, plays only through the referee with the positions back to the last capture or pawn move, and claims a result only when every branch within 9 plies resolved; `MiniGameReview` searches the game's positions from the end backwards within 200,000 nodes a position and 3 s of CPU a review, and `MiniGameReviewer` (Application) runs it off the main actor and drops it on restart, undo, a change of opponent or leaving the game. The spike that fixed these budgets runs with `CHECKMATE_MINI_PROOF_SPIKE=<output.json> swift test -c release -Xswiftc -enable-testing --filter MiniGameProofSpikeTests` on the test host.

With a voice sign-in proved this launch (a successful availability check or connection), the sheet also offers Read Aloud. It opens a session scoped to that review (`MiniGameReviewVoiceScope`: the mini-game place, the game reviewed and the review's generation) with its own lease (`GameSession.openMiniGameReviewVoice`), and reads each fact through `MiniGameReviewVoiceScript`'s exact-text validation as an out-of-conversation script, checked against the spoken transcript. It offers no tools, starts no microphone and answers nothing; closing the sheet, a restart or undo, another place or an MCP companion ends it. `openVoice` still refuses every mini-game, during play and after it. Without a proved sign-in the sheet still offers Read Aloud as a check: pressing it runs the same availability check Settings runs, shows a refusal on the sheet, and reads only if the account authorizes, so nothing is authorized without that press. The `pawn-duel` gate clicks Read Aloud with the silent voice double.

## Game review

Standard game review is available in normal builds without environment variables. The former `CHECKMATE_REVIEW_ENABLED` and `CHECKMATE_REVIEW_DISABLED` flags are no longer used. Automated checks do not substitute for the outstanding human review and novice-play acceptance checks.

Review accepts PGN collections and standard-chess FEN positions from native Open, paste or drop, or the current/previous game. Imported records remain immutable. Recorded variations and imagined lines are separate; “Practise here” starts a separate full-history game after choosing a side and profile and preserving the prior game. FEN-only review cannot recover earlier moves or repetition history.

Custom opponent skill0–20 and the engine's discovered Elo range are independent of full-strength review analysis. Engine Elo is an estimate, not a promised human rating. The beginner opponent remains gated by `CHECKMATE_BEGINNER_OPPONENT_ENABLED=1`. Review grades moves by default (?! inaccuracy, ? mistake, ?? blunder) and analyzes a game when it opens unless Settings ▸ Practice ▸ Analyze When Opened is off; it never analyzes during a network game. Review searches use all but two cores (at least one) and a 128 MB hash, and check up to five key moments more deeply. `ReviewPolicy.batchPlan` fits each game's worst case (two searches per position and per deeper moment, each with an 80 ms overhead) into 80 seconds: long games search each position more briefly, never under the engine's 100 ms minimum (`EngineSearchPolicy.minimumMs`, which the engine's clamp and the plan share), and check fewer moments, so games up to 222 plies fit. A longer game is still analyzed in full at the minimum, past 80 seconds, and stays cancellable and responsive. Only the whole-game analysis uses the shorter budget: a position the learner chooses, and the baseline of a deeper look at it, keep the full 500 ms. The voice coach in review is on by default; `CHECKMATE_REVIEW_VOICE_ENABLED=0` turns it off.

The sidebar Review game destination opens a workspace with visible Open PGN, Paste PGN/FEN and current-game actions; it does not create a document. Native imports and current-game reviews remain drafts until Save Review (Command-S). Saved reviews subsequently autosave cursor and imagined lines. MCP-created reviews keep their existing persistence contract.

Review documents/cursors are stored separately from existing progress. Before downgrading, export each original PGN/FEN and any imagined lines you wish to retain, and copy the native data directory shown in Settings. Older builds do not understand review storage; do not delete it to force compatibility. Newer saved schemas are rejected without destroying their files. This downgrade procedure is documented but has not been validated through an actual older-build round trip.

The installed app bundles `Contents/MacOS/CheckmateMCP`. Settings → Connections →
Set up Codex registers that executable and installs the companion skill if absent.
It preserves an existing customized skill. Codex stores the executable's absolute path,
so run Set up Codex from the app's final location, such as `/Applications`, not from the
mounted disk image, whose path disappears on eject. After moving the app, choose Set up
Codex again, then start a new Codex task; restarting the MCP connection alone relaunches
the old path. Developers can supply an isolated
`--connection-file` to the executable; production uses the app's private discovery.
The executable must run from inside an app bundle: it reports that bundle's
`CFBundleShortVersionString` to MCP clients and refuses to start without one.

## Training

Training is off unless `CHECKMATE_TRAINING_ENABLED=1` is set; with it off the sidebar shows no Training row and every training navigation and tool is refused. The library lists Increment A: eight existing mini-games (their one saved board, original rules, learner White) and seven new exercises. Training records live in the optional `training` object of `state-v1.json`; an unreadable or newer object is kept verbatim and training writes stay off until the learner resets it.

Authored positions live in `Content/training/`. Publish them with `python3 Tools/prepare-training-content.py`; the unit gate runs `--check`, which fails when the published resources differ from the sources. The packager checks structure, duplicates, symmetric twins sharing a cluster and the skill coverage matrix; the Swift `TrainingValidationService` re-derives every answer with the bundled chess.js. `Tools/training-oracle.cjs` is an authoring aid only. Every scenario records `reviewer: null` until an editor reviews it. `Tools/kpk-oracle.py verdict FEN...` gives the exact chess and `promoteAndHold` verdicts of a king-and-pawn start, from a retrograde solver and an independent forward search that must agree; the unit gate compares the two on every legal position (`Tools/test-kpk-oracle.py`).

Increment B (the beginner skills, Guided Games and Mixed Practice) also needs `CHECKMATE_TRAINING_B=1`. Its scenarios carry a teaching graph produced by the bundled training search. The Swift tests re-derive it: `TrainingCatalogTests` checks every published scenario, and `TrainingTreeBudgetTests` re-runs the bounded search over the whole corpus within its node budget. Changing `training-search.js` changes its hash in the manifest, so republish and rerun both. Playable games use the bundled offline Stockfish; their tests use the scripted `ScriptedDefender` from `CheckmateTestSupport` instead.

Position games and opponent levels also need `CHECKMATE_POSITION_GAMES=1` (default off). With it, the library's preview section lists four position games (mini-game plan D2, WI-020), machine-checked but not yet editor-reviewed: Pawn Race (king and one pawn against a king, nine starts on every file, the goal `promoteAndHold`), Pawn War with Kings, Cut-Down Chess (kings and pawns with knights, bishops, rooks, queens, minor or major pieces) and Two-Bishop Mate (`checkmate`, keeping the bishops). The learner plays White. Every start is legal, not over, and its goal is shown reachable in the content manifest's `positionGames`: a pawn race's exact verdict comes from `Tools/kpk-oracle.py`, computed by the content script with the oracle's identity and source hash, and must be a `promoteAndHold` success; a checkmate game names, in `Content/training/position-game-evidence.json`, a line from its start to a position where the bundled engine at a fixed node count reports a forced mate for the learner (`swift run -c release CheckmatePositionGameCalibration witness --nodes 2000000` writes it), and `PositionGameContentTests` repeats every search. Each playable game freezes its opponent level when the attempt starts: Gentle, Steady or Strong, every search a fixed node count. The drawer's Opponent picker lists the levels `MiniGameOffering.levels(entry:variant:check:)` allows: those calibration passed (below), only the fallback (Strong; Steady for a guided game) for an entry that was not calibrated, and Strong alone for the King and queen stalemate trap; with the flag off each game plays its coded strength with no picker, and nothing new is saved. A game in progress keeps its level; choosing another offers "Start a new game at this level". `training-b-pointer` runs with the flag, plays a cut-down game and drives the picker on it. The finish-the-game regression replays `Tests/Fixtures/PositionGames/finish-the-game-sequences.json`.

The standard-rule levels are calibrated like the mini-games (plan D4, WI-020). `Content/calibration/position-game-manifest.json` names each calibrated entry and variant (the four position games, the rook ending and the two guided-game variants), its starts (the published scenarios, which a test keeps equal), the sides the level plays (both colours where either side could be the opponent, else only the opponent's), the references (random, greedy and, for both-colour games, the level below), the scoring (chess: a draw is half a point; goal: the learner's side scores only for a success, as the app counts a draw as a failed goal), 100 games per pairing and each entry's accessibility criterion (greedy scores at least 30% against Gentle). A guided game publishes both learner colours: each of its starts names the learner, the level plays the other side, and the starts take turns so the level plays each colour in half the games. 100 is the fewest games at which a level scoring exactly the head-to-head minimum of 60% passes branch (b); at that size branch (a) needs a larger difference than 10 points in mid-range scores, so the smaller sample only ever makes a pass harder. `swift run -c release CheckmatePositionGameCalibration` plays it on the test host in child processes, each with its own engine, through `PositionGameMatch` (each level as an attempt's frozen opponent plays, judged by the position-game referee), and writes `Content/calibration/position-game-results.json` with the engine's identity, options and node limits, source hashes and timing. Steady is Stockfish at skill 3, whose own randomness is unseeded, so its games are not reproducible move for move; the results report intervals. Levels are offered outward from the fallback: each passes against the nearest level already offered by the same pass rule as the mini-games, branch (b) only between neighbours, and Gentle also needs to be accessible. `PositionGameCalibrationTests` keeps `MiniGameOffering.positionGames` equal to the verdicts and re-hashes the sources the results record (`PositionGameCalibration.sourceFiles` and the manifest).

The voice coach in a standard-rule training game (a playable ending, guided game or position game) also needs `CHECKMATE_TRAINING_VOICE=1` (default off; with it off the coach cannot connect in training, as before). The training bar's microphone and the drawer's Connect Voice Coach open a session bound to that game's attempt, through `TrainingVoiceAdapter` (see architecture.md). Connecting records nothing; the attempt is marked as helped just before the coach first tells the learner anything about the board, and a help that cannot be recorded is answered only with "I can't help with this one." `TrainingVoiceAdapterTests` drive it silently with provider events; `training-b-pointer` connects and disconnects it with real pointer events and the silent voice double. A live session (`scripts/live-voice.sh`) needs the learner's own sign-in and audible output, so it is a user-owned check.

Gates: `unit` (content, validators, sessions, persistence, tools), `training-pointer` (real pointer events for the library, square selection, drag and click moves, hints, suggestions, Pawn Duel from the library, quit and Continue), `training-b-pointer` (Increment B with real pointer events: subskill chips, the promotion chooser, a bridge, an ending and a guided game answered by Stockfish, a mixed case and a related lesson), and the existing `pointer`, `layout`, `lifecycle` and `integration` gates. Learner usability and learning effect are not verified by any gate: see `docs/training-observation.md`.

## Play on Network

The host is authoritative. `CheckmateDomain` holds the protocol, codec, clocks, admission and the host and guest
state machines (`Network*.swift`), with no I/O. `CheckmateApplication` runs them on a scheduler and a transport
interface (`NetworkHostRunner`, `NetworkClientRunner`, `NetworkGameController`); `CheckmateMacPlatform` supplies the
Network.framework transport over TLS with a pre-shared key derived from the code, and Bonjour discovery.
`NetworkParticipation` turns engine help off everywhere while a game is played or watched, and `NetworkPolicy`
decides which macOS versions show the feature. Unit tests drive the domain and runners with an in-memory transport and
a manual clock; `NetworkLoopbackTests` run the real transport on loopback in one process. Real Bonjour stays out of
routine tests: `CHECKMATE_BONJOUR_SMOKE=1` runs the one smoke test by hand.

macOS 27 keeps the local-network decision per bundle ID and enforces it only for executables LaunchServices has
registered. An app run from `build/` or `/tmp`, or a second registered copy, is refused silently: its connection
stays in `preparing` and no prompt appears. Bonjour browsing is not gated, so a list of games proves nothing. The
Bonjour gates therefore install one signed copy at `~/Applications/CheckmateAutomation.app`, unregister every other
copy of the automation bundle ID, register it and open it through LaunchServices (`scripts/network_gate.py`).

A game may be played with agreed assistance (`NetworkAssistance` in the domain): one level per side, `off`,
`insight` (Protected by / Attacked by on the network board), `hints` (a Hint button on the player's own move) or
`guided` (a hint shown at the start of each of the player's moves). At `hints` and `guided` the voice coach may also
connect to that game, with four network-only tools. The host fixes the terms when hosting; the guest accepts them
before joining, the host checks the accepted terms inside TLS before reserving the seat, and the guest checks them
again in every snapshot before acknowledging. The Bonjour TXT value `assist` is for display only. Spectators never
get help. Hints come only from `NetworkAssistant`, on the network game's own position, at skill 20 with a fixed node
count (`go nodes`), so every Mac searches the same amount. A move made after a hint or a voice turn carries
`assisted`, which every player and spectator counts and Review records.

Protocol 1.1's additions are optional fields a 1.0 peer ignores, so a game without assistance stays open
to a 1.0 guest; a guest that states no terms is refused, as another version, by a host whose game has assistance.
Byte fixtures from the 1.0 codec (`NetworkLegacyFixtures`) keep both directions honest. A 1.0 spectator may still
watch a game with assistance and does not see its terms; it cannot play, so this is stated rather than prevented.

Protocol 1.2 (`docs/network-protocol-1.2.md`, mini-games plan D7, L1) adds a declared start: ordinary chess from a
chosen position. Every `hello` and `resume` states the peer's `capabilities`; a game from a declared start requires
`start`, and the host refuses a connection that does not state it with `bye(protocolVersion)` before attaching it,
unpausing clocks or sending a snapshot. The record carries `startFEN` only when the start is not the standard one, a
receiver pins the start at its first snapshot and refuses any other later, and hosting refuses a start that is
illegal or already over. The host picks only a game-library position (the position after one of a library game's
moves), and only with `CHECKMATE_NETWORK_POSITIONS=1`; otherwise hosting uses the standard start exactly as 1.1 does.
`Legacy11Fixtures` and `Legacy11CoreFixtures`, frozen from the 1.1 code, hold the compatibility promise: a 1.2 Mac
decodes every 1.1 message, and a standard-start game writes its record, crash file, review record and TXT entries
byte for byte as 1.1 did.

Protocol 1.3 (`docs/network-protocol-1.3.md`, mini-games plan WI-024, L2) adds the competitive mini-games, played by
their referee (`MiniGameState`) through `NetworkMiniGame`, the same `NetworkChessRules` and `NetworkBoardModel` seam a
chess game uses. The record names a ruleset, `mini:<kind>@<rules version>`, and carries the move list; the game
requires that ruleset's capability, so a peer without it is refused before it is attached. The hashed state is the
board, the side to move, the pending finish and every position since the last capture or pawn move, so equal boards
with different histories hash differently. Receivers check every rules-decided ending against their own replay, and
a ruleset this build does not support, an unstated one or one that changes mid-game is refused before any replay.
Solo kinds are never offered or accepted, and a mini-game has no assistance. The host's Play picker appears only with
`CHECKMATE_NETWORK_MINI_GAMES=1`; with the flag off, hosting is chess exactly as 1.2. The TXT `variant` entry is only
the lobby's badge. A mini-game's crash file is its own (`current-ruleset.json`), which no 1.2 build reads, and Review
is the proof-search review over the whole game rather than a chess record. `Legacy12Fixtures` and
`Legacy12CoreFixtures`, frozen from the 1.2 code, hold the compatibility promise for 1.2 messages and for a chess
game from a declared start.

`NetworkParticipation` still turns engine help off everywhere else while participating:
`FairnessPolicy.engineHelpAllowed` is unchanged, and the scoped `networkAssistance` level opens only the network
game's hint and voice coach. `Tests/fairness-inventory.json` lists every engine call and voice entry by kind:
`guarded` (checks `engineHelpAllowed`), `delegated`, `exempt`, `assisted` (only `NetworkAssistant`, which checks
`requireNetworkHint()` before and after its search) and `voice` (only `VoiceCoach`, which checks
`voiceAllowed(network:)` first). `scripts/test-fairness-inventory.py` fails an unlisted call, and a site listed under
a kind whose check it lacks.

Three gates cover the interface, each with real pointer and key events:

| Gate | Where | What |
|---|---|---|
| `network-ui` | test host, loopback | host, guest and spectator; pending move, refused spectator click, drop and resume, draw offer, resign, Review; assistance: no help without it, the list badge, Decline then Accept, a hint counted on both boards, the inspector, a handicap; light and dark |
| `network-bonjour` | test host | two installed copies find each other over Bonjour, join, play, resign and review; permission state recorded |
| `network-lan` | test host and LAN pair | a game from a game-library position (Légal's mate after 5. Nxe5, Black to move) played to mate and watched, reviewed from its start; Pawn Duel listed with its badge, played to a far-rank win and watched, its proof-search review opened on both Macs; then the test host hosts a game with hints for both and watches, the pair accepts and joins, each player asks for a hint and every Mac counts both, the pair drops and resumes, play to checkmate, Review on both with the Assistance line |

The last two need evidence prepared once per Mac, checked before anything builds; a missing or stale record makes
the gate UNVERIFIED, never skipped. `bash scripts/automation-identity.sh create` makes the stable local signing
identity once per test host. `bash scripts/prepare-bonjour.sh` (and `--pair` for the LAN pair) installs the app,
runs its Bonjour self-check, answers the local-network prompt with a real click, and writes
`~/.config/checkmate/bonjour-ready.json`. The record names the identity, bundle ID, account and macOS build, and
any change invalidates it. The LAN pair is named by `CHECKMATE_LAN_PAIR` in the test host's shell profile, as an SSH
destination; it needs the same Accessibility, Screen Recording and unlocked console as a test host, and it never
builds: it runs the app the test host built and signed.

Two switches exist only in isolated automation. `CHECKMATE_NETWORK_LOOPBACK_DIR` replaces Bonjour with a shared
folder, for `network-ui`. Each record there names its publisher's process, and a record whose process has ended is
dropped, as a Bonjour registration is, so an instance stopped by a signal leaves no game behind in the list. `CHECKMATE_NETWORK_FAULT_FILE` names a file the app polls: `10` drops its connections and
refuses reconnecting for 10 seconds, and `stall 4` holds its outgoing messages for 4 seconds. A gate writes the file
over SSH, so the control channel is never cut. A real cable or Wi-Fi loss is not automated, and neither is a real
local-network denial: unit tests drive the denial path (help sheet, no timeout, recovery once granted) through the
in-memory transport, and the gates record only that access was allowed.

## Compatibility checks

`Version.env` owns the macOS runtime floor. Builds contain arm64 and x86_64 slices
in the application, native MCP companion, and unchanged Stockfish engine. Package
verification checks all three slices and their deployment versions, as well as
modern and legacy icons. The `intel` acceptance gate (`scripts/test-intel.sh`) runs the silent Intel
unit, UI, and MCP acceptance under Rosetta on the test host in every full run, and in targeted runs when an
architecture-dependent input (build settings, the engine, the rules runtime) changes. These tests do not substitute for a
physical Intel Mac or macOS 14 runtime acceptance.

## Automatic startup connections

After the main window opens, Checkmate makes one bounded Codex voice availability check.
Successful authorization is reused for voice connection, without a second credential request.
`voiceAutoConnect` controls startup voice and `companionAutoStart` controls the private MCP broker.
Voice is opt-in: `voiceAutoConnect` defaults off for missing preferences (a saved value is kept),
and startup voice also needs `voiceConsent`, which only the learner's answer to the one-time
consent sheet sets. Every Connect button goes through `NativeModel.connectVoiceWithConsent`.
The voice option no longer reconnects on every visit to Practice. Settings provides manual
connection controls independently of startup preferences.

Automatic MCP starts only when Codex's configuration (`$CODEX_HOME/config.toml`, read as a file,
never through `codex`) has a Checkmate registration. It publishes the existing private discovery
file without editing Codex configuration or spawning a host task. Set up Codex remains explicit,
and a registration that points at another copy of Checkmate is offered Repair Codex Setup.
A failed automatic start is logged and shown in Settings → Connections.
Voice authorization failure does not prevent local MCP availability. If both are enabled,
the broker waits in standby while voice owns the session. A learner action, navigation, hide,
shutdown or preference change during the check cannot be overwritten by its late completion.
There are no background retries. Automation skips startup checks, network access, and audio.
