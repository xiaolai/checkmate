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
        end=self.timing['movementStart']+3*self.timing['pieceDuration']+self.timing['removalDelay']
        self.assertGreaterEqual(duration,end+self.timing['postNarrationGap'])

    def testShortAudioCannotTruncateSixteenCounts(self):
        beat={'count':list(range(16))}
        duration=publisher.step_duration(beat,0.1,self.timing)
        self.assertGreaterEqual(duration,15*self.timing['minimumCountSpacing']+self.timing['postNarrationGap'])

    def testPauseAndAudioTailArePreserved(self):
        duration=publisher.step_duration({'pause':2},6.123,self.timing)
        self.assertGreaterEqual(duration,6.123+2+self.timing['postNarrationGap'])
        self.assertLess(duration-(6.123+2+self.timing['postNarrationGap']),1/self.timing['frameRate'])

    def testEncodingCacheRejectsChangedTextMasterOrSettings(self):
        master={'id':'knight:16','requestSHA256':'request','audioSHA256':'master','textSHA256':'text'}
        asset={'id':'knight:16','requestSHA256':'request','masterSHA256':'master','textSHA256':'text','file':'previous/16.m4a'}
        encoding={'codec':'aac','bitrate':64000}
        cache={'audioEncoding':encoding,'assets':[asset]}
        self.assertEqual(publisher.reusable_asset(cache,master,encoding),asset)
        self.assertIsNone(publisher.reusable_asset(cache,master,dict(encoding,bitrate=32000)))
        for field in ['requestSHA256','audioSHA256','textSHA256']:
            self.assertIsNone(publisher.reusable_asset(cache,dict(master,**{field:'changed'}),encoding))
        self.assertIsNone(publisher.reusable_asset({'assets':[asset]},master,encoding))

    def testPublishedCourseKeepsBeatIdsAndBoardFixtures(self):
        baseline=json.loads((HERE.parent / 'Content/course-baseline.json').read_text())
        content=json.loads((HERE.parent / 'Content/course-scripts.en-GB.json').read_text())
        cue_file=HERE.parent/'Content/lesson-action-cues.json'
        cues=json.loads(cue_file.read_text()).get('cues',{}) if cue_file.exists() else {}
        assets={beat['id']:{'file':'new/'+beat['id']+'.m4a','seconds':4,'textSHA256':__import__('hashlib').sha256(beat['speak'].encode()).hexdigest(),'masterSHA256':cues.get(beat['id'],{}).get('masterSHA256','fixture')} for lesson in content['lessons'] for beat in lesson['beats']}
        runtime=publisher.build_course(baseline,content,assets,self.timing,{'voice':'cedar'})
        self.assertEqual(runtime['sounds'],baseline['sounds'])
        self.assertEqual(runtime['exercises'],content['exercises'])
        self.assertFalse(runtime['exercises'])
        self.assertEqual(runtime['puzzles'],content['puzzles'])
        for li, lesson in enumerate(content['lessons']):
            for step, beat in enumerate(lesson['beats']):
                original_step=int(beat['id'].rsplit(':',1)[1])
                prep=publisher.module('prepare', 'prepare-lesson-scripts.py')
                start=prep.reference_frame(baseline,content,li,beat)['start']
                published=runtime['lessons'][li]['beats'][step]
                self.assertEqual(published['id'],beat['id'])
                self.assertEqual(published['say'],beat['say'])
                self.assertEqual(published['set'],start.get('board'))
                self.assertEqual(published['hl'],start.get('hl',[]))
                self.assertEqual(published.get('moves'),beat.get('moves'))
                self.assertNotIn('quiz',published)
        self.assertEqual(sum(len(rows) for rows in runtime['voices']),878)

    def testCorrectedKnightDemonstrationKeepsPawnsAndRejectsUnreviewedActions(self):
        import copy
        root=HERE.parent
        prep=publisher.module('prepare', 'prepare-lesson-scripts.py')
        baseline=json.loads((root/'Content/course-baseline.json').read_text())
        content=json.loads((root/'Content/course-scripts.en-GB.json').read_text())
        li=next(i for i,l in enumerate(content['lessons']) if l['id']=='knight')
        beat=next(b for b in content['lessons'][li]['beats'] if b['id']=='knight:16')
        frame=prep.reference_frame(baseline,content,li,beat)
        self.assertEqual(len(frame['start']['board']),32)
        self.assertEqual(frame['end']['board']['f3'],'wn')
        self.assertNotIn('g1',frame['end']['board'])
        for file in 'abcdefgh':
            self.assertEqual(frame['end']['board'][file+'2'],'wp')
            self.assertEqual(frame['end']['board'][file+'7'],'bp')
        mutated=copy.deepcopy(content)
        target=next(b for b in mutated['lessons'][li]['beats'] if b['id']=='knight:16')
        target['moves']=[['g1','e2']]
        with self.assertRaisesRegex(AssertionError,'Unreviewed illustration'):
            prep.validate(mutated,baseline)

    def testStartFramesHoldOverlaysUntilTheMovesLand(self):
        def frame(arrows, hl):
            return {'start': {'arrows': arrows, 'hl': hl}, 'end': {'arrows': arrows, 'hl': hl}}
        check, kept = {'sq': 'g8', 'kind': 'check'}, {'sq': 'e1', 'kind': 'focus'}
        frames = [frame([['c4', 'f7']], [kept]),
                  frame([['c4', 'f7'], ['a8', 'g8'], ['b1', 'c3']], [kept, check]),
                  frame([['d1', 'd8']], [check])]
        beats = [{}, {'moves': [['a1', 'a8'], ['b1', 'c3']]}, {}]
        publisher.stage_overlays(frames, beats)
        # Carried over, or previewing the beat's own move: shown at once. Describing the result: shown after the move.
        self.assertEqual(frames[1]['start'], {'arrows': [['c4', 'f7'], ['b1', 'c3']], 'hl': [kept]})
        self.assertEqual(frames[1]['end']['arrows'], [['c4', 'f7'], ['a8', 'g8'], ['b1', 'c3']])
        # A beat without moves shows everything from its start.
        self.assertEqual(frames[2]['start'], {'arrows': [['d1', 'd8']], 'hl': [check]})

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
