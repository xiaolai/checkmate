#!/usr/bin/env python3
"""Independent lesson-diagram audit with python-chess: `uv run --with chess Tools/audit-lesson-rules.py`.

The course validator (Tools/prepare-lesson-scripts.py) checks lessons with the repository's own rules. This audit
repeats the checks that matter most with a separate, widely used chess library, so a shared mistake in our rules
cannot pass both. It uses no app code, credentials, playback or microphone, and reads the published course.

- Every authored move follows its piece's movement on the board shown, castling is a king's two-square move followed
  by its rook in the same beat, en passant removes the passed pawn, and no move leaves its own king attacked.
- Every check mark is on a king the other side attacks; every beat's published end board is what its moves produce.
- Every move puzzle on a board with both kings: python-chess finds exactly the moves the validator accepts for its
  claim (mate, stalemate, check, escape from check, any legal move), and the authored answer is one of them.
- Every lesson practice exercise (`practice`), replayed from its FEN: the invitation beat shows exactly that position;
  every teaching node's fingerprint, accepted move and reply is legal and matches, every node is reached, and an
  accepted move has a reply exactly when the graph continues. Every checkpoint is possible from the start: a mate
  has material White can mate with, en passant a legal en-passant capture at once, promotion a white pawn with no
  black pawn ahead on its file, pawn checkpoints a white pawn, attacking the queen a black queen, and castling a
  legal castling move at the start, at a teaching node, or right after a move that completes the graph.
  - A graph without a graph checkpoint is one move of its castle or enPassant checkpoint: it accepts exactly the
    legal castling (or en-passant) moves of the position.
  - A graph checkpoint without a tactic is a developing move that stops a mate: the root accepts exactly the moves
    of a knight or bishop from its starting square after which Black has no mate in one. Every other move that
    allows mate in one is answered with that mate, and every other move has its own mistakes text.
  - A graph checkpoint with a tactic and a gain: every accepted root move has the tactic's geometry, wins at least
    the gain against every defence, and its authored reply is a best defence; every legal root move with that
    geometry that wins the gain is accepted. At every later node each accepted move keeps the gain, a move that
    completes the graph has banked it (on the board after the move and kept through Black's captures), and every
    move that banks it and keeps it is accepted.
  - A reply to a move the graph does not accept is a refutation: it mates, or White ends at least a pawn down.

Material search. Values are pawn 1, knight and bishop 3, rook 5, queen 9, checkmate 1000, stalemate 0, counted as
White's material minus Black's and compared with the practice position. A White decision is searched DEPTH = 6 plies
counting the decision itself (Black's every reply, then four more plies at full width), then quiescence: captures
and promotions until the position is quiet, with every check evasion tried for the first four quiescence plies.
"Wins at least the gain" means the minimax value over every Black reply, relative to the start, is at least the
gain; "a best defence" means the authored reply reaches that minimum. Repetition and the fifty-move rule are ignored.

Tactic geometry, judged on the move alone:
- fork: after the move, the moved piece attacks two or more black pieces, each the king or worth at least 3;
- pin: after the move a black piece is the only piece between its king and a white bishop, rook or queen moving
  along that line, and that line piece is the moved piece or the moved piece has just left the line;
- skewer: the moved bishop, rook or queen gives check, and the first piece beyond the king on that line is Black's
  and worth at least the checking piece;
- discovered: the moved piece was the only piece between a white bishop, rook or queen and Black's king or queen,
  which that line piece attacks after the move;
- removeDefender: a target (a square where the line's completing move captures) holds a black piece that White
  attacks and exactly one black piece guards, and the move captures that guard or a pawn steps up to attack it.

`--mutations` plants one defect at a time in memory (a weaker authored defence, a missing or extra accepted move, a
gain the line does not win, a non-refuting reply, a broken fingerprint, …), requires the rule it targets to reject
it, and checks that each geometry predicate tells its tactic from a near miss. It never writes files.
"""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import chess

ROOT = Path(__file__).resolve().parents[1]
CHECKED_CLAIMS = {'mate', 'stalemate', 'check', 'escape-check', 'legal'}


def board_of(position):
    board = chess.Board(None)
    for square, piece in (position or {}).items():
        board.set_piece_at(chess.parse_square(square),
                           chess.Piece.from_symbol(piece[1].upper() if piece[0] == 'w' else piece[1]))
    return board


def position_of(board):
    return {chess.square_name(square): ('w' if piece.color else 'b') + piece.symbol().lower()
            for square, piece in board.piece_map().items()}


def king_attacked(board, colour):
    king = board.king(colour)
    return king is not None and board.is_attacked_by(not colour, king)


