#!/usr/bin/env python3
"""The KPK oracle: named positions whose verdicts chess theory settles, the FEN boundary, the verdict command and the
full comparison of both implementations on every legal position (fast enough to run in the unit gate)."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('kpk_oracle', HERE / 'kpk-oracle.py')
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)

# name: (FEN, chess, promoteAndHold successPlies or None, over). Sources: key squares, opposition and the rook-pawn
# draw are the standard KPK theory of Dvoretsky's Endgame Manual (2003), chapter 1, and Fine's Basic Chess Endings
# (1941), chapter II; the stalemate and promotion rows follow from the FIDE Laws (stalemate and dead positions are
# draws) and D3; the longest KPK mate, 28 moves, is OEIS A260954 (from the Nalimov and Lomonosov tablebases).
FIXTURES = {
    # The defending king in the queening corner of a rook pawn cannot be driven out: a draw whoever moves.
    'rook-pawn-corner-white-to-move': ('k7/8/8/K7/P7/8/8/8 w - - 0 1', 'draw', None, None),
    'rook-pawn-corner-black-to-move': ('k7/8/8/K7/P7/8/8/8 b - - 0 1', 'draw', None, None),
    # The same draw with Black's h-pawn and White's king in h1 (both normalisations at once).
    'rook-pawn-corner-black-pawn': ('8/8/8/8/7p/7k/8/7K b - - 0 1', 'draw', None, None),
    # A rook pawn wins when the attacking king shoulders the defender away from the corner: b7 holds c6-c8.
    'rook-pawn-shouldered-win': ('8/1K1k4/8/P7/8/8/8/8 w - - 0 1', 'win', 6, None),
    # Opposition: kings e5 and e7, pawn e4. White to move cannot gain a key square (d6, e6, f6) against the opposition.
    'opposition-white-to-move-draws': ('8/4k3/8/4K3/4P3/8/8/8 w - - 0 1', 'draw', None, None),
    # Black to move must give way, and White's king reaches a key square.
    'opposition-black-to-move-wins': ('8/4k3/8/4K3/4P3/8/8/8 b - - 0 1', 'win', None, None),
    # The king on the sixth rank in front of a non-rook pawn wins whoever has the move.
    'sixth-rank-key-square-white-to-move': ('4k3/8/4K3/4P3/8/8/8/8 w - - 0 1', 'win', None, None),
    'sixth-rank-key-square-black-to-move': ('4k3/8/4K3/4P3/8/8/8/8 b - - 0 1', 'win', None, None),
    # The defending king takes the new piece: e8=Q or e8=R is captured, a minor piece is insufficient material, and
    # any other move loses the pawn.
    'promotion-captured': ('8/4Pk2/8/8/8/8/8/K7 w - - 0 1', 'draw', None, None),
    'promotion-defended': ('8/3KPk2/8/8/8/8/8/8 w - - 0 1', 'win', 2, None),
    # f8=Q (or f8=R) is checkmate, a success on the move; with Black to move the same position is stalemate.
    'promotion-mates': ('7k/5P2/6K1/8/8/8/8/8 w - - 0 1', 'win', 1, None),
    'mate-square-stalemate': ('7k/5P2/6K1/8/8/8/8/8 b - - 0 1', 'draw', None, 'stalemate'),
    # c8=Q stalemates the king on a7; c8=R leaves it b7 and a6, the shortest success.
    'queen-promotion-stalemates': ('8/k1P5/8/2K5/8/8/8/8 w - - 0 1', 'win', 2, None),
    # The pawn side itself can be stalemated: White's king is boxed in by its own pawn.
    'pawn-side-stalemated': ('K7/P1k5/8/8/8/8/8/8 w - - 0 1', 'draw', None, 'stalemate'),
    # The longest KPK mate (OEIS A260954): mate in 28.
    'longest-mate': ('8/8/8/1k6/8/8/K5P1/8 w - - 0 1', 'win', None, None),
}


def flipped(fen):
    """The same position with colours and ranks exchanged."""
    rows, mover = fen.split()[0].split('/'), fen.split()[1]
    return '/'.join(row.swapcase() for row in reversed(rows)) + (' b' if mover == 'w' else ' w') + ' - - 0 1'


def mirrored(fen):
    rows = [''.join(c if c.isalpha() else '.' * int(c) for c in row)[::-1] for row in fen.split()[0].split('/')]
    packed = ['' for _ in rows]
    for i, row in enumerate(rows):
        run = 0
        for c in row:
            if c == '.':
                run += 1
                continue
            packed[i] += (str(run) if run else '') + c
            run = 0
        packed[i] += str(run) if run else ''
    return '/'.join(packed) + ' ' + ' '.join(fen.split()[1:])


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.oracle = oracle.Oracle()

    def testNamedPositions(self):
        for name, (fen, chess, plies, over) in FIXTURES.items():
            with self.subTest(name):
                report = self.oracle.report(fen)
                self.assertEqual((report['chess'], report['over']), (chess, over))
                self.assertEqual(report['promoteAndHold'], 'success' if chess == 'win' else 'failure')
                if plies is not None:
                    self.assertEqual(report['successPlies'], plies)

    def testSymmetricTwinsAgree(self):
        for name, (fen, *_) in FIXTURES.items():
            report = self.oracle.report(fen)
            for twin in (flipped(fen), mirrored(fen), mirrored(flipped(fen))):
                with self.subTest(name, twin=twin):
                    other = self.oracle.report(twin)
                    self.assertEqual((other['chess'], other['successPlies'], other['over']), (report['chess'], report['successPlies'], report['over']))
                    self.assertNotEqual(other['pawnSide'] == report['pawnSide'], twin != mirrored(fen))

    def testForwardDistanceMatchesRetrograde(self):
        """Iterative deepening in the forward search finds the same shortest success as the retrograde distance:
        White's n moves are 2n plies (2n - 1 for a mate), and Black's reply comes first when Black is to move."""
        search = oracle.forward.Search()
        for name, (fen, *_) in FIXTURES.items():
            with self.subTest(name):
                _, _, wk, p, bk, white = oracle.parse(fen)
                plies = oracle.retro.distance('promoteAndHold', wk, p, bk, white)
                moves = search.moves_to_success(wk, p, bk, white)
                self.assertEqual(moves, None if plies is None else (plies + 1) // 2 if white else plies // 2)

    def testLongestMateIsTwentyEightMoves(self):
        _, _, wk, p, bk, white = oracle.parse(FIXTURES['longest-mate'][0])
        self.assertEqual(oracle.retro.distance('chess', wk, p, bk, white), 55)

    def testPromotionMechanisms(self):
        """The fixtures win or fail for the reason their names give, checked by the rules module."""
        rules = oracle.rules
        squares = oracle.board(FIXTURES['queen-promotion-stalemates'][0])
        self.assertTrue(rules.stalemated(rules.play(squares, ['c7', 'c8', 'wq']), 'b'))
        self.assertFalse(rules.stalemated(rules.play(squares, ['c7', 'c8', 'wr']), 'b'))
        squares = oracle.board(FIXTURES['promotion-mates'][0])
        self.assertTrue(rules.checkmated(rules.play(squares, ['f7', 'f8', 'wq']), 'b'))
        squares = oracle.board(FIXTURES['promotion-captured'][0])
        self.assertIn(['f7', 'e8'], rules.legal_moves(rules.play(squares, ['e7', 'e8', 'wq']), 'b'))
        self.assertIsNone(oracle.retro._pah_leaf('q', oracle.retro.index('a1'), oracle.retro.index('e8'), oracle.retro.index('f7')))
        self.assertFalse(oracle.forward.promotion_holds(oracle.forward.QUEEN, oracle.forward.square('a1'), oracle.forward.square('e8'), oracle.forward.square('f7')))


class BoundaryTests(unittest.TestCase):
    def testRejectsWhatIsNotALegalKpkStart(self):
        for fen, reason in [
            ('8/8/8/8/8/8/8/8 w - - 0 1', 'needs exactly'),
            ('k7/8/8/K7/PP6/8/8/8 w - - 0 1', 'needs exactly'),
            ('k7/8/8/K7/R7/8/8/8 w - - 0 1', 'not a KPK FEN'),
            ('kK6/8/8/8/P7/8/8/8 w - - 0 1', 'touching'),
            ('8/8/8/8/8/1k6/P7/K7 w - - 0 1', 'not to move is in check'),
            ('P6k/8/8/8/8/8/8/K7 w - - 0 1', 'first or last rank'),
            ('k7/8/8/K7/P7/8/8/8 w - - 3 1', 'halfmove clock of 0'),
            ('k7/8/8/K7/P7/8/8/8 w KQ - 0 1', 'no castling'),
            ('k7/8/8/K7/P7/8/8/8 w - a3 0 1', 'no en passant'),
            ('k7/8/8/K7/P7/8/8 w - - 0 1', 'not a KPK FEN'),
            ('k8/8/8/K7/P7/8/8/8 w - - 0 1', 'eight squares'),
        ]:
            with self.subTest(fen):
                with self.assertRaises(ValueError) as caught:
                    oracle.parse(fen)
                self.assertIn(reason, str(caught.exception))

    def testBlackInCheckWithBlackToMoveIsLegal(self):
        self.assertEqual(oracle.parse('8/8/8/8/8/1k6/P7/K7 b - - 0 1')[5], False)


class CommandTests(unittest.TestCase):
    def run_tool(self, *arguments):
        return subprocess.run([sys.executable, '-I', str(HERE / 'kpk-oracle.py'), *arguments], capture_output=True, text=True)

    def testVerdictPrintsOneLinePerStartWithTheGeneratorIdentity(self):
        fens = [FIXTURES['promotion-defended'][0], FIXTURES['opposition-white-to-move-draws'][0]]
        result = self.run_tool('verdict', *fens)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([line['fen'] for line in lines], fens)
        self.assertEqual([line['promoteAndHold'] for line in lines], ['success', 'failure'])
        self.assertEqual(set(lines[0]), {'fen', 'pawnSide', 'sideToMove', 'over', 'chess', 'promoteAndHold', 'successPlies', 'generator'})
        self.assertEqual(lines[0]['generator'], oracle.identity())
        self.assertEqual(json.loads(self.run_tool('identity').stdout), oracle.identity())

    def testSourceHashCoversEveryDecidingFile(self):
        self.assertEqual(oracle.SOURCES, ('kpk-oracle.py', 'kpk_retrograde.py', 'kpk_forward.py', 'lesson_rules.py'))
        self.assertRegex(oracle.identity()['sourceHash'], r'^[0-9a-f]{64}$')

    def testAnIllegalStartFailsTheCommand(self):
        result = self.run_tool('verdict', FIXTURES['promotion-defended'][0], 'kK6/8/8/8/P7/8/8/8 w - - 0 1')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertIn('touching', result.stderr)

    def testUsage(self):
        self.assertEqual(self.run_tool().returncode, 2)


class ExhaustiveTests(unittest.TestCase):
    def testBothImplementationsAgreeOnEveryLegalPosition(self):
        summary = oracle.exhaustive()
        print(json.dumps({k: summary[k] for k in ('legalPositions', 'disagreements', 'whiteToMove', 'blackToMove', 'maxChessMatePlies', 'maxSuccessPlies', 'seconds')}), file=sys.stderr)
        self.assertTrue(summary['ok'], summary)
        # 2 x 98,304 placements with the pawn on files a-d, less the illegal ones.
        self.assertEqual(summary['legalPositions'], summary['whiteToMove']['positions'] + summary['blackToMove']['positions'])
        self.assertEqual(summary['maxChessMatePlies'], 56)


if __name__ == '__main__':
    unittest.main()
