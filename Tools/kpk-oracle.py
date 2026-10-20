#!/usr/bin/env python3
"""Exact verdicts for king and pawn against king (KPK), for the pawn race's authored starts (mini-game plan WI-019).

Semantics
- Position: one king each and one pawn, either colour; the side with the pawn is "the pawn side" (the learner in
  the pawn race). Legal means two kings not touching, the pawn on ranks 2-7, no castling rights or en passant
  square, and the side not to move not in check. Retro-legality is not required (a pawn on its second rank
  checking the king beside it counts, as in every tablebase). The halfmove clock must be 0: a verdict is for the
  position with no history, so no repetition or move-count rule has started to run.
- Normalisation: a black pawn is turned into a white one by flipping the ranks and swapping the colours, and a pawn
  on files e-h is mirrored onto a-d. Neither changes any verdict, because KPK has no castling and no en passant.
- chess: "win" when the pawn side forces checkmate, otherwise "draw" (the lone king can never win). Stalemate and
  insufficient material (bare kings after the pawn is taken, or a knight or bishop promotion) are draws. Forced mates
  in KPK are shorter than 50 moves (asserted by the exhaustive run), so neither the 50-move claim nor the automatic
  75-move and fivefold draws can intervene in a line that is played to win.
- promoteAndHold: the D3 goal for the pawn side, decided by the first matching event after each move: checkmate
  succeeds (including by promotion); stalemate fails (including by promotion); insufficient material fails (the
  pawn captured, or a knight or bishop promotion); a reply that captures the promoted piece fails; a reply that
  leaves it on the board succeeds; anything else continues. "success" when the pawn side forces success, else
  "failure". `successPlies` is the number of plies, both sides counted, from the position to the success event
  under best play (the reply that leaves the new piece standing is included).
- The two verdicts are computed separately and turn out to be equal on every legal position: after a queen or rook
  promotion, KQK and KRK are won exactly when D3 scores success. The exhaustive run counts that too.

Implementations
- Tools/kpk_retrograde.py: retrograde analysis (KQK and KRK solved in full for the chess verdict).
- Tools/kpk_forward.py: memoised depth-bounded forward search, sharing no code with the first.
Every verdict printed here comes from both and stops with an error if they disagree. `over` reports a start that
is already checkmate or stalemate, from Tools/lesson_rules.py (a third, independent rules implementation).

  python3 -I Tools/kpk-oracle.py verdict FEN [FEN ...]   one JSON line per FEN, with the generator identity
  python3 -I Tools/kpk-oracle.py identity                tool name, version and source hash
  python3 -I Tools/kpk-oracle.py exhaustive              compare both implementations on every legal position

Only authored starts' verdicts are stored (in the content manifest, from WI-020); nothing here writes content.
"""
import hashlib
import importlib.util
import json
import pathlib
import re
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
# Bumped whenever a verdict or an output field can change; the source hash covers every file that decides one.
VERSION = 1
SOURCES = ('kpk-oracle.py', 'kpk_retrograde.py', 'kpk_forward.py', 'lesson_rules.py')
FEN = re.compile(r'^([pkPK1-8]{1,8}/){7}[pkPK1-8]{1,8} [wb] - - 0 [1-9]\d*$')
FILES = 'abcdefgh'


def _load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


retro, forward, rules = _load('kpk_retrograde'), _load('kpk_forward'), _load('lesson_rules')


def identity():
    digest = hashlib.sha256()
    for name in SOURCES:
        digest.update(name.encode() + b'\0' + (HERE / name).read_bytes() + b'\0')
    return {'tool': 'kpk-oracle', 'version': VERSION, 'sourceHash': digest.hexdigest()}


def board(fen):
    squares = {}
    for row, text in zip('87654321', fen.split()[0].split('/')):
        column = 0
        for c in text:
            if c.isdigit():
                column += int(c)
            else:
                if column > 7:
                    break
                squares[FILES[column] + row] = ('w' if c.isupper() else 'b') + c.lower()
                column += 1
        if column != 8:
            raise ValueError(f'rank {row} does not have eight squares')
    return squares


def parse(fen):
    """(pawn side, side to move, normalised white king, pawn, black king, White to move) for a legal KPK FEN, or a
    ValueError saying why it is not one."""
    if not isinstance(fen, str) or not FEN.match(fen):
        raise ValueError('not a KPK FEN with no castling, no en passant square and a halfmove clock of 0')
    squares, mover = board(fen), fen.split()[1]
    pieces = sorted(squares.values())
    if pieces not in (['bk', 'bp', 'wk'], ['bk', 'wk', 'wp']):
        raise ValueError('needs exactly the two kings and one pawn')
    if any(piece == side + 'p' and square[1] in '18' for square, piece in squares.items() for side in 'wb'):
        raise ValueError('a pawn cannot stand on the first or last rank')
    where = {p: s for s, p in squares.items()}
    if retro.NEAR[retro.index(where['wk'])] >> retro.index(where['bk']) & 1:
        raise ValueError('the kings are touching')
    if rules.in_check(squares, rules.other(mover)):
        raise ValueError('the side not to move is in check')
    side = 'w' if 'wp' in where else 'b'

    def normal(s):
        x, y = FILES.index(s[0]), int(s[1]) - 1
        if side == 'b':
            y = 7 - y
        if FILES.index(where[side + 'p'][0]) > 3:
            x = 7 - x
        return FILES[x] + str(y + 1)
    wk, p, bk = normal(where[side + 'k']), normal(where[side + 'p']), normal(where[rules.other(side) + 'k'])
    white_to_move = mover == side
    if not retro.legal(wk, p, bk, white_to_move) or not forward.legal(wk, p, bk, white_to_move):
        raise AssertionError(f'the rules and the solvers disagree on the legality of {fen}')
    return side, mover, wk, p, bk, white_to_move