def check_beat(identity, beat, frame):
    board = board_of(frame['start']['board'])
    moves = beat.get('moves', [])
    for index, move in enumerate(moves):
        start, end = map(chess.parse_square, move[:2])
        piece = board.piece_at(start)
        assert piece is not None, (identity, 'missing source', move)
        target = board.piece_at(end)
        assert target is None or target.color != piece.color, (identity, 'friendly landing', move)
        dx = abs(chess.square_file(end) - chess.square_file(start))
        dy = chess.square_rank(end) - chess.square_rank(start)
        passed = None
        if piece.piece_type == chess.PAWN:
            d = 1 if piece.color else -1
            valid = (dx == 0 and dy == d and target is None) or (
                dx == 0 and dy == 2 * d and chess.square_rank(start) == (1 if piece.color else 6)
                and target is None and board.piece_at(start + d * 8) is None) or (dx == 1 and dy == d and target is not None)
            if dx == 1 and dy == d and target is None:
                passed = end - d * 8
                valid = chess.square_name(passed) in beat.get('remove', []) and board.piece_at(passed) == chess.Piece(chess.PAWN, not piece.color)
        elif piece.piece_type == chess.KING and dx == 2 and dy == 0:
            rank = '1' if piece.color else '8'
            corner, rook_end = ('h', 'f') if chess.square_file(end) > chess.square_file(start) else ('a', 'd')
            assert moves[index + 1:index + 2] == [[corner + rank, rook_end + rank]], (identity, 'castling moves its rook next', move)
            assert move[0] == 'e' + rank and board.piece_at(chess.parse_square(corner + rank)) == chess.Piece(chess.ROOK, piece.color), (identity, 'castling from home', move)
            between = [chess.parse_square(f + rank) for f in ('fg' if corner == 'h' else 'bcd')]
            crossed = [chess.parse_square(f + rank) for f in ('efg' if corner == 'h' else 'edc')]
            valid = all(board.piece_at(s) is None for s in between) and not any(board.is_attacked_by(not piece.color, s) for s in crossed)
        elif index > 0 and piece.piece_type == chess.ROOK and moves[index - 1][0][0] == 'e' and moves[index - 1][1] in ('g' + move[0][1], 'c' + move[0][1]) \
                and board.piece_at(chess.parse_square(moves[index - 1][1])) == chess.Piece(chess.KING, piece.color):
            valid = move[1] == ('f' if moves[index - 1][1][0] == 'g' else 'd') + move[0][1]  # the castling rook
        else:
            valid = end in board.attacks(start)
        assert valid, (identity, 'movement or path', move)
        board.remove_piece_at(start)
        if passed is not None:
            board.remove_piece_at(passed)
        promoted = move[2] if len(move) > 2 else None
        board.set_piece_at(end, chess.Piece.from_symbol(promoted[1].upper() if promoted[0] == 'w' else promoted[1]) if promoted else piece)
        assert not king_attacked(board, piece.color), (identity, 'leaves its own king attacked', move)
    for square in beat.get('remove', []):
        if board.piece_at(chess.parse_square(square)) is not None:
            board.remove_piece_at(chess.parse_square(square))
    assert position_of(board) == (frame['end']['board'] or {}), (identity, 'endpoint mismatch')
    for mark in frame['end'].get('hl', []):
        if mark['kind'] == 'check':
            piece = board.piece_at(chess.parse_square(mark['sq']))
            assert piece is not None and piece.piece_type == chess.KING and king_attacked(board, piece.color), (identity, 'check mark on an unattacked king')
    return len(moves)


def satisfies(board, move, claim):
    after = board.copy(stack=False)
    after.push(move)
    return {'mate': after.is_checkmate, 'stalemate': after.is_stalemate, 'check': after.is_check,
            'escape-check': lambda: True, 'legal': lambda: True}[claim]()


def check_puzzle(puzzle, prepare):
    exercise = puzzle['exercise']
    claim = exercise.get('claim', {}).get('type')
    if exercise['kind'] != 'move' or claim not in CHECKED_CLAIMS:
        return False
    board = board_of(puzzle['board'])
    if board.king(chess.WHITE) is None or board.king(chess.BLACK) is None:
        return False
    board.turn = exercise['claim']['side'] == 'w'
    board.castling_rights = chess.BB_EMPTY
    for flag, (king, rook) in {'K': ('e1', 'h1'), 'Q': ('e1', 'a1'), 'k': ('e8', 'h8'), 'q': ('e8', 'a8')}.items():
        if flag in exercise['claim'].get('castling', ''):
            board.castling_rights |= chess.BB_SQUARES[chess.parse_square(rook)]
    if exercise['claim'].get('enPassant'):
        board.ep_square = chess.parse_square(exercise['claim']['enPassant'])
    if claim == 'escape-check':
        assert board.is_check(), (puzzle['id'], 'escape-check puzzle starts in check')
    ours = {tuple(m[:2]) for m in prepare.claim_moves(puzzle['board'], exercise)}
    theirs = {(chess.square_name(m.from_square), chess.square_name(m.to_square)) for m in board.legal_moves if satisfies(board, m, claim)}
    assert ours == theirs, (puzzle['id'], 'answer set differs', sorted(ours ^ theirs))
    assert (exercise['from'], exercise['to']) in theirs, (puzzle['id'], 'authored answer is not a solution')
    return True


