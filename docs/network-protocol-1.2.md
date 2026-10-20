# Network protocol 1.2: a declared start (LAN L1)

Protocol 1.2 lets a network game start from a chosen position instead of the standard start (mini-games plan D7,
"L1"). The game is ordinary chess from that position, adjudicated by the same rules as any network game: checkmate
wins, stalemate and the automatic draws are draws, and claims, resignation, agreement, time and abandonment are as in
1.1. A training goal (promote and hold, survive, avoid stalemate) is never carried or judged over the network; the host
sheet says so. Everything not named here is exactly 1.1.

The host's picker offers game-library positions only (the position after a chosen move of a bundled library game),
behind `CHECKMATE_NETWORK_POSITIONS=1`. There is no free FEN entry. With the flag off, hosting uses the standard
start exactly as 1.1 does.

## Fields added

| Where | Field | Value | Written |
|---|---|---|---|
| `hello` | `capabilities` | array of tokens, sorted, no duplicates | by every 1.2 guest and spectator |
| `resume` | `capabilities` | the same | on every resume |
| `NetworkPublicGame` (snapshot record, crash file) | `startFEN` | the canonical start FEN | only when the start is not the standard start |
| `NetworkHostSettings` | `startFEN` | the canonical start FEN, or nil | nil for the standard start |

- **Capability bounds.** At most 8 tokens; each 1 to 32 bytes of printable ASCII without spaces (0x21 to 0x7E). A
  message with more tokens, an empty, overlong or non-printable token, or a token twice is malformed and closes the
  connection with `bye(malformed)`, by the same rule in both directions. Tokens a host does not know are ignored, so a
  newer peer may state more. An empty list is not written.
- **Tokens defined.** `start`: this Mac replays a record from a declared start and pins it (below). A 1.2 guest and
  spectator state it in every `hello` and `resume`, whatever the flag: the flag only decides whether this Mac offers a
  start when hosting.
- **`startFEN`.** At most 128 bytes, six fields separated by single spaces, side to move `w` or `b`, a full-move
  number of 1 to 9999. A record whose `startFEN` is malformed, is the standard start (which is never written), or is not
  canonical (this Mac's rules load it and write a different FEN) is refused as `badSnapshot`.

## Admission

A game with a declared start requires the capability `start`; a standard-start game requires none.

The host admits a connection only if its `hello` or `resume` states every capability the game requires. The check is
the first thing the host does with either message, on a pending connection and on the guest's own connection alike,
for a guest's seat and a spectator alike. A connection that does not state them is refused with `bye(protocolVersion)`
before the host attaches it, reserves or re-answers a seat, replaces the guest's connection, ends a hold, resumes the
clocks, refreshes spectators or sends a snapshot. Nothing about the game changes: a reserved seat stays reserved
until its own deadline, a disconnected guest's hold and paused clocks stay as they were, and a running guest's
connection stays attached. Only a `resume` on the guest's own connection that withdraws a capability closes that
connection, as any refusal on it does: the guest has dropped, and the hold begins.

This covers the first join, a reservation's recovery by `hello` with the same claim, and `resume` while reserved,
running or disconnected, for guests and spectators, with the capability present, missing (a 1.1 Mac) or withdrawn (a
peer that stated it once and not on its next connection). A 1.1 Mac reads `protocolVersion` as "uses a different
version of Checkmate"; it no longer receives a snapshot it cannot replay, so the retryable `badSnapshot("start")` loop of
1.1 against such a game cannot happen.

## Start pinning

- The host makes the start once, when the game is hosted: its rules load the chosen FEN, and the FEN they write back
  (chess.js's normalisation: an en passant square only when the capture is legal) is the canonical start. Its record
  is that game's own export, so it carries `[SetUp "1"]` and `[FEN "<canonical start>"]`.
- A receiver installs a snapshot only if the record's FEN header equals the declared start (`startFEN`, or the
  standard start when absent, in which case the record has no FEN header) and the record's moves, played afresh on a
  new game from that start, reach the snapshot's hash. The board kept is the one played afresh.
- The first snapshot a receiver installs pins that start for the whole session, across reconnects. Every later
  snapshot, a resync, and the snapshot after `resumed` or `watching`, must carry the same start; one that differs
  closes the connection with `bye(malformed)` and leaves the board as it was. This holds at the same revision and at a
  newer one, for a game with no moves yet, and for a start that differs only in castling or en passant rights.
- The review record and Review replay from the pinned start.

## Hosting refuses

The host refuses a start, and hosts nothing, when:

- the rules refuse the FEN (chess.js's validation: six fields, one king each, no pawn on the first or last rank, and
  so on);
- the side not to move is in check;
- a castling right has no king and rook on their home squares, or an en passant square has no pawn that has just
  passed it (the pawn on the square beyond it, and the square and the one behind it empty);
- the game is already over at the start: checkmate, stalemate, insufficient material, or the 75-move rule.

## Ply parity

A declared start may have Black to move and any full-move number. Ply 1 is the first move from the start, made by
the start's side to move.

- `assistedMoves(by:)` counts a side's assisted plies from the start's side to move, not from White.
- `reviewPGN` writes `[SetUp "1"]` and `[FEN "<start>"]` after `Result`, and numbers the movetext from the start:
  Black first at full move 37 is `37... Kd7 38. Ke5`. A standard-start game's review record is unchanged.

## Version and compatibility

The protocol is 1.2, a minor bump: no message type is added, and every addition is optional.

The compatibility promise:

1. A 1.2 Mac decodes every frozen 1.1 message (`Legacy11Fixtures`, captured from the 1.1 codec before any 1.2
   change).
2. A standard-start game encodes its record and settings exactly as 1.1 does: the public game record, the crash-file
   entry, the review record and the TXT entries are byte for byte the frozen 1.1 ones.
3. Messages differ from 1.1's only in the version field and the new optional fields (`capabilities`), which a 1.1
   decoder ignores.

A 1.1 guest or spectator still joins and watches a standard-start game hosted by a 1.2 Mac. A 1.2 guest joins a 1.1
host's game: the 1.1 host ignores `capabilities`, and every game it hosts has the standard start.
