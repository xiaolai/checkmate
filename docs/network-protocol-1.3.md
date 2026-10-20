# Network protocol 1.3: simplified mini-games (LAN L2)

Protocol 1.3 lets two people play one of the simplified-rule mini-games over the network (mini-games plan D7, "L2",
WI-024): Pawn Duel, Rook Sweep, Rooks and Pawns, Bishop Sweep, Bishops and Pawns, Queen Against Pawns and Knight
Capture. The game is judged by the mini-game referee (`MiniGameState.winner`, `drawReason`, `play` and
`MiniGameRules.moves`), the same one the lessons and the computer opponent use, never by chess rules. Everything not
named here is exactly 1.2 (`docs/network-protocol-1.2.md`).

The host chooses a mini-game in the host sheet only with `CHECKMATE_NETWORK_MINI_GAMES=1` (off by default). With the
flag off, hosting is exactly 1.2. Joining and watching a mini-game need no flag: every 1.3 build plays and verifies
each ruleset it states.

## The ruleset descriptor

A mini-game's rules are named by one descriptor, `mini:<kind>@<rulesVersion>`:

- `<kind>` is the `MiniGameKind` raw value (`pawn-duel`, `rook-sweep`, `rooks-and-pawns`, `bishop-sweep`,
  `bishops-and-pawns`, `queen-vs-pawns`, `knight-capture`);
- `<rulesVersion>` is `MiniGameRules.version` written in decimal without leading zeros (2 today). That constant is
  bumped whenever anything the game depends on changes: the referee (`winner`, `victory`, `drawReason`, `play`,
  `advance`, `MiniGameRules.moves`), everything they read (`canMove`, `delayedFinish`, `CourseLibrary.pawnMoves`, the
  repetition and no-progress constants) and the kind's initial board. So two builds that state the same descriptor
  start from the same board and judge every move and every ending identically. A test freezes each kind's initial
  board and a terminal trace per kind, so changing either without the bump fails.

The descriptor is at most 24 bytes (`mini:bishops-and-pawns@2`). A string that is not exactly this shape, names a kind
this build does not know, names a solo kind (Knight Corners, which has no opponent), or names another rules version is
not a ruleset this build supports. **Solo kinds are refused everywhere**: the host sheet never offers one, a host
cannot be given one (`NetworkRuleset(_:)` is nil for a solo kind, so host settings
cannot name it), no build states its capability, and a record naming one
is refused like any unsupported ruleset.

The descriptor fixes the whole start: each kind has one initial board (`MiniGameKind.initialBoard`), White to move,
no history. A ruleset game therefore never has a `startFEN`; a record with both is malformed.

## Fields added

| Where | Field | Value | Written |
|---|---|---|---|
| `NetworkHostSettings` | `ruleset` | the descriptor, or nil | nil for chess |
| `NetworkPublicGame` (snapshot record, crash file) | `ruleset` | the descriptor | only for a ruleset game |
| `NetworkPublicGame` | `pgn` | the ruleset record (below) instead of PGN | for a ruleset game |
| `ended.termination` | six new values (below) | | only on a connection that negotiated the ruleset |
| Bonjour TXT | `variant` | the descriptor | only for a ruleset game; display only |

Nothing is added to any message type, and no message type is added.

The descriptor is part of the authoritative game, like the start: the host's settings hold it, fixed when the game is
hosted, and every snapshot carries it. It is **pinned**: the first snapshot a receiver installs pins its ruleset (none,
for chess) for the whole session, across reconnects, exactly as 1.2 pins the start. A later snapshot, a resync, or the
snapshot after `resumed` or `watching` that names another ruleset, or none where one was pinned, or one where none was,
closes the connection with `bye(malformed)` and leaves the board as it was. This holds at the same revision and at a
newer one, and for a game with no moves yet.

## Negotiation

- **Capability.** A ruleset game requires the capability `ruleset:<descriptor>` (at most 32 bytes:
  `ruleset:mini:bishops-and-pawns@2` is exactly 32). A 1.3 guest and spectator state `start` and one `ruleset:` token
  for every ruleset it supports, in every `hello` and `resume`, whatever the flag: 1 + 7 = 8 tokens, the 1.2 maximum.
  A host never infers what a peer supports from its version or from TXT; it reads only the stated tokens.