VALUES = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3, chess.ROOK: 5, chess.QUEEN: 9, chess.KING: 0}
MATE = 1000
DEPTH = 6  # plies searched from every White decision, the decision itself included, before quiescence
EVASION_PLIES = 4  # quiescence plies in which a side in check tries every evasion instead of standing pat
SLIDERS = (chess.BISHOP, chess.ROOK, chess.QUEEN)
MINOR_HOMES = (chess.B1, chess.G1, chess.C1, chess.F1)


def material(board):
    """White's material minus Black's: pawn 1, knight and bishop 3, rook 5, queen 9."""
    return sum(VALUES[p.piece_type] * (1 if p.color else -1) for p in board.piece_map().values())


class MaterialSearch:
    """Full-width alpha-beta over material, then quiescence: captures and promotions until the position is quiet.

    Checkmate scores 1000 for the winner, stalemate 0; repetition and the fifty-move rule are not modelled. A side in
    check tries every evasion for the first EVASION_PLIES quiescence plies instead of standing pat. Results are exact
    minimax values for that tree; the table only stores bounds proved for the same position and remaining depth.
    """
    def __init__(self):
        self.table, self.decisions = {}, {}

    @staticmethod
    def ordered(board, moves):
        def rank(move):
            victim = board.piece_type_at(move.to_square) or (chess.PAWN if board.is_en_passant(move) else None)
            if victim is None and not move.promotion:
                return (1, 0)
            return (0, VALUES[board.piece_type_at(move.from_square)] - 10 * (VALUES[victim] if victim else 0) - (VALUES[move.promotion] if move.promotion else 0))
        return sorted(moves, key=rank)

    def quiescence(self, board, alpha, beta, ply=0):
        moves = list(board.legal_moves)
        if not moves:
            return -MATE if board.is_check() else 0
        if board.is_check() and ply < EVASION_PLIES:
            best = -2 * MATE
        else:
            best = material(board) * (1 if board.turn else -1)
            if best >= beta:
                return best
            moves = [m for m in moves if board.is_capture(m) or m.promotion]
        for move in self.ordered(board, moves):
            board.push(move)
            value = -self.quiescence(board, -beta, -max(alpha, best), ply + 1)
            board.pop()
            if value > best:
                best = value
                if best >= beta:
                    break
        return best

    def negamax(self, board, depth, alpha, beta):
        if depth <= 0:
            return self.quiescence(board, alpha, beta)
        key = (board.board_fen(), board.turn, board.castling_rights, board.ep_square, depth)
        stored = self.table.get(key)
        if stored is not None:
            value, bound = stored
            if bound == 0 or (bound > 0 and value >= beta) or (bound < 0 and value <= alpha):
                return value
        moves = list(board.legal_moves)
        if not moves:
            return -MATE if board.is_check() else 0
        best, floor = -2 * MATE, alpha
        for move in self.ordered(board, moves):
            board.push(move)
            value = -self.negamax(board, depth - 1, -beta, -max(alpha, best))
            board.pop()
            if value > best:
                best = value
                if best >= beta:
                    break
        self.table[key] = (best, 1 if best >= beta else (-1 if best <= floor else 0))
        return best

    def white(self, board, depth):
        """The exact value of `board` for White, searched `depth` plies."""
        value = self.negamax(board, depth, -2 * MATE - 1, 2 * MATE + 1)
        return value if board.turn == chess.WHITE else -value

    def decision(self, board, move):
        """White plays `move`; every Black reply is searched to DEPTH plies from the decision. Returns (the worst value
        for White, {reply: value}); values are White's material minus Black's, or ±MATE."""
        key = (board.fen(), move.uci())
        if key not in self.decisions:
            board.push(move)
            replies = {}
            for reply in board.legal_moves:
                board.push(reply)
                replies[reply.uci()] = self.white(board, DEPTH - 2)
                board.pop()
            worst = min(replies.values()) if replies else (MATE if board.is_check() else 0)
            board.pop()
            self.decisions[key] = (worst, replies)
        return self.decisions[key]

    def banked(self, board, move):
        """The material White holds after `move`: already on the board, and kept through Black's best capture sequence
        (quiescence). The lower of the two, so a check whose evasion lets White capture later does not count yet."""
        board.push(move)
        value = min(material(board), -self.quiescence(board, -2 * MATE - 1, 2 * MATE + 1))
        board.pop()
        return value


