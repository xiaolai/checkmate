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
if __name__=='__main__':unittest.main()
