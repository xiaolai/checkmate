"""Retrograde KPK solver: the first of the two independent implementations behind Tools/kpk-oracle.py.

Works backwards from the end of the game. Squares are 0..63 (a1 = 0, h8 = 63) with bitmask attack tables. White
has the pawn (the oracle normalises colours and files before asking). It solves king and queen against king and
king and rook against king completely, then king and pawn against king twice over the same backward induction with
two different leaves:
  - chess: a promotion to a queen or rook is worth the solved KQK/KRK value of the position it makes; a knight or
    bishop is a dead position (insufficient material), so a draw.
  - promoteAndHold: a promotion is scored by the event rules of the plan's D3 directly, with no endgame table.
Pawn moves never change file (a white pawn has nothing to capture), so files a-d cover every case after mirroring.
The forward search (Tools/kpk_forward.py) shares none of this code.

Values are distances in plies to the winning event, or None for no forced win: from a position with White to move
`white[i]`, with Black to move `black[i]`, where i = (wk * 64 + piece) * 64 + bk.
"""
from collections import defaultdict, deque
from functools import lru_cache

FILES = 'abcdefgh'
STEPS = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
LINES = {'q': STEPS, 'r': STEPS[:4]}


def index(name):
    return FILES.index(name[0]) + 8 * (int(name[1]) - 1)


def _walk(square, step):
    x, y = square % 8 + step[0], square // 8 + step[1]
    while 0 <= x < 8 and 0 <= y < 8:
        yield x + 8 * y
        x, y = x + step[0], y + step[1]


NEIGHBOURS = [tuple(t for t in (next(_walk(s, step), None) for step in STEPS) if t is not None) for s in range(64)]
NEAR = [sum(1 << t for t in NEIGHBOURS[s]) for s in range(64)]
# The squares a white pawn on s attacks.
PAWN_HITS = [sum(1 << t for t in (next(_walk(s, step), None) for step in ((1, 1), (-1, 1))) if t is not None) for s in range(64)]
PAWN_SQUARES = [x + 8 * y for y in range(1, 7) for x in range(4)]


def _between(piece):
    """between[x * 64 + t]: the squares strictly between a piece on x and t, or -1 when the piece cannot reach t."""
    table = [-1] * 4096
    for x in range(64):
        for step in LINES[piece]:
            mask = 0
            for t in _walk(x, step):
                table[x * 64 + t] = mask
                mask |= 1 << t
    return table


BETWEEN = {piece: _between(piece) for piece in LINES}


def _hits(between, x, t, blockers):
    line = between[x * 64 + t]
    return line >= 0 and not line & blockers


def _replies(piece, wk, x, bk):
    """Black's king moves after White's piece lands on x: (moves to safe squares, capture available, in check). The
    black king does not block the line it stands on, so it cannot step back along a check."""
    between, safe, capture = BETWEEN[piece], 0, False
    for t in NEIGHBOURS[bk]:
        if NEAR[wk] >> t & 1:
            continue
        if t == x:
            capture = True
        elif not _hits(between, x, t, 1 << wk):
            safe += 1
    return safe, capture, _hits(between, x, bk, 1 << wk)


@lru_cache(maxsize=None)
def solve_kxk(piece):
    """King and queen (piece 'q') or rook ('r') against a lone king, by breadth-first retrograde analysis from every
    mate. Returns (white, black) distance lists; a capture of the piece or a stalemate is never a win."""
    white, black, count, frontier = [None] * 262144, [None] * 262144, [0] * 262144, deque()
    for wk in range(64):
        for x in range(64):
            for bk in range(64):
                if len({wk, x, bk}) < 3 or NEAR[wk] >> bk & 1:
                    continue
                i = (wk * 64 + x) * 64 + bk
                safe, capture, check = _replies(piece, wk, x, bk)
                if capture or (not safe and not check):
                    count[i] = -1
                elif not safe:
                    black[i] = 0
                    frontier.append(i)
                else:
                    count[i] = safe
    while frontier:
        i = frontier.popleft()
        wk, x, bk = i >> 12, i >> 6 & 63, i & 63
        for p in _kxk_white_unmoves(piece, wk, x, bk):
            if white[p] is not None:
                continue
            white[p] = black[i] + 1
            pwk, px, pbk = p >> 12, p >> 6 & 63, p & 63
            for s in NEIGHBOURS[pbk]:
                if s == pwk or s == px or NEAR[pwk] >> s & 1:
                    continue
                q = (pwk * 64 + px) * 64 + s
                if count[q] > 0:
                    count[q] -= 1
                    if not count[q]:
                        black[q] = white[p] + 1
                        frontier.append(q)
    return white, black


def _kxk_white_unmoves(piece, wk, x, bk):
    """Positions with White to move from which one White move reaches (wk, x, bk); each must be legal, so Black's king
    may not be in check in it."""
    between = BETWEEN[piece]
    for s in NEIGHBOURS[wk]:
        if s != x and s != bk and not NEAR[s] >> bk & 1 and not _hits(between, x, bk, 1 << s):
            yield (s * 64 + x) * 64 + bk
    for step in LINES[piece]:
        for s in _walk(x, step):
            if s == wk or s == bk:
                break
            if not _hits(between, s, bk, 1 << wk):
                yield (wk * 64 + s) * 64 + bk


def _pah_leaf(piece, wk, t, bk):
    """D3 for a promotion on t: a knight or bishop is insufficient material (failure); checkmate succeeds at once;
    stalemate fails; a reply that captures the new piece fails; otherwise every reply leaves it on the board, a
    success one ply later."""
    if piece not in LINES:
        return None
    safe, capture, check = _replies(piece, wk, t, bk)
    if not safe and not capture:
        return 1 if check else None
    return None if capture else 2