def after_move(board, move):
    after = board.copy(stack=False)
    after.push(move)
    return after


def fork(before, move, targets):
    """The moved piece attacks two or more black pieces, each the king or worth at least 3."""
    after = after_move(before, move)
    hit = [s for s in after.attacks(move.to_square) if after.color_at(s) == chess.BLACK
           and (after.piece_type_at(s) == chess.KING or VALUES[after.piece_type_at(s)] >= 3)]
    return len(hit) >= 2


def pin(before, move, targets):
    """After the move a black piece is absolutely pinned to its king: the only piece between the king and a white
    bishop, rook or queen moving along that line, where that piece is the moved one or the moved piece left the line."""
    after = after_move(before, move)
    king = after.king(chess.BLACK)
    for pinner in chess.SquareSet(after.occupied_co[chess.WHITE]):
        kind = after.piece_type_at(pinner)
        if kind not in SLIDERS:
            continue
        line = chess.between(pinner, king)
        blockers = chess.SquareSet(line & after.occupied)
        diagonal = abs(chess.square_file(pinner) - chess.square_file(king)) == abs(chess.square_rank(pinner) - chess.square_rank(king))
        if not line or len(blockers) != 1 or (kind == chess.BISHOP and not diagonal) or (kind == chess.ROOK and diagonal):
            continue
        pinned = next(iter(blockers))
        if after.color_at(pinned) == chess.BLACK and (pinner == move.to_square or line & chess.BB_SQUARES[move.from_square]):
            return True
    return False


def skewer(before, move, targets):
    """The moved bishop, rook or queen checks the king, and the first piece beyond the king on that line is Black's
    and worth at least the checking piece, so taking it once the king steps aside never loses material."""
    after = after_move(before, move)
    piece, king = after.piece_at(move.to_square), after.king(chess.BLACK)
    if piece.piece_type not in SLIDERS or king not in after.attacks(move.to_square):
        return False
    df = (chess.square_file(king) > chess.square_file(move.to_square)) - (chess.square_file(king) < chess.square_file(move.to_square))
    dr = (chess.square_rank(king) > chess.square_rank(move.to_square)) - (chess.square_rank(king) < chess.square_rank(move.to_square))
    file, rank = chess.square_file(king) + df, chess.square_rank(king) + dr
    while 0 <= file < 8 and 0 <= rank < 8:
        behind = after.piece_at(chess.square(file, rank))
        if behind is not None:
            return behind.color == chess.BLACK and VALUES[behind.piece_type] >= VALUES[piece.piece_type]
        file, rank = file + df, rank + dr
    return False


def discovered(before, move, targets):
    """The moved piece was the only piece between a white bishop, rook or queen and Black's king or queen; after the
    move that line piece attacks it."""
    after = after_move(before, move)
    aims = [before.king(chess.BLACK), *before.pieces(chess.QUEEN, chess.BLACK)]
    for line_piece in chess.SquareSet(before.occupied_co[chess.WHITE]):
        if line_piece == move.from_square or before.piece_type_at(line_piece) not in SLIDERS:
            continue
        for aim in aims:
            if chess.between(line_piece, aim) & before.occupied == chess.BB_SQUARES[move.from_square] \
                    and aim in after.attacks(line_piece) and after.piece_at(aim) == before.piece_at(aim):
                return True
    return False


def remove_defender(before, move, targets):
    """A target (a square the line's completing move captures on) holds a black piece that White attacks and exactly
    one black piece guards; the move captures that guard, or a pawn steps up to attack it."""
    after = after_move(before, move)
    for target in targets:
        piece = before.piece_at(target)
        if piece is None or piece.color != chess.BLACK or piece.piece_type == chess.KING or not before.is_attacked_by(chess.WHITE, target):
            continue
        guards = before.attackers(chess.BLACK, target)
        if len(guards) != 1:
            continue
        guard = next(iter(guards))
        if move.to_square == guard:
            return True
        if before.piece_type_at(move.from_square) == chess.PAWN and not before.is_capture(move) and guard in after.attacks(move.to_square):
            return True
    return False


GEOMETRY = {'fork': fork, 'pin': pin, 'skewer': skewer, 'discovered': discovered, 'removeDefender': remove_defender}


def mate_in_one(board):
    for reply in board.legal_moves:
        board.push(reply)
        mated = board.is_checkmate()
        board.pop()
        if mated:
            return reply.uci()
    return None


