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
"""
import argparse
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


def main():
    spec = importlib.util.spec_from_file_location('prepare', ROOT / 'Tools/prepare-lesson-scripts.py')
    prepare = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prepare)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--course', type=Path, default=ROOT / 'Sources/CheckmateCore/Resources/course.json')
    course = json.loads(parser.parse_args().course.read_text())
    moves = segments = 0
    for li, lesson in enumerate(course['lessons']):
        for si, beat in enumerate(lesson['beats']):
            moves += check_beat(beat['id'], beat, course['frames'][li][si])
            segments += 1
    puzzles = sum(check_puzzle(p, prepare) for p in course['puzzles'])
    print(json.dumps({'passed': True, 'lessons': len(course['lessons']), 'segments': segments,
                      'authoredMoves': moves, 'puzzlesCrossChecked': puzzles}, indent=2))


if __name__ == '__main__':
    main()
