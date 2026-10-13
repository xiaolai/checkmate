import importlib.util
import unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('align',Path(__file__).with_name('align-lesson-actions.py'))
align=importlib.util.module_from_spec(spec);spec.loader.exec_module(align)
class AlignmentTests(unittest.TestCase):
    def testCoordinateNormalisationAndChronologicalPhrases(self):
        text='The white rook slides from C3 to C4. The white rook slides from C4 to C5.'
        words=[{'word':word,'start':i*0.1} for i,word in enumerate(text.split())]
        cues=align.align(words,['The white rook slides from C three to C four','The white rook slides from C four to C five'],5)
        self.assertEqual(cues,[0,0.16])
    def testMissingAndReversedPhrasesFailClosed(self):
        words=[{'word':'Hello','start':0}]
        with self.assertRaises(ValueError):align.align(words,['The queen moves'],4)
        text='The queen moves. The rook moves.'
        words=[{'word':word,'start':i*0.1} for i,word in enumerate(text.split())]
        with self.assertRaises(ValueError):align.align(words,['The rook moves','The queen moves'],4)
    def testAPhraseThatFitsTwoPlacesIsRejected(self):
        text='The pawn on A six guards B five. Later the pawn on A six guards B five again.'
        words=[{'word':word,'start':i*0.1} for i,word in enumerate(text.split())]
        with self.assertRaisesRegex(ValueError,'two places'):align.align(words,['The pawn on A six guards B five'],4)
        # The same sentence once, beside a merely similar one, is unambiguous.
        text="Black's pawn on F seven is guarded only by Black's king. White's pawn on F two is guarded only by White's king."
        words=[{'word':word,'start':i*0.1} for i,word in enumerate(text.split())]
        self.assertEqual(align.align(words,["White's pawn on F two is guarded only by White's king"],4),[0.275])
    def testTimestampsOutsideTheRecordingAreRejected(self):
        for start in (-0.1,4.5,None):
            with self.subTest(start),self.assertRaisesRegex(ValueError,'outside its recording'):
                align.align([{'word':'The','start':0},{'word':'queen','start':start}],['The queen'],4)
        self.assertEqual(align.align([{'word':'The','start':4.1},{'word':'queen','start':4.2}],['The queen'],4),[1])
    def testEachPhraseTakesItsOwnSentence(self):
        text='The rook moves to D one. Then the king steps to E two.'
        words=[{'word':word,'start':i*0.1} for i,word in enumerate(text.split())]
        self.assertEqual(align.align(words,['The rook moves to D one','the king steps to E two'],4),[0,0.175])
if __name__=='__main__':unittest.main()