def replay(where, teaching, root):
    """Every visit to a teaching node as (index, board), after checking legality, fingerprints and structure."""
    visits = []

    def visit(index, board, path):
        assert 0 <= index < len(teaching) and index not in path, (where, 'node out of range or on a loop', index)
        node = teaching[index]
        assert board.turn == chess.WHITE and node['fingerprint'] == board.board_fen() + ' w', (where, 'fingerprint', index)
        legal = {m.uci() for m in board.legal_moves}
        replies, following = node.get('replies', {}), node.get('next', {})
        assert node['accepted'] and set(node['accepted']) <= legal, (where, 'accepted move not legal', index)
        for move, reply in replies.items():
            assert move in legal and chess.Move.from_uci(reply) in after_move(board, chess.Move.from_uci(move)).legal_moves, (where, 'illegal reply', move, reply)
        visits.append((index, board.copy()))
        for move in node['accepted']:
            assert (move in replies) == (move in following), (where, 'a reply exactly when the graph continues', move)
            if move in following:
                after = after_move(board, chess.Move.from_uci(move))
                after.push(chess.Move.from_uci(replies[move]))
                visit(following[move], after, path | {index})

    visit(0, root.copy(), frozenset())
    assert {i for i, _ in visits} == set(range(len(teaching))), (where, 'unreached teaching nodes')
    return visits


def audit_refutations(where, teaching, visits, search):
    """A reply to a move the graph does not accept must show why it fails: it mates, or White ends at least a pawn
    down against the material at the node."""
    for index, board in visits:
        node = teaching[index]
        for move, reply in node.get('replies', {}).items():
            if move in node['accepted']:
                continue
            before = material(board)
            after = after_move(board, chess.Move.from_uci(move))
            after.push(chess.Move.from_uci(reply))
            assert after.is_checkmate() or search.white(after, DEPTH - 2) - before <= -1, (where, 'reply does not refute', move, reply)


def audit_move_kind(where, practice, root):
    """A teaching graph without a graph checkpoint is one move of a checkpoint's kind: it accepts exactly the legal
    castling (or en-passant) moves of the practice position, and each completes it."""
    kinds = [c['kind'] for c in practice['checkpoints'] if c['kind'] in ('castle', 'enPassant')]
    assert len(kinds) == 1, (where, 'a one-move graph belongs to one castle or enPassant checkpoint')
    test = root.is_castling if kinds[0] == 'castle' else root.is_en_passant
    expected = {m.uci() for m in root.legal_moves if test(m)}
    node = practice['teaching'][0]
    assert expected and len(practice['teaching']) == 1 and 'next' not in node and set(node['accepted']) == expected, \
        (where, f'accepts {sorted(node["accepted"])}, but the legal {kinds[0]} moves are {sorted(expected)}')


def audit_development(where, practice, root):
    """A graph checkpoint without a tactic is a developing move that stops a mate: the root accepts exactly the moves
    of a knight or bishop from its starting square after which Black has no mate in one, and each completes it. Every
    other move that allows mate in one is answered by that mate; every other move gets its own mistakes text."""
    teaching, mistakes = practice['teaching'], practice.get('mistakes', {})
    node = teaching[0]
    assert len(teaching) == 1 and 'next' not in node, (where, 'a development graph is one decision')
    for move in root.legal_moves:
        develops = root.piece_type_at(move.from_square) in (chess.KNIGHT, chess.BISHOP) and move.from_square in MINOR_HOMES
        mate = mate_in_one(after_move(root, move))
        accepted = move.uci() in node['accepted']
        assert accepted == (develops and mate is None), (where, 'development stopping the mate', move.uci(), accepted)
        if accepted:
            continue
        if mate is not None:
            reply = node.get('replies', {}).get(move.uci())
            assert reply is not None and after_move(after_move(root, move), chess.Move.from_uci(reply)).is_checkmate(), (where, 'a move allowing mate is answered by it', move.uci())
        else:
            assert move.uci() in mistakes, (where, 'a move that stops the mate without developing needs its own text', move.uci())


