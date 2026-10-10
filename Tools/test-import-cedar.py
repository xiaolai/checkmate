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
        self.assertEqual(runtime['sounds'],baseline['sounds'])
        self.assertEqual(runtime['exercises'],content['exercises'])
        self.assertFalse(runtime['exercises'])
        self.assertEqual(runtime['puzzles'],content['puzzles'])
        for li, lesson in enumerate(content['lessons']):
            for step, beat in enumerate(lesson['beats']):
                original_step=int(beat['id'].rsplit(':',1)[1])
                start=baseline['frames'][li][original_step]['start']
                published=runtime['lessons'][li]['beats'][step]
                self.assertEqual(published['id'],beat['id'])
                self.assertEqual(published['say'],beat['say'])
                self.assertEqual(published['set'],start.get('board'))
                self.assertEqual(published['hl'],start.get('hl',[]))
                self.assertEqual(published.get('moves'),beat.get('moves'))
                self.assertNotIn('quiz',published)
        self.assertEqual(sum(len(rows) for rows in runtime['voices']),864)

    def testRebuildReproducesPublishedContinuousCourse(self):
        root=HERE.parent
        baseline=json.loads((root/'Content/course-baseline.json').read_text())
        content=json.loads((root/'Content/course-scripts.en-GB.json').read_text())
        current=json.loads((root/'Sources/CheckmateCore/Resources/course.json').read_text())
        manifest=json.loads((root/'Sources/CheckmateCore/Resources/course-narration.json').read_text())
        assets={a['id']:a for a in manifest['assets']}
        rebuilt=publisher.build_course(baseline,content,assets,self.timing,current['narration'])
        self.assertEqual(rebuilt,current)


if __name__ == '__main__':
    unittest.main()