def _chess_leaf(piece, wk, t, bk):
    if piece not in LINES:
        return None
    depth = solve_kxk(piece)[1][(wk * 64 + t) * 64 + bk]
    return None if depth is None else depth + 1


def _kpk_black(wk, p, bk):
    safe, capture = 0, False
    for t in NEIGHBOURS[bk]:
        if NEAR[wk] >> t & 1:
            continue
        if t == p:
            capture = True
        elif not PAWN_HITS[p] >> t & 1:
            safe += 1
    return safe, capture, bool(PAWN_HITS[p] >> bk & 1)


def _kpk_white_unmoves(wk, p, bk):
    for s in NEIGHBOURS[wk]:
        if s != p and s != bk and not NEAR[s] >> bk & 1 and not PAWN_HITS[p] >> bk & 1:
            yield (s * 64 + p) * 64 + bk
    rank = p >> 3
    if rank >= 2 and p - 8 not in (wk, bk):
        if not PAWN_HITS[p - 8] >> bk & 1:
            yield (wk * 64 + p - 8) * 64 + bk
        if rank == 3 and p - 16 not in (wk, bk) and not PAWN_HITS[p - 16] >> bk & 1:
            yield (wk * 64 + p - 16) * 64 + bk


def _solve_kpk(leaf):
    """Backward induction over KPK with distances: a White node takes the smallest distance of its winning moves, a
    Black node the largest over its replies once every reply wins. Distances differ by leaf, so nodes are settled
    from a queue of buckets in increasing distance, which makes the first settled value the minimum."""
    white, black, count, best, buckets = [None] * 262144, [None] * 262144, [0] * 262144, {}, defaultdict(list)
    mates = []
    for p in PAWN_SQUARES:
        for wk in range(64):
            for bk in range(64):
                if len({wk, p, bk}) < 3 or NEAR[wk] >> bk & 1:
                    continue
                i = (wk * 64 + p) * 64 + bk
                safe, capture, check = _kpk_black(wk, p, bk)
                if capture or (not safe and not check):
                    count[i] = -1
                elif not safe:
                    black[i] = 0
                    mates.append(i)
                else:
                    count[i] = safe
                if not check and p >> 3 == 6 and p + 8 not in (wk, bk):
                    for piece in 'qrbn':
                        d = leaf(piece, wk, p + 8, bk)
                        if d is not None and d < best.get(i, 99):
                            best[i] = d
                            buckets[d].append(i)
    for i in mates:
        for w in _kpk_white_unmoves(i >> 12, i >> 6 & 63, i & 63):
            if best.get(w, 99) > 1:
                best[w] = 1
                buckets[1].append(w)
    d = 0
    while buckets:
        d += 1
        for i in buckets.pop(d, ()):
            if white[i] is not None or best[i] != d:
                continue
            white[i] = d
            wk, p, bk = i >> 12, i >> 6 & 63, i & 63
            for s in NEIGHBOURS[bk]:
                if s == wk or s == p or NEAR[wk] >> s & 1:
                    continue
                q = (wk * 64 + p) * 64 + s
                if count[q] > 0:
                    count[q] -= 1
                    if not count[q]:
                        black[q] = d + 1
                        for w in _kpk_white_unmoves(wk, p, s):
                            if white[w] is None and best.get(w, 99) > d + 2:
                                best[w] = d + 2
                                buckets[d + 2].append(w)
    return white, black


@lru_cache(maxsize=None)
def solve(verdict):
    """'chess' or 'promoteAndHold': (white, black) distance lists over KPK."""
    return _solve_kpk({'chess': _chess_leaf, 'promoteAndHold': _pah_leaf}[verdict])


def legal(wk, p, bk, white_to_move):
    """Three distinct squares, kings not touching, the pawn on ranks 2-7 of files a-d, and the side not to move not in
    check (only Black can be checked)."""
    wk, p, bk = index(wk), index(p), index(bk)
    return (len({wk, p, bk}) == 3 and not NEAR[wk] >> bk & 1 and p in PAWN_SQUARES
            and not (white_to_move and PAWN_HITS[p] >> bk & 1))


def distance(verdict, wk, p, bk, white_to_move):
    """Plies to the winning event under best play, or None when the pawn side cannot force it."""
    assert legal(wk, p, bk, white_to_move), (wk, p, bk, white_to_move)
    white, black = solve(verdict)
    return (white if white_to_move else black)[(index(wk) * 64 + index(p)) * 64 + index(bk)]


def kxk_fact():
    """Checks the endgame fact the forward search relies on: in KQK and KRK every position with White to move is won,
    and with Black to move it is won exactly when Black is mated or has a move but cannot capture the piece. Returns
    the number of positions checked; raises on the first counterexample."""
    checked = 0
    for piece in LINES:
        white, black = solve_kxk(piece)
        for wk in range(64):
            for x in range(64):
                for bk in range(64):
                    if len({wk, x, bk}) < 3 or NEAR[wk] >> bk & 1:
                        continue
                    i = (wk * 64 + x) * 64 + bk
                    safe, capture, check = _replies(piece, wk, x, bk)
                    if (black[i] is not None) != (not capture and (safe > 0 or check)):
                        raise AssertionError(f'K{piece.upper()}K black to move {i}: table {black[i]}')
                    if not check and white[i] is None:
                        raise AssertionError(f'K{piece.upper()}K white to move {i} is not won')
                    checked += 1 + (not check)
    return checked