def audit_tactic(where, practice, root, checkpoint, search):
    """See the module docstring: geometry, gain against every defence, best authored defence, completeness."""
    tactic, gain, teaching = checkpoint['tactic'], checkpoint['gain'], practice['teaching']
    shaped = GEOMETRY[tactic]
    start = material(root)
    visits = replay(where, teaching, root)
    completing = {i: [m for m in teaching[i]['accepted'] if m not in teaching[i].get('next', {})] for i in range(len(teaching))}
    targets = {chess.Move.from_uci(m).to_square for i, b in visits for m in completing[i] if b.is_capture(chess.Move.from_uci(m))}
    first = set(teaching[0]['accepted'])
    for move in root.legal_moves:
        geometry = shaped(root, move, targets)
        assert geometry or move.uci() not in first, (where, f'{move.uci()} is accepted but is not a {tactic}')
        if geometry:
            worst, _ = search.decision(root, move)
            assert (worst - start >= gain) == (move.uci() in first), \
                (where, f'{move.uci()} is a {tactic} that wins {worst - start} against best defence; gain {gain}, accepted {move.uci() in first}')
    for index, board in visits:
        node = teaching[index]
        for uci in node['accepted']:
            move = chess.Move.from_uci(uci)
            worst, replies = search.decision(board, move)
            assert worst - start >= gain, (where, f'{uci} at node {index} wins only {worst - start}')
            if uci in node.get('next', {}):
                assert replies[node['replies'][uci]] == worst, (where, f'reply {node["replies"][uci]} to {uci} is not a best defence', replies[node['replies'][uci]] - start, worst - start)
            else:
                assert search.banked(board, move) - start >= gain, (where, f'{uci} completes the line before the gain is banked')
        if completing[index]:
            for move in board.legal_moves:
                if move.uci() in node['accepted'] or search.banked(board, move) - start < gain:
                    continue
                assert search.decision(board, move)[0] - start < gain, (where, f'{move.uci()} at node {index} also banks the gain but is not accepted')
    return visits


def can_promote(board):
    """A white pawn with no black pawn ahead of it on its file."""
    return any(not any(board.piece_at(chess.square(chess.square_file(pawn), rank)) == chess.Piece(chess.PAWN, chess.BLACK)
                       for rank in range(chess.square_rank(pawn) + 1, 8)) for pawn in board.pieces(chess.PAWN, chess.WHITE))


def castling_reachable(root, teaching, visits):
    """A legal castling move at the start, at a teaching node, or right after a move that completes the graph."""
    boards = [root] + [board for _, board in visits]
    for index, board in visits:
        for move in teaching[index]['accepted']:
            if move not in teaching[index].get('next', {}):
                after = after_move(board, chess.Move.from_uci(move))
                after.turn, after.ep_square = chess.WHITE, None
                boards.append(after)
    return any(board.is_castling(move) for board in boards for move in board.legal_moves)


def audit_practice(where, practice, frames, beats, search):
    """Check one lesson's practice exercise; returns what kind of exercise it is."""
    root = chess.Board(practice['fen'])
    assert root.turn == chess.WHITE and root.is_valid(), (where, 'practice position')
    assert {'beat', 'checkpoints'} <= set(practice), (where, 'practice is a full exercise')
    kinds = [c['kind'] for c in practice['checkpoints']]
    # Every checkpoint is possible from the start.
    if 'mate' in kinds:
        assert not root.has_insufficient_material(chess.WHITE), (where, 'White cannot mate with this material')
    if set(kinds) & {'pawnAdvance', 'pawnCapture', 'enPassant', 'promote'}:
        assert root.pieces(chess.PAWN, chess.WHITE), (where, 'a pawn checkpoint without a white pawn')
    if 'enPassant' in kinds:
        assert root.has_legal_en_passant(), (where, 'no legal en-passant capture at the start')
    if 'promote' in kinds:
        assert can_promote(root), (where, 'no white pawn can still promote')
    if 'attackQueen' in kinds:
        assert root.pieces(chess.QUEEN, chess.BLACK), (where, 'no black queen to attack')
    index = [b['id'] for b in beats].index(practice['beat'])
    shown = position_of(root)
    assert frames[index]['start']['board'] == shown == frames[index]['end']['board'], (where, 'beat board is not the practice position')
    teaching = practice.get('teaching')
    if teaching is None:
        assert 'graph' not in kinds, (where, 'graph checkpoint without a graph')
        assert 'castle' not in kinds or castling_reachable(root, [], []), (where, 'no legal castling at the start or in the graph')
        return 'checkpoints only'
    graph = next((c for c in practice['checkpoints'] if c['kind'] == 'graph'), None)
    if graph is not None and 'tactic' in graph:
        visits = audit_tactic(where, practice, root, graph, search)
        kind = graph['tactic']
    else:
        visits = replay(where, teaching, root)
        if graph is None:
            audit_move_kind(where, practice, root)
            kind = next(k for k in kinds if k in ('castle', 'enPassant'))
        else:
            audit_development(where, practice, root)
            kind = 'development'
    assert 'castle' not in kinds or castling_reachable(root, teaching, visits), (where, 'no legal castling at the start or in the graph')
    audit_refutations(where, teaching, visits, search)
    return kind


def audit_course_practice(course):
    found = {}
    for li, lesson in enumerate(course['lessons']):
        if 'practice' in lesson:
            found[lesson['id']] = audit_practice(lesson['id'], lesson['practice'], course['frames'][li], lesson['beats'], MaterialSearch())
    return found


