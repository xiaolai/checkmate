"""The lesson rules agree with published perft counts (every legal move sequence to a fixed depth)."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('lesson_rules', Path(__file__).resolve().parent / 'lesson_rules.py')
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)


def fen(text):
    placement, colour, castling, en_passant = text.split()[:4]
    board = {}
    for row, rank in zip(placement.split('/'), '87654321'):
        file = 0
        for char in row:
            if char.isdigit():
                file += int(char)
            else:
                board[rules.FILES[file] + rank] = ('w' if char.isupper() else 'b') + char.lower()
                file += 1
    return board, colour, '' if castling == '-' else castling, None if en_passant == '-' else en_passant


def after(board, colour, castling, en_passant, move):
    piece = board[move[0]]
    result = rules.play(board, move, en_passant)
    for square, rights in (('e1', 'KQ'), ('e8', 'kq'), ('h1', 'K'), ('a1', 'Q'), ('h8', 'k'), ('a8', 'q')):
        if square in (move[0], move[1]):
            castling = ''.join(c for c in castling if c not in rights)
    passed = None
    if piece[1] == 'p' and abs(int(move[0][1]) - int(move[1][1])) == 2:
        passed = move[0][0] + str((int(move[0][1]) + int(move[1][1])) // 2)
    return result, rules.other(colour), castling, passed


def perft(board, colour, castling, en_passant, depth):
    if depth == 0:
        return 1
    return sum(perft(*after(board, colour, castling, en_passant, move), depth - 1)
               for move in rules.legal_moves(board, colour, en_passant, castling))


class PerftTests(unittest.TestCase):
    def check(self, text, counts):
        for depth, expected in enumerate(counts, 1):
            with self.subTest(text, depth=depth):
                self.assertEqual(perft(*fen(text), depth), expected)

    def testStartingPosition(self):
        self.check('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1', [20, 400, 8902])

    def testCastlingPinsAndEnPassant(self):  # "Kiwipete"
        self.check('r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1', [48, 2039])

    def testEnPassantDiscoveredCheck(self):
        self.check('8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1', [14, 191, 2812])

    def testPromotionsAndChecks(self):
        self.check('r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1', [6, 264, 9467])

    def testMateAndStalemate(self):
        board, *_ = fen('6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1')
        self.assertTrue(rules.checkmated(rules.play(board, ['a1', 'a8']), 'b'))
        board, *_ = fen('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1')
        self.assertTrue(rules.stalemated(board, 'b'))

    def testPartialBoardsHaveGeometry(self):
        self.assertEqual(rules.destinations({'d4': 'wr'}, 'd4'), {f + '4' for f in 'abcefgh'} | {'d' + r for r in '1235678'})
        self.assertEqual(rules.attacks({'d4': 'wr', 'd6': 'bp'}, 'd4') & {'d6', 'd7'}, {'d6'})


if __name__ == '__main__':
    unittest.main()
