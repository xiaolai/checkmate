"""Chess rules for checking authored lesson content. No dependencies; never edits anything.

Boards are dicts from square ("e4") to piece code ("wp", "bk"). Lesson boards may be partial (a lone rook, no
kings), so movement geometry works on any board; legality, check and mate need both kings.
"""
FILES = 'abcdefgh'
SQUARES = [f + r for r in '12345678' for f in FILES]
PIECES = {c + p for c in 'wb' for p in 'pnbrqk'}
DIRECTIONS = {'b': [(1, 1), (1, -1), (-1, 1), (-1, -1)], 'r': [(1, 0), (-1, 0), (0, 1), (0, -1)]}
DIRECTIONS['q'] = DIRECTIONS['b'] + DIRECTIONS['r']
KNIGHT = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
KING = DIRECTIONS['q']


def xy(square):
    assert isinstance(square, str) and len(square) == 2 and square[0] in FILES and square[1] in '12345678', square
    return FILES.index(square[0]), int(square[1]) - 1


def name(x, y):
    return FILES[x] + str(y + 1) if 0 <= x < 8 and 0 <= y < 8 else None


def other(colour):
    return 'b' if colour == 'w' else 'w'


def valid_board(board):
    assert isinstance(board, dict), 'A board maps squares to pieces'
    for square, piece in board.items():
        xy(square)
        assert piece in PIECES, f'Unknown piece {piece!r} on {square}'
    for colour in 'wb':
        assert sum(p == colour + 'k' for p in board.values()) <= 1, 'At most one king per side'
    for square, piece in board.items():
        if piece[1] == 'p':
            assert square[1] not in '18', f'A pawn cannot stand on {square}'


def attacks(board, square):
    """Squares the piece on `square` attacks. A slider's line stops at the first piece, which it attacks."""
    piece = board[square]
    colour, kind = piece[0], piece[1]
    x, y = xy(square)
    result = set()
    if kind == 'p':
        step = 1 if colour == 'w' else -1
        for dx in (-1, 1):
            target = name(x + dx, y + step)
            if target:
                result.add(target)
    elif kind in 'nk':
        for dx, dy in (KNIGHT if kind == 'n' else KING):
            target = name(x + dx, y + dy)
            if target:
                result.add(target)
    else:
        for dx, dy in DIRECTIONS[kind]:
            cx, cy = x + dx, y + dy
            while name(cx, cy):
                target = name(cx, cy)
                result.add(target)
                if target in board:
                    break
                cx, cy = cx + dx, cy + dy
    return result


def attacked(board, square, by):
    """Whether any piece of colour `by` attacks `square`."""
    return any(p[0] == by and square in attacks(board, s) for s, p in board.items())


def destinations(board, square, en_passant=None, castling=''):
    """Pseudo-legal destinations (ignoring whether the mover's own king is left in check)."""
    piece = board[square]
    colour, kind = piece[0], piece[1]
    x, y = xy(square)
    result = set()
    if kind == 'p':
        step, home = (1, 1) if colour == 'w' else (-1, 6)
        one = name(x, y + step)
        if one and one not in board:
            result.add(one)
            two = name(x, y + 2 * step)
            if y == home and two not in board:
                result.add(two)
        for target in attacks(board, square):
            if target in board and board[target][0] != colour or target == en_passant:
                result.add(target)
        return result
    for target in attacks(board, square):
        if target not in board or board[target][0] != colour:
            result.add(target)
    if kind == 'k':
        rank = '1' if colour == 'w' else '8'
        if square == 'e' + rank and not attacked(board, square, other(colour)):
            for side, rook, between, path in (('K', 'h', 'fg', 'fg'), ('Q', 'a', 'bcd', 'dc')):
                right = side if colour == 'w' else side.lower()
                if right in castling and board.get(rook + rank) == colour + 'r' and all(f + rank not in board for f in between) \
                        and not any(attacked(board, f + rank, other(colour)) for f in path):
                    result.add(('g' if side == 'K' else 'c') + rank)
    return result


def play(board, move, en_passant=None):
    """Board after a move [from, to] or [from, to, promotion]; castling also moves the rook, en passant removes the pawn."""
    board = dict(board)
    origin, target = move[0], move[1]
    piece = board.pop(origin)
    if piece[1] == 'p' and target == en_passant and target not in board:
        del board[target[0] + origin[1]]
    if piece[1] == 'k' and abs(xy(origin)[0] - xy(target)[0]) == 2:
        rank = origin[1]
        rook_from, rook_to = ('h' + rank, 'f' + rank) if target[0] == 'g' else ('a' + rank, 'd' + rank)
        board[rook_to] = board.pop(rook_from)
    board[target] = move[2] if len(move) > 2 else piece
    return board


def advance(board, colour, castling, en_passant, move):
    """The position after a legal move: board, side to move, castling rights and en-passant square (FEN fields 1-4).

    A king or rook leaving home, or a rook captured at home, removes the matching rights; a pawn's double step leaves
    the square it passed over as the en-passant square.
    """
    piece = board[move[0]]
    result = play(board, move, en_passant)
    for square, rights in (('e1', 'KQ'), ('e8', 'kq'), ('h1', 'K'), ('a1', 'Q'), ('h8', 'k'), ('a8', 'q')):
        if square in (move[0], move[1]):
            castling = ''.join(c for c in castling if c not in rights)
    passed = None
    if piece[1] == 'p' and abs(int(move[0][1]) - int(move[1][1])) == 2:
        passed = move[0][0] + str((int(move[0][1]) + int(move[1][1])) // 2)
    return result, other(colour), castling, passed


def in_check(board, colour):
    king = next((s for s, p in board.items() if p == colour + 'k'), None)
    return king is not None and attacked(board, king, other(colour))


def legal_moves(board, colour, en_passant=None, castling=''):
    """Every legal move for `colour`; promotions are listed once per promotion piece."""
    assert colour + 'k' in board.values() and other(colour) + 'k' in board.values(), 'Legality needs both kings'
    moves = []
    for square, piece in board.items():
        if piece[0] != colour:
            continue
        for target in destinations(board, square, en_passant, castling):
            if piece[1] == 'p' and target[1] in '18':
                candidates = [[square, target, colour + p] for p in 'qrbn']
            else:
                candidates = [[square, target]]
            for move in candidates:
                if not in_check(play(board, move, en_passant), colour):
                    moves.append(move)
    return moves


def checkmated(board, colour):
    return in_check(board, colour) and not legal_moves(board, colour)


def stalemated(board, colour):
    return not in_check(board, colour) and not legal_moves(board, colour)