def mutations(course):
    """Plant one defect at a time in a copy of the published exercises (files are never touched). Each plant must be
    rejected by the rule it targets, recognised by that rule's message; a plant that passes, or fails for another
    reason, fails this run."""
    lessons = {lesson['id']: (li, lesson) for li, lesson in enumerate(course['lessons'])}

    def plant(lesson_id, change):
        li, lesson = lessons[lesson_id]
        practice = copy.deepcopy(lesson['practice'])
        change(practice)
        return lambda: audit_practice(lesson_id, practice, course['frames'][li], lesson['beats'], MaterialSearch())

    def tactic(practice):
        return next(c for c in practice['checkpoints'] if c['kind'] == 'graph')

    def accept(node, move):
        return lambda practice: practice['teaching'][node]['accepted'].append(move)

    def fingerprint(fen, *line):
        board = chess.Board(fen)
        for move in line:
            board.push_uci(move)
        return board.board_fen() + ' w'

    def weaker_fork_defence(practice):
        practice['teaching'][0]['replies']['g5e6'] = 'd8e8'
        practice['teaching'][1]['fingerprint'] = fingerprint(practice['fen'], 'g5e6', 'd8e8')

    def drop_discovered_branch(practice):
        root = practice['teaching'][0]
        root['accepted'].remove('e5g6')
        del root['replies']['e5g6'], root['next']['e5g6'], practice['teaching'][2]

    def grab_guarded_piece(practice):
        practice['teaching'][0]['accepted'].append('d1d4')
        del practice['teaching'][0]['replies']['d1d4']

    def second_capture_left_out():
        # The removing-the-defender position with a white knight on f5 as a second attacker of d4: once the guard is
        # gone, both the rook and the knight bank the bishop. The line is built from the search's own best defence.
        fen = '6k1/pp3ppp/2n5/1B3N2/3b4/8/PPP2PPP/3R2K1 w - - 0 1'
        root, search = chess.Board(fen), MaterialSearch()
        worst, replies = search.decision(root, chess.Move.from_uci('b5c6'))
        reply = min(sorted(replies), key=lambda r: replies[r])
        practice = {'fen': fen, 'teaching': [
            {'fingerprint': fingerprint(fen), 'accepted': ['b5c6'], 'replies': {'b5c6': reply}, 'next': {'b5c6': 1}},
            {'fingerprint': fingerprint(fen, 'b5c6', reply), 'accepted': ['d1d4']}]}
        checkpoint = {'kind': 'graph', 'label': 'x', 'tactic': 'removeDefender', 'gain': 3}
        return lambda: audit_tactic('synthetic', practice, root, checkpoint, search)

    def kingside_only(practice):
        # Castling Rules with only the kingside right, which Black's bishop on a6 denies, and no graph.
        for field in ('teaching', 'offTrack', 'mistakes'):
            practice.pop(field)
        practice['fen'] = practice['fen'].replace(' KQ ', ' K ')

    planted = {
        'fingerprint that does not match the position': (plant('fork', lambda p: p['teaching'][1].__setitem__('fingerprint', p['teaching'][0]['fingerprint'])), "'fingerprint'"),
        'a reply without next': (plant('fork', lambda p: p['teaching'][0].pop('next')), 'a reply exactly when'),
        'an unreachable node': (plant('fork', lambda p: p['teaching'].append(copy.deepcopy(p['teaching'][1]))), 'unreached teaching nodes'),
        'beat bound to another board': (plant('fork', lambda p: p.__setitem__('beat', 'fork:13')), 'beat board is not the practice position'),
        'mate with too little material': (plant('queen-mate', lambda p: p.__setitem__('fen', '8/8/8/4k3/8/8/8/2KB4 w - - 0 1')), 'cannot mate'),
        'fork: a weaker authored defence': (plant('fork', weaker_fork_defence), 'is not a best defence'),
        'fork: gain above what the line wins': (plant('fork', lambda p: tactic(p).__setitem__('gain', tactic(p)['gain'] + 1)), 'against best defence'),
        'fork: an accepted move with no fork': (plant('fork', accept(0, 'd1h5')), 'is not a fork'),
        'fork: a reply that refutes nothing': (plant('fork', lambda p: p['teaching'][0]['replies'].__setitem__('g5f7', 'h8g8')), 'does not refute'),
        'skewer: an accepted check that is no skewer': (plant('skewer', accept(0, 'd1e1')), 'is not a skewer'),
        'discovered: a winning discovered check left out': (plant('discovered-attack', drop_discovered_branch), 'e5g6 is a discovered that wins'),
        'discovered: completing before the gain is banked': (plant('discovered-attack', lambda p: p['teaching'][1].__setitem__('accepted', ['h2h3'])), 'before the gain is banked'),
        'removeDefender: grabbing the guarded piece': (plant('removing-the-defender', grab_guarded_piece), 'is not a removeDefender'),
        'removeDefender: a second banking capture left out': (second_capture_left_out(), 'also banks the gain but is not accepted'),
        'castling: a king step accepted as castling': (plant('castling', accept(0, 'e1f1')), 'legal castle moves'),
        'castling-rules: the legal castling left out': (plant('castling-rules', lambda p: p['teaching'][0].__setitem__('accepted', ['e1d1'])), 'legal castle moves'),
        'en passant: a pawn push accepted instead': (plant('promotion-en-passant', accept(0, 'a6a7')), 'legal enPassant moves'),
        'development: a queen move accepted': (plant('scholars-mate', accept(0, 'd1e2')), 'development stopping the mate'),
        'development: a safe development left out': (plant('scholars-mate', lambda p: p['teaching'][0]['accepted'].remove('g1h3')), 'development stopping the mate'),
        'development: a mating answer replaced': (plant('scholars-mate', lambda p: p['teaching'][0]['replies'].__setitem__('g1e2', 'h7h6')), 'answered by it'),
        'development: a stopping move without its own text': (plant('scholars-mate', lambda p: p['mistakes'].pop('d2d4')), 'needs its own text'),
        'pin: gain above what the line wins': (plant('pin', lambda p: tactic(p).__setitem__('gain', tactic(p)['gain'] + 1)), 'against best defence'),
        'pin: the pawn attack accepted before the pin': (plant('pin', accept(0, 'd4d5')), 'is not a pin'),
        'checkpoint: en passant with no capture at the start': (plant('pawn', lambda p: p['checkpoints'].__setitem__(1, {'kind': 'enPassant', 'label': 'x'})), 'no legal en-passant capture'),
        'checkpoint: promotion with every pawn blocked': (plant('castling', lambda p: p['checkpoints'].append({'kind': 'promote', 'label': 'x'})), 'no white pawn can still promote'),
        'checkpoint: castling that is never legal': (plant('castling-rules', kingside_only), 'no legal castling'),
    }
    caught = {}
    for name, (run, expected) in planted.items():
        try:
            run()
        except AssertionError as error:
            assert expected in str(error), f'{name}: rejected for another reason: {error}'
            caught[name] = str(error)[:200]
            continue
        raise AssertionError(f'planted defect passed the audit: {name}')
    # Each geometry predicate tells its tactic from a near miss on a real board.
    shapes = [('fork', 'rn1q1r1k/ppp3pp/8/6N1/8/8/PPPP1PPP/R1BQ2K1 w - - 0 1', 'g5e6', 'g5f3'),
              ('pin', '1r1qkbnr/1pp1pppp/2np4/p7/2BPP3/2N1B2P/PPPQ1PP1/R4RK1 w k - 0 12', 'c4b5', 'c4d3'),
              ('skewer', 'rr4q1/p1pn2pp/4k3/8/8/2N5/PPPQ1PPP/3R1BK1 w - - 0 1', 'f1c4', 'd1e1'),
              ('discovered', '4k2r/pp3ppp/8/2q1N3/8/8/P4PPP/4R1K1 w - - 0 1', 'e5d3', 'e1d1'),
              ('removeDefender', '6k1/pp3ppp/2n5/1B6/3b4/8/PPP2PPP/3R2K1 w - - 0 1', 'b5c6', 'd1d4')]
    for name, fen, yes, no in shapes:
        board = chess.Board(fen)
        assert GEOMETRY[name](board, chess.Move.from_uci(yes), {chess.D4}), (name, 'misses', yes)
        assert not GEOMETRY[name](board, chess.Move.from_uci(no), {chess.D4}), (name, 'accepts', no)
        caught[f'{name} predicate'] = f'{yes} has it, {no} does not'
    return caught


def main():
    spec = importlib.util.spec_from_file_location('prepare', ROOT / 'Tools/prepare-lesson-scripts.py')
    prepare = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prepare)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--course', type=Path, default=ROOT / 'Sources/CheckmateCore/Resources/course.json')
    parser.add_argument('--mutations', action='store_true', help='Plant defects in the practice exercises and require the audit to reject each.')
    args = parser.parse_args()
    course = json.loads(args.course.read_text())
    if args.mutations:
        print(json.dumps({'passed': True, 'caught': mutations(course)}, indent=2))
        return
    moves = segments = 0
    for li, lesson in enumerate(course['lessons']):
        for si, beat in enumerate(lesson['beats']):
            moves += check_beat(beat['id'], beat, course['frames'][li][si])
            segments += 1
    puzzles = sum(check_puzzle(p, prepare) for p in course['puzzles'])
    practice = audit_course_practice(course)
    print(json.dumps({'passed': True, 'lessons': len(course['lessons']), 'segments': segments,
                      'authoredMoves': moves, 'puzzlesCrossChecked': puzzles, 'practice': practice}, indent=2))


if __name__ == '__main__':
    main()
