#!/usr/bin/env python3
"""Contracts of the narration coverage judge (Tools/check-narration-coverage.py), on the real failures it was built
from and the transcript habits that must not fail a complete clip."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('coverage', Path(__file__).with_name('check-narration-coverage.py'))
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)
judge = coverage.judge


class CoverageJudgeTests(unittest.TestCase):
    def testADroppedFinalSentenceFails(self):
        # bishop-practice:12 once ended "... on its turn", which inverts the rule it teaches.
        script = 'Black has no move. A side with no move on its turn loses.'
        problems = judge(script, 'Black has no move. A side with no move on its turn.', 'with no move on its turn.')
        self.assertTrue(any('end is not heard' in p for p in problems), problems)

    def testAMissingRunInsideTheClipFails(self):
        script = 'The pawn on D five attacks C four and E four, while D four is safe, as you can see.'
        problems = judge(script, 'The pawn on d5 attacks c4 and e4, as you can see.', 'as you can see.')
        self.assertTrue(any(p.startswith('missing') for p in problems), problems)

    def testAFinalSentenceTheFullTranscriptDroppedButTheTailHoldsPasses(self):
        script = 'Two rooks climb the board. Checkmate!'
        self.assertEqual(judge(script, 'Two rooks climb the board.', 'climb the board. Checkmate!'), [])

    def testAMisspokenSquareFails(self):
        # puzzles-material:6 once said "S six" for "F six".
        script = "Puzzle two. Black's knight on F six attacks White's knight on D five."
        problems = judge(script, "Puzzle 2. Black's knight on S6 attacks White's knight on D5.", "White's knight on D5.")
        self.assertIn('wrong square: script f6, heard s6', problems)

    def testTranscriptHabitsDoNotFailACompleteClip(self):
        cases = [
            ("Ranks are numbered 1 to 8, starting from White's side.", 'numbered 1 to 8, starting from Whiteside.'),
            ('From F five, this one attacks eleven squares.', 'From F5, this one attacks 11 squares.'),
            ("So nothing defends Black's bishop any more.", "So nothing defends Black's bishop anymore."),
            ('It has to climb to the sixth rank.', 'It has to climb to the 6th rank.'),
            ("The pawn runs all the way to Black's.", 'The pawn runs all the way to blacks.'),
            ('A good bishop likes the centre and its own colour.', 'A good bishop likes the center and its own color.'),
            ('It is said as castles kingside.', 'It is said as Castles King side.'),
            ('That is said as castles queenside.', "That is said as castle's queenside."),
            ("Black's knight attacks White's.", 'Black knight attacks White.'),
        ]
        for script, heard in cases:
            with self.subTest(script=script):
                self.assertEqual(judge(script, heard, heard), [])


if __name__ == '__main__':
    unittest.main()
