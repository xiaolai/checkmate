# Module ownership

Checkmate uses SwiftPM targets to enforce dependency direction. Native windows remain AppKit/SwiftUI; shared application behavior lives below the native host. `Package.swift` is the authoritative dependency graph, and `scripts/test-module-boundaries.py` checks both that graph and source imports. Its negative fixtures verify that forbidden imports, reverse dependencies and implementation in the compatibility facade fail the gate.

| Target | Owns | Platform considerations |
| --- | --- | --- |
| CheckmateAssets | Bundled chess.js, Stockfish, lessons, recordings, schemas and licenses; resource lookup | Source assets remain in `Sources/CheckmateCore/Resources`; the bundle is `Checkmate_CheckmateAssets.bundle` |
| CheckmateDomain | Saved-state models, chess/engine values, activity, course content, mini-game rules, opponent policies, engine and narration contracts | Foundation/CoreFoundation only, plus asset lookup; no UI, process, observation or service SDK |
| CheckmateSupport | Error projection, schema validation, JSON projections, hashes, logs, data-directory policy | CryptoKit and OSLog require platform replacements for Windows |
| CheckmateRules | Chess rules facade and isolated script-runtime contract | Current default adapter uses JavaScriptCore; injected factories survive copy and restore |
| CheckmateEngine | Stockfish process lifecycle, UCI protocol, canonical move validation, NNUE identity and search cancellation | Current implementation uses Foundation Process, Darwin and Combine |
| CheckmateContent | Localization/recording packs, language jobs, Codex and voice gateways, usage accounting, companion installation | No application-controller or native-UI dependency; subscription/CLI/filesystem behavior still requires platform validation |
| CheckmateApplication | Practice, learning, reviews, beginner opponent selection, persistence, migration, tool routing and workspace entry | Depends on the engine protocol in Domain; no dependency on the Stockfish implementation or macOS service module. Current controllers use Combine |
| CheckmateMacPlatform | Narration, voice audio/transport, companion HTTP broker and window geometry | AVFoundation, CoreAudio, Network, Security and CoreGraphics |
| CheckmateCore | Compatibility exports only | Imports all modules for existing consumers; new shared code must import its owner instead |
| CheckmateNative | Windows, toolbar, drawers, settings, board rendering, user prompts and native composition | AppKit/SwiftUI; the released and automation identities remain separate |
| CheckmateMCPKit / CheckmateMCP | MCP SDK adapter, discovery and stdio transport | Existing MCP schemas and errors are unchanged |

`CheckmateDomain` and `CheckmateApplication` are library products. Targets cannot import upstream consumers or native UI. The application does not cast an engine to `NativeEngine`; `EngineService` requires history-aware searches, search-move constraints, strength profiles and metadata. Cancellation remains Swift task cancellation, implemented by the Stockfish worker's generation-scoped cancellation handler. Position-only fake engines belong exclusively to `CheckmateTestSupport`.

`ChessRules` accepts a factory for an isolated `ChessScriptRuntime`. Its default is the current JavaScriptCore adapter. Copies and staged PGN restoration reuse that factory, preserving independent game state and the existing chess.js behavior. A replacement runtime must implement the same script/JSON contract.

## Workspace lifecycle

`WorkspaceTransitionCoordinator` prepares review restoration, imported progress and practice forks from a review before the host leaves its current activity. It also owns entry into practice, lessons, puzzles and reviews. `NativeModel` keeps modal consent, generation checks, unsaved review snapshots, backup writes, native service teardown and save notifications. Existing order remains: consent and stale-request checks, fallible preparation and backup, exit, then entry. A failed preparation does not change the activity or board.

A lesson's exercise is not a workspace transition. `LessonAttemptController` (Application) runs it on the lesson's own invitation step, saves it in `ApplicationState.lessonAttempts` and never touches the practice game; `LessonAttemptJudge` decides where an attempt stands by replaying its moves against the lesson's `practice` definition.

This extraction intentionally keeps native lifecycle effects with the host. Any new frontend must implement those host responsibilities, including save failures, stale modal requests, pending imports and explicit resume after a failed restore.

The bottom control bar is one pure model, `ControlBarModel` (CheckmateNative/ControlBar.swift), built from the
state shown, and one view that draws it. Status sits at the leading edge, tools at the trailing edge and the centre
group centred under the board; when the sides no longer fit beside it the bar takes a second row and the board
yields the height. In a lesson the centre always holds the same four slots (from the start, previous, play, next),
so none moves as the learner steps through, the exercise step included. The Lesson menu performs the bar's own
controls, so menu and bar never disagree. Each symbol has one meaning, checked by `ControlBarModelTests`.
The window keeps its fixed shape (a square board area plus any open drawers) and its 600-point minimum; the
layout gate measures every bar control in practice, a lesson and an exercise from 780 down to 320 points, and
requires no overlap and nothing outside the bar at every size, and one row from the minimum up.

## Adding features

