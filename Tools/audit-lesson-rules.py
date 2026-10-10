#!/usr/bin/env python3
"""Independent lesson-diagram audit. Run on build-host with python-chess installed.

This uses no app rules, credentials, playback, or microphone. Partial teaching
diagrams test geometry, not full-game legality or the historical side to move.
"""
import json
from pathlib import Path
import chess

ROOT = Path(__file__).resolve().parents[1]
CASTLING_ROOK_STEPS = {
    'castling:7', 'castling:11', 'castling:14', 'castling:20',
    'castling:24', 'castling:5', 'castling-rules:18', 'rulesReview:25',
    'opening:13', 'famous-game:15',
}
MATES = {
    'intro:12': 'b', 'check-and-checkmate:25': 'b', 'rulesReview:23': 'w',
    'draws:9': 'b', 'tournaments:9': 'b', 'scholars-mate:11': 'b',
    'two-rook-mate:14': 'b', 'queen-mate:20': 'b', 'queen-mate:23': 'b',
    'rook-mate:24': 'b', 'puzzles-mate:4': 'b',
    'puzzles-mate:6': 'b', 'puzzles-mate:9': 'b',
    'puzzles-mate:13': 'b', 'puzzles-mate:17': 'b', 'famous-game:24': 'b',
}
STALEMATES = {'draws:7': 'b', 'draws:18': 'b',
              'queen-mate:12': 'b', 'rook-mate:17': 'b'}


def board_of(position):
    board = chess.Board(None)
    for square, piece in (position or {}).items():
        board.set_piece_at(chess.parse_square(square),
                           chess.Piece.from_symbol(piece[1].upper() if piece[0] == 'w' else piece[1]))
    return board


def position_of(board):
    return {chess.square_name(square): ('w' if piece.color else 'b') + piece.symbol().lower()
            for square, piece in board.piece_map().items()}


def main():
    course = json.loads((ROOT / 'Sources/CheckmateCore/Resources/course.json').read_text())
    found = {}; moves = 0; safe_steps = 0; castle_exceptions = set()
    for li, lesson in enumerate(course['lessons']):
        for si, beat in enumerate(lesson['beats']):
            identity = beat['id']
            frame = course['frames'][li][si]
            board = board_of(frame['start']['board'])
            for move in beat.get('moves', []):
                moves += 1
                start, end = map(chess.parse_square, move[:2])
                piece = board.piece_at(start)
                assert piece is not None, (identity, 'missing source', move)
                target = board.piece_at(end)
                assert target is None or target.color != piece.color, (identity, 'friendly landing', move)
                dx = abs(chess.square_file(end) - chess.square_file(start))
                dy = abs(chess.square_rank(end) - chess.square_rank(start))
                valid = end in board.attacks(start)
                if piece.piece_type == chess.PAWN:
                    d = 1 if piece.color else -1
                    dr = chess.square_rank(end) - chess.square_rank(start)
                    valid = (dx == 0 and dr == d and target is None) or (
                        dx == 0 and dr == 2*d and chess.square_rank(start) == (1 if piece.color else 6)
                        and target is None and board.piece_at(start+d*8) is None) or (
                        dx == 1 and dr == d and target is not None)
                    if dx == 1 and dr == d and target is None:
                        captured = chess.square_name(end-d*8)
                        valid = captured in beat.get('remove', []) and board.piece_at(end-d*8) == chess.Piece(chess.PAWN, not piece.color)
                if piece.piece_type == chess.KING and dx == 2 and dy == 0:
                    # Castling is illustrated as two motions, not two turns.
                    rank = '1' if piece.color else '8'
                    corner, rook_end = ('h', 'f') if chess.square_file(end) > chess.square_file(start) else ('a', 'd')
                    assert [corner+rank, rook_end+rank] in beat.get('moves', []) or identity in {'castling:13', 'castling:19'}
                    valid = True
                if not valid and identity in CASTLING_ROOK_STEPS and piece.piece_type == chess.ROOK:
                    rank = '1' if piece.color else '8'
                    pair = (move[0], move[1])
                    king_square = ('g' if pair == ('h'+rank, 'f'+rank) else 'c')+rank
                    valid = pair in {('h'+rank, 'f'+rank), ('a'+rank, 'd'+rank)} and board.piece_at(chess.parse_square(king_square)) == chess.Piece(chess.KING, piece.color)
                    if valid: castle_exceptions.add(identity)
                assert valid, (identity, 'movement or path', move)
                board.remove_piece_at(start)
                promoted = move[2] if len(move) > 2 else None
                board.set_piece_at(end, chess.Piece.from_symbol(promoted[1].upper() if promoted[0] == 'w' else promoted[1]) if promoted else piece)
                if lesson['id'] == 'safe-squares':
                    assert not board.is_attacked_by(chess.BLACK, end), (identity, 'unsafe king route', move)
                    safe_steps += 1
            for square in beat.get('remove', []):
                assert board.remove_piece_at(chess.parse_square(square)) is not None, (identity, 'missing removal')
            assert position_of(board) == (frame['end']['board'] or {}), (identity, 'endpoint mismatch')
            found[identity] = frame
    assert castle_exceptions == CASTLING_ROOK_STEPS, 'Castling illustration inventory changed; review it explicitly'
    for cases, method in [(MATES, 'is_checkmate'), (STALEMATES, 'is_stalemate')]:
        for identity, side in cases.items():
            board = board_of(found[identity]['end']['board'])
            assert board.king(chess.WHITE) is not None and board.king(chess.BLACK) is not None
            board.turn = side == 'w'
            assert getattr(board, method)(), (identity, method)
    for identity in ['knight:14', 'knight:15', 'knight:16']:
        assert position_of(board_of(found[identity]['start']['board'])) == position_of(chess.Board())
    board = board_of(found['knight:16']['start']['board'])
    assert {chess.square_name(m.to_square) for m in board.legal_moves if m.from_square == chess.G1} == {'f3', 'h3'}
    board.push_uci('g1f3')
    assert position_of(board) == found['knight:16']['end']['board']
    print(json.dumps({'passed': True, 'lessons': len(course['lessons']), 'segments': len(found),
                      'authoredMoves': moves, 'castlingRookIllustrations': len(castle_exceptions),
                      'mateAndStalemateCases': len(MATES)+len(STALEMATES), 'safeKingRouteSteps': safe_steps,
                      'knightStartingPositionVerified': True}, indent=2))


if __name__ == '__main__':
    main()
