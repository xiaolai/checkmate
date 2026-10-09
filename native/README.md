# Checkmate native

macOS 27 AppKit/SwiftUI application. Practice with bundled Stockfish, 40 lessons,
83 quizzes, 87 puzzles, reversible candidate previews and demonstrations, native
settings, local MCP companion and native live voice transport. No web view or
JavaScript UI runtime. JavaScriptCore runs the existing chess.js rules only.

## Build and run

All development execution stays on build-host. From its native checkout:

```sh
bash build.sh
open build/CheckmateNative.app
```

`CHECKMATE_AUTOMATION=1 swift test` tests the core silently. `bash scripts/acceptance.sh` runs silent isolated
native tests, packaged UI scenarios, the existing MCP adapter against the native
broker, a temporary WebKit legacy-store exporter test, and resource checks.
The WebKit helper is a test executable, never part of the application. Its export is reimported by the deterministic migration test. The aggregate includes 483 sampled layout frames, constrained/fullscreen checks, lifecycle/restart tests, 1000 command transitions and 20 connection cycles. Automation does not enable VoiceOver or change accessibility preferences.
UI/integration gates require the MCP adapter built with `pnpm companion:build` from the repository root. Normal offline play needs neither Node nor Homebrew installed.

## Piece inspection

Select a piece, then press `P` for **Protected by** or `A` for **Attacked by**
while the board has keyboard focus. The Game menu also provides these commands
with `Command-Shift-P` and `Command-Shift-A`. The right drawer lists the related
pieces and explains castling restrictions and conditional recaptures.
Curved connectors have no arrowheads: teal indicates protection, red indicates
attacks, and dashed connections indicate restricted or conditional relationships.
Inspection clicks never play moves. Escape dismisses inspection first; a second
Escape clears selection. A changed position or presentation clears the inspection.

Practice, previews and demonstrations use the displayed full position. En passant,
promotion captures and actual legal recaptures are evaluated without changing the
game. Partial lesson and puzzle diagrams explicitly show square coverage only.
Protection is not a guarantee of safety or a favorable exchange.

## Data and connection isolation

Development data lives in `~/Library/Application Support/ai.xiaolai.checkmate.native-development`.
Automation supplies `--data-dir` and uses a separate bundle identifier.
The native MCP discovery file lives in that data directory's `companion` folder.
The existing adapter accepts its path through `BrokerClient`; normal registered
legacy MCP discovery remains untouched during migration. Connections are local,
private and exclusive. Enabling live voice requires disconnecting external MCP.

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

Development builds remain isolated; signed release packaging is documented in [RELEASE.md](RELEASE.md). See bundled
THIRD_PARTY_NOTICES.txt for engine, rules, artwork and content provenance.

## App icon

`Artwork/Checkmate.icon` is the macOS Icon Composer document. Its full-bleed graphite background is rendered by the system; `Assets/Knight.svg` preserves the existing grayscale artwork with a larger, centered silhouette. `build.sh` requires Xcode 27 and compiles it using `actool` into `Assets.car`, registering the compiled `CFBundleIconName`. The package checker requires an actual `IconImageStack`, rather than accepting a flattened bitmap. Apple-rendered preview and package/relocated launch evidence are in `evidence/icon-20261008/`.

## Rewritten lesson scripts

All 40 lessons now use the native-owned British-English rewrite and 947 bundled OpenAI Cedar recordings at speed 1.0. [Content/lesson-scripts.en-GB.md](Content/lesson-scripts.en-GB.md) is the script book; [Content/README.md](Content/README.md) documents recording, verification and publication. Text, compressed audio, transcript titles, quiz projections and timing are published together, preserving actions, answer keys and saved progress. Playback is offline.

Lesson mini-games default to human White versus computer Black: Pawn Duel, Rook Sweep, Rooks and Pawns, Bishop Sweep, Bishops and Pawns, Queen Against Pawns, and Knight Capture. Their opponent uses a bounded variant-aware search, without standard-chess king/check rules. The inspector offers a two-player option. Games are saved separately and Undo takes back a complete human/computer turn. Knight Corners is a solo ordered-corner challenge.

## Game review development pilot

Enable review with `CHECKMATE_REVIEW_ENABLED=1` when launching the native app. `CHECKMATE_REVIEW_DISABLED=1` overrides it; isolated silent automation enables review automatically. Review is not enabled by default until the human acceptance checks is complete.

Review accepts PGN collections and standard-chess FEN positions from native Open, paste or drop, or the current/previous game. Imported records remain immutable. Recorded variations and imagined lines are separate; “Practise here” starts a separate full-history game after choosing a side and profile and preserving the prior game. FEN-only review cannot recover earlier moves or repetition history.

Custom opponent skill0–20 and the engine's discovered Elo range are independent of full-strength review analysis. Engine Elo is an estimate, not a promised human rating. Experimental features remain separately gated by `CHECKMATE_REVIEW_QUALITY_LABELS=1`, `CHECKMATE_REVIEW_VOICE_ENABLED=1` and `CHECKMATE_BEGINNER_OPPONENT_ENABLED=1`.

Review documents/cursors are stored separately from existing progress. Before downgrading, export each original PGN/FEN and any imagined lines you wish to retain, and copy the native data directory shown in Settings. Older builds do not understand review storage; do not delete it to force compatibility. Newer saved schemas are rejected without destroying their files. This downgrade procedure is documented but has not been validated through an actual older-build round trip.
