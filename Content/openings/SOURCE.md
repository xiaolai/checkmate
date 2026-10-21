# Named opening lines

`a.tsv` to `e.tsv` are copied unchanged from Lichess `chess-openings`:

- Repository: https://github.com/lichess-org/chess-openings
- Commit: `a6189a30dc273ccb21fc2536a9a2fefd5592a67a`
- Files: `https://raw.githubusercontent.com/lichess-org/chess-openings/a6189a30dc273ccb21fc2536a9a2fefd5592a67a/{a,b,c,d,e}.tsv`
- Columns: `eco`, `name`, `pgn` (3,865 named lines)

| File | SHA-256 |
|---|---|
| a.tsv | `3282e4c9155289a29224f9a85fba0decb46efa35c2fa5e39662d2ac48fb0f793` |
| b.tsv | `1d5ed134ebbd87915ead5683416e37583bb3e5ae3582b4d8cb5cb4aa7ef4f623` |
| c.tsv | `45e843c7b7e79a0d04d5bda879c9bd23f5a10974488bd8615e4f4c5d0749986f` |
| d.tsv | `1cf4057a8aece94f27bb3f278ad410ee2844831a642364eeceaafa091dbcceda` |
| e.tsv | `48c6f6645b031a5937c8386839debab0e2e48837251687ba1afb6369677f8546` |

The repository's README states:

> As a collection of facts, this data set is in the public domain.
> Considerable effort was spent curating and cleaning the data. Insofar as that
> qualifies for copyright, the work is released under the
> CC0 Public Domain Dedication.

They are used for three things only: the provenance allowance for bundled games (`Tools/provenance.py`,
`bundled_board_hit`), the opening name the game library shows for each bundled game
(`Tools/build-game-library.py`), and the opening a review names (R-20). Updating them changes the allowance, which
`Tools/test-provenance.py` pins.

The review's book, `Sources/CheckmateCore/Resources/openings.tsv`, is derived from these five files by
`Tools/build-openings.py` and carries the same CC0 dedication. It lists every position each line passes through,
keyed by its placement, side to move and castling rights (the en-passant square left out), with the ECO code and name of the line that ends there
(empty for a position no line ends on). `OpeningBook` matches a game's positions against it, so a game that reaches a
line by another move order finds it. `python3 -I Tools/build-openings.py --check`, run by `scripts/test-unit.sh`, fails
when the bundled book differs from what these files produce.