- **Admission is 1.2's, unchanged.** The host's `requiredCapabilities` for a ruleset game is `{ruleset:<descriptor>}`;
  the check is the first thing the host does with a `hello` or `resume`, on a pending connection and on the guest's own
  connection, for guests and spectators, before it attaches the connection, reserves or re-answers a seat, replaces the
  guest's connection, ends a hold, resumes the clocks, refreshes spectators or sends a snapshot. A connection that does
  not state the exact token is refused with `bye(protocolVersion)`. So a 1.2 Mac (which states only `start`), a 1.3
  Mac without that kind, and a 1.3 Mac with another rules version of it (`@2` against `@1`) are all refused **before
  any snapshot, and so before any replay**; a peer that withdraws the token on a later `resume` is refused the same
  way, and only a `resume` on the guest's own connection closes it, starting the hold.
- **Receivers check too, before any replay.** A receiver reads a snapshot's metadata before it chooses a rules adapter
  or parses the record, in this order: a `ruleset` this build does not support, or did not state, is `badSnapshot`; a
  start or ruleset other than the one pinned (chess to a mini-game, a mini-game to chess, another kind, another
  version) is `malformed`; then the record is parsed and replayed as below. "Nothing installed yet" is not a pin: the
  first snapshot pins whatever it declares.
- **Capability budget.** The scheme fills 1.2's bounds exactly: eight tokens, the longest 32 bytes. A 1.2 host
  refuses a `hello` over those bounds as malformed before it looks at any token, so the bounds cannot be raised in a
  minor version. A ninth capability, a second rules version stated at once, or a rules version of two digits
  (`ruleset:mini:bishops-and-pawns@20` is 33 bytes) needs a new compact token scheme designed then, within the same
  bounds, or a major version. A test asserts that what this build states fits, so the first change that would not
  fit fails instead of truncating what is stated.
- **TXT `variant=` is display only.** The lobby shows the kind's title beside the game; nothing reads it for anything
  else. The stated capabilities do not depend on it, the board the guest shows comes only from the verified snapshot's
  ruleset, and a forged, missing or unreadable `variant` changes nothing but the label (an unreadable one shows no
  label). A 1.2 lobby ignores the key and lists the game as an ordinary one; joining it is refused as another version.

## The ruleset record

A ruleset game's record is not PGN. It is one line of ASCII, the descriptor followed by every move from the start, in
order, each as a space and four characters, from-square then to-square:

```
mini:pawn-duel@2 b2b4 g7g5 b4b5
```

- Exactly that grammar: the descriptor, then zero or more ` <square><square>` with each square `[a-h][1-8]`; no other
  character, no leading, trailing or doubled space, no line break, no promotion suffix (mini-game pawns never promote).
  The descriptor must be the game's own `ruleset`.
- **Limits, checked before any replay.** At most `NetworkRuleset.maximumPlies` = 10,000 moves and
  `24 + 5 × moves` bytes. The bound is derived from the referee: at most 16 pieces start in any kind, so at most 15
  captures; at most 16 pawns of at most 6 moves each, so at most 96 pawn moves; that is at most 111 irreversible plies,
  and the 80-ply rule ends any stretch without one within 80 plies, so no game reaches 111 + 112 × 80 = 9,071 plies.
  A snapshot whose revision is over the limit plus one, whose record is over the byte bound for its revision, or whose
  record does not parse, is refused as `badSnapshot` unread. The revision must equal the moves plus one once ended, as
  in 1.2.
- **Replay from the start.** A record is applied by playing every move, in order, on a fresh state of the kind's
  initial board through the referee's `play`, which refuses a move that is not legal there or comes after the game
  ended. The repetition history and the no-progress count are therefore recomputed by the receiver from the moves;
  nothing a peer sends states them. A receiver keeps the board played afresh, as in 1.2.
- **Moves on the wire** are the same four characters in `move.uci` and `moved.uci`; a five-character UCI is illegal in
  a ruleset game. `moved.san` carries a readable form (`b2-b4`, `c4xd5`, `Rb1xb7`), display only.

## The position hash

`moved.hash` and `snapshotBegin.hash` are, as before, SHA-256 of a state string and the revision. For a ruleset game
the state string is the referee's whole canonical state, not a board:

```
mini-state-v1|<descriptor>|<board>|<turn>|<pending>|<history>|<count>
```

- `<board>`: every occupied square in sorted order as `square=piece`, comma-separated; `<turn>` is `w` or `b`;
  `<pending>` the side whose pawn waits on the far rank for the reply (`w`, `b`) or `-`.
- `<history>`: every earlier position since the last capture or pawn move, oldest first, each as `board;turn;pending`,
  joined by `/`; `<count>` is how many there are (the no-progress count, below 80 while the game goes on).