class Oracle:
    """Both implementations behind one call; any disagreement is an error, never a verdict."""

    def __init__(self):
        self.search = forward.Search()

    def verdict(self, wk, p, bk, white_to_move):
        chess = retro.distance('chess', wk, p, bk, white_to_move)
        plies = retro.distance('promoteAndHold', wk, p, bk, white_to_move)
        ahead = self.search.verdict(wk, p, bk, white_to_move)
        if (chess is not None) != ahead or (plies is not None) != ahead:
            raise AssertionError(f'implementations disagree on {wk} {p} {bk} {"w" if white_to_move else "b"}: retrograde chess {chess}, promoteAndHold {plies}; forward {ahead}')
        return chess is not None, plies

    def report(self, fen):
        side, mover, wk, p, bk, white_to_move = parse(fen)
        won, plies = self.verdict(wk, p, bk, white_to_move)
        squares = board(fen)
        over = 'checkmate' if rules.checkmated(squares, mover) else 'stalemate' if rules.stalemated(squares, mover) else None
        return {'fen': fen, 'pawnSide': side, 'sideToMove': mover, 'over': over, 'chess': 'win' if won else 'draw',
                'promoteAndHold': 'success' if plies is not None else 'failure', 'successPlies': plies, 'generator': identity()}


def positions():
    """Every legal normalised position, in a fixed order: (white king, pawn, black king, White to move)."""
    names = [f + r for r in '12345678' for f in FILES]
    for p in [f + r for r in '234567' for f in 'abcd']:
        for wk in names:
            for bk in names:
                for white_to_move in (True, False):
                    if retro.legal(wk, p, bk, white_to_move):
                        yield wk, p, bk, white_to_move


def exhaustive():
    """Both implementations on every legal position, both verdicts, plus the checks the semantics rely on."""
    clock, timing = time.perf_counter(), {}

    def lap(name):
        nonlocal clock
        now = time.perf_counter()
        timing[name] = round(now - clock, 2)
        clock = now
    for verdict in ('chess', 'promoteAndHold'):
        retro.solve(verdict)
    lap('retrograde')
    kxk = retro.kxk_fact()
    lap('kxkFact')
    names = [f + r for r in '12345678' for f in FILES]
    illegal_disagreements = sum(retro.legal(wk, p, bk, m) != forward.legal(wk, p, bk, m) for p in names for wk in names for bk in names for m in (True, False))
    lap('legality')
    search, rows = forward.Search(), []
    for position in positions():
        rows.append((position, retro.distance('chess', *position), retro.distance('promoteAndHold', *position), search.verdict(*position)))
    lap('forward')
    unstable = sum(search.verdict(*position, budget=forward.BUDGET + 1) != ahead for position, _, _, ahead in rows)
    lap('fixpoint')
    disagreements = [r for r in rows if (r[1] is not None) != r[3] or (r[2] is not None) != r[3]]
    summary = {'generator': identity(), 'legalPositions': len(rows), 'legalityDisagreements': illegal_disagreements,
               'kxkPositionsChecked': kxk, 'forwardBudget': forward.BUDGET, 'budgetNotFixpoint': unstable,
               'chessVersusPromoteAndHold': sum((r[1] is None) != (r[2] is None) for r in rows),
               'disagreements': len(disagreements), 'firstDisagreements': [list(r[0]) for r in disagreements[:5]], 'seconds': timing}
    for mover, flag in (('whiteToMove', True), ('blackToMove', False)):
        mine = [r for r in rows if r[0][3] == flag]
        summary[mover] = {'positions': len(mine), 'wins': sum(r[1] is not None for r in mine), 'successes': sum(r[2] is not None for r in mine)}
    summary['maxChessMatePlies'] = max(r[1] for r in rows if r[1] is not None)
    summary['maxSuccessPlies'] = max(r[2] for r in rows if r[2] is not None)
    summary['ok'] = not (disagreements or illegal_disagreements or unstable or summary['chessVersusPromoteAndHold']) and summary['maxChessMatePlies'] < 100
    return summary


def main(argv):
    if argv[:1] == ['identity'] and len(argv) == 1:
        print(json.dumps(identity()))
        return 0
    if argv[:1] == ['exhaustive'] and len(argv) == 1:
        summary = exhaustive()
        print(json.dumps(summary, indent=1))
        return 0 if summary['ok'] else 1
    if argv[:1] == ['verdict'] and len(argv) > 1:
        oracle, failed = Oracle(), 0
        for fen in argv[1:]:
            try:
                print(json.dumps(oracle.report(fen)))
            except ValueError as error:
                print(f'kpk-oracle: {fen!r}: {error}', file=sys.stderr)
                failed = 1
        return failed
    print(__doc__.rsplit('\n\n', 2)[-2], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