1. Put values, saved-state fields and pure policy in Domain. Preserve Codable keys and unknown-field round trips.
2. Put workflows in Application, using Domain contracts. Add native or external services below the appropriate adapter boundary; never import native UI into a workflow.
3. Implement user interaction and composition in the native host. Keep real games and hypothetical boards separate.
4. Add regression tests to the owning test suite. Domain tests import only Domain; native interaction tests live in `CheckmateNativeTests`; integration and controller tests live in `CheckmateCoreTests`.
5. Update `scripts/gates.json` when a file moves or a new responsibility is added. Run the architecture gate, map and gate-selection checks on the test host, then only the acceptance gates the change touches.

## A future native Windows app

These boundaries make reusable behavior identifiable and prevent new UI dependencies from spreading into it. They do not establish a working Windows build. The current manifest and released products target macOS.

A Windows implementation still needs a native frontend, an alternative chess.js runtime, a Windows Stockfish process adapter, audio/device/network/credential adapters, platform logging/hashing and a replacement or bridge for Combine observation. It must also validate Foundation/CoreFoundation support, CLI discovery, data paths, resource packaging and engine cancellation on Windows. Keep existing saved-state and MCP formats at those boundaries.

Choose the Windows frontend and interoperability strategy before implementing it. A Swift Windows host can consume the library products where supported. A WinUI/C# or C++ host needs an explicit bridge or service protocol; Swift target boundaries alone do not provide that ABI. Avoid duplicating chess and learning behavior in the new UI. A later portability phase should replace the remaining runtime dependencies behind these boundaries, with tests on a Windows host.

## Training

Training is default-off (`CHECKMATE_TRAINING_ENABLED=1` enables it in development and automation). Its values are portable: definitions, geometry, scenarios and saved training records live in Domain; legality, sessions, progress and the legacy-game bridge live in Application; the library and panels live in the native host.

| Concern | Owner | Notes |
| --- | --- | --- |
| Catalog, objectives, rule modes, illegal-input policy | `CheckmateDomain/TrainingDefinition.swift` | Finite objective set; each entry declares `movementDrill`, `simplifiedVariant`, `recognitionDiagram` or `standardChess` and shows plain rules. No executable content. |
| Exact geometry and movement BFS | `CheckmateDomain/TrainingGeometry.swift` | Pinned pieces still attack; rays stop at the first piece. Legal chess queries stay in Rules. |
| Authored sources and coverage matrix | `Content/training/` | Published to `Resources/training/` by `Tools/prepare-training-content.py`; `--check` runs in the unit gate. |
| Truthful activity projection | `CheckmateApplication/TrainingProjection.swift`, `GameSession` | Never contains accepted answers, solution sets or scheduled replies. |

### Activity and protocol audit (WI-001)

The legacy-game origin is part of the activity: `Place.miniGame(lessonIndex:Int?,kind:)` has a real lesson index when a lesson opened the game and `nil` when the library did. New places are `.trainingLibrary` and `.training(entry:)`; all three library places have `NativeMode.training`. A review opened over any of them returns there, because `ReviewVisit.returnTo` carries the place. There is no second origin flag.

Consumers of `Place` and `NativeMode`, and their training behaviour:

| Consumer | Behaviour in training |
| --- | --- |
| `GameSession.publicState()` (`get_session`, `wait_for_change`) | `mode: "training"`, `trainingProtocol: 1`, `training` projection; `capabilities` lists the training tools the current view offers when they are attached, and is empty otherwise. Lesson-launched mini-games and practice payloads are unchanged. |
| `GameSession.setLesson` / `setTraining` | Each writes only in its own mode, so a late lesson publish cannot paint over training. Leaving training clears its projection. |
| `CompanionTools` practice tools (`get_legal_moves`, `inspect_piece`, `analyze_position`, `preview_move`, `demonstrate_line`, `play_move`, `get_turn_brief`) | `UNSUPPORTED_MODE`: they require practice. |
| `CompanionTools` `show_annotation` / `clear_annotations` | `UNSUPPORTED_MODE`: the training activity has no lesson board, so unrecorded agent help cannot reach an assessment. |
| `GameSession.openVoice`, `VoiceCoach.changed`, `NativeModel.voiceMayConnect` | Voice requires practice: it cannot connect in training and disconnects on entering it. |
| `LearningPlayer` mini-game scheduling, restart, profile change, reply callbacks | Keyed to the mini-game place, not lesson mode, so library-launched games keep the original opponent and rules. `leaveMini` returns to the opening lesson or the library. |
| Native sidebar, details drawer, transport, menus, drag rules | Training branches (WI-004). |

Protocol impact: `mode` gains the value `training`. A strict client that rejects unknown mode values must be updated before training is enabled for users; no old-client compatibility is claimed. The training projection is protocol version 1. There is no second registered MCP server.

### Companion training tools (WI-007)

`CheckmateApplication/TrainingTools.swift` adds five tools, routed by `CompanionTools` and attached only when training is enabled: `list_training_entries` (read-only), `start_training`, `submit_training_action`, `request_training_hint` and `end_training_attempt`.

