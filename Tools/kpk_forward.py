"""Memoised forward KPK search: the second of the two independent implementations behind Tools/kpk-oracle.py.

Searches forwards from the position asked about. Squares are 0x88 numbers (rank * 16 + file), attacks are computed
by stepping, and nothing is shared with Tools/kpk_retrograde.py. White has the pawn.

`wins(wk, p, bk, budget)` asks whether White, to move, forces the `promoteAndHold` success of the plan's D3 within
`budget` White moves. Black's replies are expanded inline: a capture of the pawn fails, a stalemate fails, a mate
succeeds. A promotion is scored on the spot: a knight or bishop is insufficient material (failure); a queen or rook
succeeds if Black is mated or has a reply and none of them captures the new piece, and fails on stalemate or a
possible capture. Each position keeps the smallest budget proven to win and the largest proven not to, which is
enough to memoise a search whose answer only grows with the budget.

The chess verdict uses the same search. It differs from `promoteAndHold` only after a promotion, where chess asks
whether the KQK or KRK position is won; endgame theory (every KQK and KRK tablebase) says that position is won
exactly when the scoring above succeeds, so the two coincide here. That fact is checked, not assumed, by
kpk_retrograde.kxk_fact(), and the oracle's exhaustive mode compares this module's chess answers with the
retrograde solver's, which solves KQK and KRK completely instead.

BUDGET is the White-move horizon used for verdicts. It is exact because the oracle's exhaustive mode proves that
raising it by one changes no verdict among all legal positions: the set of positions won within n + 1 moves is a
function of the set won within n, so once two consecutive sets agree they agree for every larger n.
"""
import sys

BUDGET = 40
KING = (-17, -16, -15, -1, 1, 15, 16, 17)
ROOK = (-16, -1, 1, 16)
QUEEN = KING


def square(name):
    return (int(name[1]) - 1) * 16 + 'abcdefgh'.index(name[0])


def touching(a, b):
    return a - b in KING


def pawn_attacks(p, s):
    return s - p in (15, 17)


def slides(steps, origin, target, blocker):
    """Whether a queen or rook on origin attacks target, with the white king as the only possible blocker."""
    for step in steps:
        s = origin + step
        while not s & 0x88:
            if s == target:
                return True
            if s == blocker:
                break
            s += step
    return False


def legal(wk, p, bk, white_to_move):
    wk, p, bk = square(wk), square(p), square(bk)
    if wk == p or p == bk or wk == bk or touching(wk, bk) or not 1 <= p >> 4 <= 6 or (p & 7) > 3:
        return False
    return not (white_to_move and pawn_attacks(p, bk))


def promotion_holds(steps, wk, t, bk):
    moves = False
    for step in KING:
        s = bk + step
        if s & 0x88 or touching(s, wk):
            continue
        if s == t:
            return False
        if not slides(steps, t, s, wk):
            moves = True
    return moves or slides(steps, t, bk, wk)


class Search:
    def __init__(self):
        self.won = {}
        self.lost = {}
        sys.setrecursionlimit(max(sys.getrecursionlimit(), 20 * BUDGET + 1000))

    def wins(self, wk, p, bk, budget):
        key = (wk, p, bk)
        if self.won.get(key, budget + 1) <= budget:
            return True
        if self.lost.get(key, -1) >= budget:
            return False
        result = budget > 0 and self._expand(wk, p, bk, budget)
        if result:
            self.won[key] = budget
        else:
            self.lost[key] = budget
        return result

    def _expand(self, wk, p, bk, budget):
        ahead = p + 16
        if ahead >> 4 == 7:
            if ahead != wk and ahead != bk and (promotion_holds(QUEEN, wk, ahead, bk) or promotion_holds(ROOK, wk, ahead, bk)):
                return True
        elif ahead != wk and ahead != bk:
            if self.replies(wk, ahead, bk, budget - 1):
                return True
            jump = ahead + 16
            if p >> 4 == 1 and jump != wk and jump != bk and self.replies(wk, jump, bk, budget - 1):
                return True
        for step in KING:
            s = wk + step
            if not s & 0x88 and s != p and s != bk and not touching(s, bk) and self.replies(s, p, bk, budget - 1):
                return True
        return False

    def replies(self, wk, p, bk, budget):
        """Black to move after a White move that did not promote: True when every reply still loses."""
        moves = []
        for step in KING:
            s = bk + step
            if s & 0x88 or touching(s, wk):
                continue
            if s == p:
                return False
            if not pawn_attacks(p, s):
                moves.append(s)
        if not moves:
            return pawn_attacks(p, bk)
        return all(self.wins(wk, p, s, budget) for s in moves)

    def verdict(self, wk, p, bk, white_to_move, budget=BUDGET):
        """True when the pawn side forces success (and so wins at chess) within `budget` of its moves."""
        assert legal(wk, p, bk, white_to_move), (wk, p, bk, white_to_move)
        wk, p, bk = square(wk), square(p), square(bk)
        return self.wins(wk, p, bk, budget) if white_to_move else self.replies(wk, p, bk, budget)

    def moves_to_success(self, wk, p, bk, white_to_move):
        """The fewest pawn-side moves that force success, by iterative deepening, or None."""
        for budget in range(BUDGET + 1):
            if self.verdict(wk, p, bk, white_to_move, budget):
                return budget
        return None