These are exactly the inputs of `drawReason`: a repetition compares only positions with the same material and pawns,
which are the positions since the last capture or pawn move (a capture removes a piece and pawns only move forward, so
no earlier position can recur), and the 80-ply rule counts the same positions. So two states with the same string are
judged identically on every continuation, and two games that reach the same board with different repetition or
no-progress histories have different hashes. The last move is not part of the state (it changes no ruling); the
moves themselves are covered by the replay.

## Terminations added

| `termination` | Result | When (the referee's own order) |
|---|---|---|
| `farRank` | a win | a pawn on the far rank: at once in Pawn Duel; still there after the reply in the delayed kinds |
| `allCaptured` | a win | the other side has no pieces left to capture (only pawns count in the two Sweeps) |
| `noMoves` | a win for the other side | the side to move has no legal move (in the Sweeps, also when its moving pieces are gone) |
| `miniRepetition` | a draw | the same position, side to move and pending finish the third time |
| `miniNoProgress` | a draw | 80 plies without a capture or pawn move |
| `unreachableTargets` | a draw | Bishop Sweep, once no side has won: no bishop stands on a square of the same colour as any piece of the other side (the referee's square-colour test, not a path search) |

The referee is the authority: the host maps `MiniGameState.victory` and `draw` to these by the same checks in the
same order, and an ending it cannot name is a rules failure, never "play on". Resignation, agreement, time and
abandonment are as in 1.1; a flag falling is always a win for the other side (no side is ever reduced to a lone king).
There is nothing to claim: `claimDraw` is refused as `notClaimable`.

**Receivers verify every ending the rules decide.** An `ended`, and a snapshot's `outcome`, whose termination is one
the rules decide by themselves (checkmate, stalemate, insufficient material, the 75-move rule, fivefold repetition,
and the six above) must be exactly the ending this Mac's own replayed game shows, result included; a claimed draw
(`repetition`, `fiftyMoves`) must be one this Mac's game allows the side to move to claim, which a mini-game never
does. Anything else closes the connection with `bye(malformed)`. Resignation, agreement, time and abandonment are
the host's word, as before. This also closes, for chess, the 1.2 gap where a host could announce a checkmate the board
does not show.

**These values are sent only to connections that negotiated the ruleset.** They arise only in a ruleset game, and a
ruleset game sends nothing to a connection that has not stated its token: admission refuses it before anything is sent,
and `ended` is broadcast only to admitted connections (`NetworkHost.broadcast`, which sends to `admitted()`). A chess
game cannot produce them: the chess rules adapter has no path to them. Tests assert both.

## Assistance is off

A ruleset game has no assistance: the host refuses to set one up with any assistance level
(`NetworkHostError.assistanceNotAllowed`), drops an `assisted` flag on a move, and a receiver refuses a ruleset
snapshot whose terms are not `off` or whose `assistedPlies` is not empty (`badSnapshot`), and a `moved` that says
`assisted` (`malformed`). No hint, board insight or voice coach is offered; the engine stays off everywhere while
participating, as in every network game. The guest's join needs no Accept sheet.

## Review

Review of a finished ruleset game is the mini-game review (WI-018): the proof search over the game's own positions,
replayed from the whole record by the referee, with the review's budgets, giving facts such as "Move 4: White had a
forced win in 2 moves here." Every position is reviewed with its absolute ply (so move numbers count from the start,
however long the game) and with its own draw context, the positions back to its last capture or pawn move, taken
from the complete replay rather than from the referee's 256-position memory. It starts when the verified result
arrives, whatever ended the game: the referee, a resignation, an agreed draw, a flag or abandonment (a game ended
that way is not over by the referee's rules, and is reviewed all the same). It runs off the main actor, is bound to
that session, game and record, and is shown when the player presses "Review this game", which is offered once the
game has a result and a move. An interrupted ruleset game (no result) has no review, and neither does the crash
notice of one: its notice says so. There is no PGN review record.

**The crash file.** A ruleset game in progress is kept in `NetworkGames/current-ruleset.json`, never in
`current.json`, which a 1.2 build reads and would take for a chess record. A 1.3 build reads both and removes both;
a chess game's entry is byte for byte 1.2's, in 1.2's file.

The game is the network place's own: it is never a lesson, training or mini-game place, never saved as the learner's
mini-game, and records nothing in training.

## Version and compatibility

The protocol is 1.3, a minor bump: no message type is added and every added field is optional. Each new value is
kept from an older peer by a mechanism of its own:

- **The game itself** (the `ruleset` field, a record that is not PGN, the six terminations) reaches only a connection
  that stated the ruleset's token. A 1.2 decoder would refuse an unknown termination and would try to read a ruleset
  record as PGN, so these must never reach it. Admission on every `hello` and `resume`, before attachment, is what
  guarantees that, and it is 1.2's existing mechanism, unchanged (Codex conceded this in the plan's round 2, given
  negotiation on every connection). A test keeps it: a 1.2 guest and spectator and a 1.3 one lacking the kind see
  nothing of a ruleset game but `bye(protocolVersion)`, while a capable one plays it to an added termination.
- **The new capability tokens** go to every host, a 1.2 one included. They are within 1.2's bounds (eight tokens of at
  most 32 bytes), and a 1.2 host ignores tokens it does not know, so a 1.3 guest joins a 1.2 host's chess game.
