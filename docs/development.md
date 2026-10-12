# Checkmate development

macOS 14+ AppKit/SwiftUI application for Apple Silicon and Intel. Practice with bundled Stockfish, 40 lessons,
87 puzzles, reversible candidate previews and demonstrations, native
settings, local MCP companion and native live voice transport. No web view or
JavaScript UI runtime. JavaScriptCore runs the existing chess.js rules only.

## Module boundaries

See [architecture.md](architecture.md) for target ownership, service contracts and the remaining Windows work.
`CheckmateCore` is a compatibility facade. New shared code imports its owning module; application workflows
cannot depend on the Stockfish implementation or macOS services. Domain, application/service integration,
native UI and MCP tests have separate test targets. The architecture gate rejects dependency regressions.

## Build and run

Development execution runs on a test host, never the main Mac: build-host, or test-host for end-to-end testing.
`scripts/test_host.py` lists them, and acceptance refuses any other Mac. Release builds, recording import and the
Stockfish build stay on build-host. A test host needs Xcode 27 selected with its licence accepted, Rosetta for the Intel gate,
a logged-in GUI session whose display never sleeps, and Accessibility and Screen Recording permission for the remote
login session that drives the pointer. From the repository root:

```sh
bash build.sh
open build/CheckmateNative.app
```

`CHECKMATE_AUTOMATION=1 swift test` runs all four test suites silently. `bash scripts/acceptance.sh` runs silent isolated
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
pieces and explains castling restrictions and conditional recaptures.
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

All 40 lessons now use the native-owned British-English rewrite and 878 bundled OpenAI Cedar recordings at speed 1.0. [Content/lesson-scripts.en-GB.md](../Content/lesson-scripts.en-GB.md) is the script book; [Content/README.md](../Content/README.md) documents recording, verification and publication. Text, compressed audio, transcript titles, lesson projections and timing are published together, preserving actions, answer keys and saved progress. Playback is offline.

Lesson mini-games default to human White versus computer Black: Pawn Duel, Rook Sweep, Rooks and Pawns, Bishop Sweep, Bishops and Pawns, Queen Against Pawns, and Knight Capture. Their opponent uses a bounded variant-aware search, without standard-chess king/check rules. The inspector offers a two-player option. Games are saved separately and Undo takes back a complete human/computer turn. Knight Corners is a solo ordered-corner challenge.

## Game review

Standard game review is available in normal builds without environment variables. The former `CHECKMATE_REVIEW_ENABLED` and `CHECKMATE_REVIEW_DISABLED` flags are no longer used. Automated checks do not substitute for the outstanding human review and novice-play acceptance checks.

Review accepts PGN collections and standard-chess FEN positions from native Open, paste or drop, or the current/previous game. Imported records remain immutable. Recorded variations and imagined lines are separate; “Practise here” starts a separate full-history game after choosing a side and profile and preserving the prior game. FEN-only review cannot recover earlier moves or repetition history.

Custom opponent skill0–20 and the engine's discovered Elo range are independent of full-strength review analysis. Engine Elo is an estimate, not a promised human rating. Experimental features remain separately gated by `CHECKMATE_REVIEW_QUALITY_LABELS=1`, `CHECKMATE_REVIEW_VOICE_ENABLED=1` and `CHECKMATE_BEGINNER_OPPONENT_ENABLED=1`.

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

Authored positions live in `Content/training/`. Publish them with `python3 Tools/prepare-training-content.py`; the unit gate runs `--check`, which fails when the published resources differ from the sources. The packager checks structure, duplicates, symmetric twins sharing a cluster and the skill coverage matrix; the Swift `TrainingValidationService` re-derives every answer with the bundled chess.js. `Tools/training-oracle.cjs` is an authoring aid only. Every scenario records `reviewer: null` until an editor reviews it.

Increment B (the beginner skills, Guided Games and Mixed Practice) also needs `CHECKMATE_TRAINING_B=1`. Its scenarios carry a teaching graph produced by the bundled training search. The Swift tests re-derive it: `TrainingCatalogTests` checks every published scenario, and `TrainingTreeBudgetTests` re-runs the bounded search over the whole corpus within its node budget. Changing `training-search.js` changes its hash in the manifest, so republish and rerun both. Playable games use the bundled offline Stockfish; their tests use the scripted `ScriptedDefender` from `CheckmateTestSupport` instead.

Gates: `unit` (content, validators, sessions, persistence, tools), `training-pointer` (real pointer events for the library, square selection, drag and click moves, hints, suggestions, Pawn Duel from the library, quit and Continue), `training-b-pointer` (Increment B with real pointer events: subskill chips, the promotion chooser, a bridge, an ending and a guided game answered by Stockfish, a mixed case and a related lesson), and the existing `pointer`, `layout`, `lifecycle` and `integration` gates. Learner usability and learning effect are not verified by any gate: see `docs/training-observation.md`.

## Compatibility checks

`Version.env` owns the macOS runtime floor. Builds contain arm64 and x86_64 slices
in the application, native MCP companion, and unchanged Stockfish engine. Package
verification checks all three slices and their deployment versions, as well as
modern and legacy icons. The `intel` acceptance gate (`scripts/test-intel.sh`) runs the silent Intel
unit, UI, and MCP acceptance under Rosetta on build-host in every full run, and in targeted runs when an
architecture-dependent input (build settings, the engine, the rules runtime) changes. These tests do not substitute for a
physical Intel Mac or macOS 14 runtime acceptance.

## Automatic startup connections

After the main window opens, Checkmate makes one bounded Codex voice availability check.
Successful authorization is reused for voice connection, without a second credential request.
`voiceAutoConnect` controls startup voice and `companionAutoStart` controls the private MCP broker.
Both default on for missing preferences; explicitly saved voice opt-outs remain off.
The voice option no longer reconnects on every visit to Practice. Settings provides manual
connection controls independently of startup preferences.

Automatic MCP starts only when Codex is installed. It publishes the existing private discovery
file without editing Codex configuration or spawning a host task. Set up Codex remains explicit.
Voice authorization failure does not prevent local MCP availability. If both are enabled,
the broker waits in standby while voice owns the session. A learner action, navigation, hide,
shutdown or preference change during the check cannot be overwritten by its late completion.
There are no background retries. Automation skips startup checks, network access, and audio.
