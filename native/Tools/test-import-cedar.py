"""Publication timing contracts; no API calls, encoding or playback."""
import importlib.util
import json
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('publisher', HERE / 'import-cedar-recordings.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class TimingTests(unittest.TestCase):
    def setUp(self):
        self.timing = json.loads((HERE.parent / 'Content/narration-packaging.json').read_text())['timing']

    def testShortAudioCannotTruncateMoveOrRemoval(self):
        beat = {'moves': [['a1','a2'],['a2','a3'],['a3','a4']], 'remove':['a4']}
        duration=publisher.step_duration(beat,0.1,self.timing)
        end=self.timing['movementStart']+2*self.timing['movementInterval']+self.timing['pieceDuration']+self.timing['removalDelay']
        self.assertGreaterEqual(duration,end+self.timing['postNarrationGap'])

    def testShortAudioCannotTruncateSixteenCounts(self):
        beat={'count':list(range(16))}
        duration=publisher.step_duration(beat,0.1,self.timing)
        self.assertGreaterEqual(duration,15*self.timing['minimumCountSpacing']+self.timing['postNarrationGap'])

    def testPauseAndAudioTailArePreserved(self):
        duration=publisher.step_duration({'pause':2},6.123,self.timing)
        self.assertGreaterEqual(duration,6.123+2+self.timing['postNarrationGap'])
        self.assertLess(duration-(6.123+2+self.timing['postNarrationGap']),1/self.timing['frameRate'])

    def testPublishedCourseKeepsBeatIdsAndBoardFixtures(self):
        baseline=json.loads((HERE.parent / 'Content/course-baseline.json').read_text())
        content=json.loads((HERE.parent / 'Content/course-scripts.en-GB.json').read_text())
        assets={beat['id']:{'file':'new/'+beat['id']+'.m4a','seconds':4} for lesson in content['lessons'] for beat in lesson['beats']}
        runtime=publisher.build_course(baseline,content,assets,self.timing,{'voice':'cedar'})
        self.assertEqual(runtime['frames'],baseline['frames'])
        self.assertEqual(runtime['sounds'],baseline['sounds'])
        self.assertEqual(runtime['exercises'],content['exercises'])
        self.assertEqual(runtime['lessons'],content['lessons'])
        self.assertEqual(sum(len(rows) for rows in runtime['voices']),947)


if __name__ == '__main__':
    unittest.main()