| Contract | Rule |
| --- | --- |
| Consent | `start_training` works only while the learner is already in Training; it never leaves a game, lesson or review (`LEARNER_CONSENT_REQUIRED`). |
| Identity | Mutations name `attemptId` and `sessionRevision` from the projection, plus the session `revision`; anything older is `STALE_STATE`. |
| Assistance | Every agent submission or hint marks the attempt as recorded help before it applies, so it can never count as a first try with no recorded help. |
| Disclosure | Results carry only the projection. Agent hints stop at level 2 (`HINT_LIMIT`); revealing the answer is the learner's choice in the app. |
| Ownership | The voice lease is refused (`ROLE_FORBIDDEN`); a review over an exercise owns the board (`REVIEW_ACTIVE`); generic practice and annotation tools stay `UNSUPPORTED_MODE`. |
| Parity | Tools call the same controller methods as the board and drawer, so both reach the same result. |
| Defender | While the practice defender of a playable game is choosing its reply, `submit_training_action` returns `BUSY`. |

### Increment B: beginner skills (WI-009 to WI-013)

Increment B is a preview behind a second flag: its entries appear only with `CHECKMATE_TRAINING_B=1` as well as `CHECKMATE_TRAINING_ENABLED=1` (`TrainingRolloutPolicy.beginnerEnabled`), and the library labels them as machine-checked but not yet editor-reviewed.

| Concern | Owner | Notes |
| --- | --- | --- |
| Evaluator per scenario | `TrainingCheck` in `CheckmateDomain/TrainingScenario.swift` | Each focused variant fixes its evaluator; a mixed case names one from a fixed set. `TrainingTask` (move, select, choose, game) follows from it. |
| Material values, defence-method tags, fork and pin geometry | `CheckmateDomain/TrainingMaterial.swift`, `TrainingRelationship.swift` | Tags and motifs explain technique only; whether a move works is decided by the search. |
| Bounded search | `Resources/training-search.js`, run by `TrainingContinuationValidator` | Threshold search over N plies, then captures-only quiescence (all evasions in check); mate before material; draws count only when the goal allows them; 32,000 nodes per scenario, and exhaustion certifies nothing. Its hash is pinned in the content manifest. |
| Teaching graph | `TrainingTeachingNode` | Each node has a position fingerprint, the complete accepted set and a reply per playable move. The runtime plays this immutable graph and never searches; a fingerprint mismatch withdraws the scenario without counting anything. Offline (`deep:`) validation re-derives every node. |
| Special rules | `CheckmateApplication/TrainingSpecialRules.swift` | Castling and en-passant reasons are sets; questions must have exactly one. King-onto-rook is a rule error in castling tasks. |
| Playable endings and guided games | `CheckmateApplication/TrainingEndgameController.swift`, `TrainingGuidedGame.swift` | The injected `EngineService` answers with the whole history from the start (`.skill(20)` for endings, `.skill(3)` for guided games, 300 ms). A reply is checked against the attempt and revision it was asked for and for legality before it is saved as a `.reply` action; a failure pauses the game and is never counted. Claimable draws need a claim; insufficient material, fivefold repetition and the 75-move rule end the game. |
| Position games and opponent levels | `CheckmateDomain/PositionGames.swift`, `CheckmateApplication/TrainingOpponent.swift` | Behind `CHECKMATE_POSITION_GAMES` (mini-game plan WI-017). `positionGame` plays to `checkmate` or `promoteAndHold`, keeping the piece types `keep` lists; `PositionGameReferee` is the closed outcome matrix (mate, being mated, stalemate, automatic draw, a claim, a lost kept piece, the tracked pawn taken, the new piece taken at once, the new piece held through the reply). A game attempt freezes its opponent in `TrainingSessionSnapshot.opponent`: Gentle (`BeginnerOpponent`), Steady (`.skill(3)`) or Strong (`.skill(20)`), every search node-limited through `EngineService`'s limit-and-`searchMoves` overload; `OpponentStrategy` chooses the reply. The configuration names its attempt (another attempt's is ignored) and a witness revision (behind means an older build played on: `mixed`); an attempt from before levels plays today's 300 ms search as `legacy`. Attempts record `level` and `levelPolicy`. |
| Guided-game review | `TrainingGuidedGame.swift` | Habit notes (castling rights, a piece left to be taken, early queen moves) are labelled "worth reviewing" and never grade a move. Up to two moments per game come from exact mate-in-one detectors and are retried as `.moment` scenarios, marked as practice. |
| Mixed practice | `TrainingMixedController.swift` | Prompts and hints name no topic; the topic is shown after the answer. The next case prefers a fresh one whose primary skill differs from the previous case. Reused positions name their `source` and keep its cluster. |
| Bridges and lesson links | `TrainingScenarioProvider.bridge(for:)`, `Place.lesson(index:fromTraining:)` | Each family of existing games links one normal-chess case. A lesson opened from a training link keeps the course bookmark, and its transport leads back to training. |