- **The TXT `variant` key** is published to every browser before any connection. A 1.2 lobby reads only `game`,
  `role` and `assist` and ignores other keys; it lists the game as an ordinary one, and joining is refused as another
  version.
- **The crash file** of a ruleset game is in a file a 1.2 build never reads (above).

The compatibility promise:

1. A 1.3 Mac decodes every frozen 1.1 message (`Legacy11Fixtures`) and every frozen 1.2 message (`Legacy12Fixtures`,
   captured from the 1.2 code at bf7c181 before any 1.3 change).
2. A chess game, from the standard start or a declared one, encodes its record and settings exactly as 1.2 does: the
   public game record, the crash-file entry, the review record and the TXT entries are byte for byte the frozen ones.
3. Messages differ from 1.2's only in the version field and in the capability tokens stated.

A 1.2 guest or spectator still joins and watches a chess game hosted by a 1.3 Mac. A 1.3 guest joins a 1.2 host's
game: the 1.2 host ignores the tokens it does not know, and every game it hosts is chess.

## Review of this section

This section was written before any 1.3 code and reviewed by Codex in refute mode (read-only, 2026-10-18), with every
objection required to name its check. Nine objections; every check held, and all nine were addressed above before
the code was written. None was rejected.

| # | Objection | Check that held | What changed |
|---|---|---|---|
| 1 | The crash file bypasses negotiation: a 1.2 build reads `current.json` and would take the ruleset record for PGN | `NetworkGameRecord.swift` (one path for every entry) | A ruleset game's entry goes to `current-ruleset.json`; a test saves one and finds no `current.json` |
| 2 | A receiver accepts any `ended` whose revision fits: `farRank` in a chess game, a repetition at the start, the wrong winner | `NetworkReceiver.swift` (`ended` checks revision and clocks only); `NetworkSnapshot.swift` (outcome not checked) | Receivers verify every rules-decided ending, live and in snapshots, against their own replay; this closes the same gap for chess |
| 3 | Review is offered after a resignation, agreement, flag or abandonment, but `MiniGameReviewer.start` refuses a state the referee does not call finished | `MiniGameReviewer.swift` (`guard ... game.isFinished`) | The network review starts on the verified result whatever ended the game; a test resigns a running game and gets a review |
| 4 | Review would see only the referee's last 256 positions, numbered from zero | `MiniGames.swift` (`maximumHistory`), `MiniGameReview.positions` | The network review replays the whole record and reviews each position at its absolute ply with its own draw context; a test plays past 256 plies |
| 5 | The capability scheme fills 1.2's bounds; `@10` is 33 bytes; raising the bounds breaks 1.2 hosts | `NetworkStart.swift` (`NetworkCapabilities` bounds) | The evolution policy is stated; a test asserts that what this build states fits the bounds |
| 6 | The rules version must also cover the initial board and everything the referee reads | `MiniGames.swift` (`initialBoard`, `canMove`, `delayedFinish`), `Course.swift` (`pawnMoves`) | The bump rule covers the whole definition; a test freezes each kind's initial board and a terminal trace |
| 7 | `unreachableTargets` is not "no bishop can reach any target": it is the referee's square-colour test against any opposing piece | `MiniGames.swift` (`drawWithoutWinner`) | The table states the exact predicate |
| 8 | The pin rule (`malformed`) and the capability rule (`badSnapshot`) overlap, and the inherited flow replays before checking the pin | `NetworkReceiver.swift` (`finishSnapshot` checks the pin after `install`) | Metadata is checked before any adapter is chosen or any record parsed, in a stated order; tests count replays |
| 9 | The minor-version argument claimed admission protects the capability tokens and TXT too | `NetworkReceiver.swift` (`opening`), `NetworkTransport.swift` (`txt`) | The argument now names each value's own mechanism |

Claims Codex tried to break and could not: the canonical state's sufficiency (delayed finishes and eviction
included), the 10,000-ply bound, the record grammar and its bounded work, pinning across rulesets including
zero-move games, and admission before attachment for reservations, replaced connections, spectators and reconnects.
