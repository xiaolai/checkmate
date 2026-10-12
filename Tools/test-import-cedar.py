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

    def testPublishedCourseFollowsTheEditorialSource(self):
        root=HERE.parent
        content=json.loads((root/'Content/course-scripts.en-GB.json').read_text())
        sounds=json.loads((root/'Content/course-sounds.json').read_text())['sounds']
        prep=publisher.module('prepare', 'prepare-lesson-scripts.py')
        prep.fill_speech(content['lessons'])
        cue_file=root/'Content/lesson-action-cues.json'
        cues=json.loads(cue_file.read_text()).get('cues',{}) if cue_file.exists() else {}
        assets={beat['id']:{'file':'new/'+beat['id']+'.m4a','seconds':4,'textSHA256':__import__('hashlib').sha256(beat['speak'].encode()).hexdigest(),'masterSHA256':cues.get(beat['id'],{}).get('masterSHA256','fixture')} for lesson in content['lessons'] for beat in lesson['beats']}
        runtime=publisher.build_course(sounds,content,assets,self.timing,{'voice':'cedar'})
        self.assertEqual(runtime['sounds'],sounds)
        self.assertFalse(runtime['exercises'])
        self.assertEqual(runtime['puzzles'],content['puzzles'])
        for li, lesson in enumerate(content['lessons']):
            frames=prep.lesson_frames(lesson)
            self.assertEqual(runtime['stepTitles'][li],[b['label'] for b in lesson['beats']])
            for step, beat in enumerate(lesson['beats']):
                published=runtime['lessons'][li]['beats'][step]
                self.assertEqual(published['id'],beat['id'])
                self.assertEqual(published['say'],beat['say'])
                self.assertEqual(published['set'],frames[step]['start']['board'])
                self.assertEqual(published['big'],beat['big'])
                self.assertEqual(published.get('moves'),beat.get('moves'))
                self.assertNotIn('label',published)
                self.assertNotIn('quiz',published)
        self.assertEqual(sum(len(rows) for rows in runtime['voices']),sum(len(l['beats']) for l in content['lessons']))

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
        content=json.loads((root/'Content/course-scripts.en-GB.json').read_text())
        publisher.module('prepare', 'prepare-lesson-scripts.py').fill_speech(content['lessons'])
        sounds=json.loads((root/'Content/course-sounds.json').read_text())['sounds']
        current=json.loads((root/'Sources/CheckmateCore/Resources/course.json').read_text())
        manifest=json.loads((root/'Sources/CheckmateCore/Resources/course-narration.json').read_text())
        assets={a['id']:a for a in manifest['assets']}
        rebuilt=publisher.build_course(sounds,content,assets,self.timing,current['narration'])
        self.assertEqual(rebuilt,current)
        projections=json.loads((root/'Sources/CheckmateCore/Resources/projections.json').read_text())
        self.assertEqual(publisher.build_projections(content,rebuilt),projections)


class PracticeRelationTests(unittest.TestCase):
    """Practice lessons sit under their piece lesson; the relation is presentation metadata only."""
    def setUp(self):
        self.prep = publisher.module('prepare', 'prepare-lesson-scripts.py')
        self.content = json.loads((HERE.parent / 'Content/course-scripts.en-GB.json').read_text())

    def testPublishedPracticeLessonsNameTheirPieceLesson(self):
        pairs = {l['id']: l['practiceFor'] for l in self.content['lessons'] if 'practiceFor' in l}
        self.assertEqual(pairs, {'pawn-duel': 'pawn', 'rook-practice': 'rook', 'bishop-practice': 'bishop',
                                 'queen-practice': 'queen', 'knight-practice': 'knight'})
        self.prep.validate_practice(self.content['lessons'])
        runtime = json.loads((HERE.parent / 'Sources/CheckmateCore/Resources/course.json').read_text())
        self.assertEqual({l['id']: l['practiceFor'] for l in runtime['lessons'] if 'practiceFor' in l}, pairs)

    def testInvalidRelationsAreRejected(self):
        def lessons(*pairs):
            return [dict({'id': i}, **({'practiceFor': p} if p is not None else {})) for i, p in pairs]
        invalid = {
            'unknown parent': lessons(('pawn', None), ('pawn-duel', 'missing')),
            'itself': lessons(('pawn', None), ('pawn-duel', 'pawn-duel')),
            'a practice parent': lessons(('pawn', None), ('pawn-duel', 'pawn'), ('drill', 'pawn-duel')),
            'not a string': lessons(('pawn', None), ('pawn-duel', ['pawn'])),
            'not the nearest main lesson': lessons(('pawn', None), ('rook', None), ('pawn-duel', 'pawn')),
            'no lesson before it': lessons(('pawn-duel', 'pawn'), ('pawn', None)),
        }
        for name, case in invalid.items():
            with self.subTest(name), self.assertRaises(AssertionError):
                self.prep.validate_practice(case)
        self.prep.validate_practice(lessons(('pawn', None), ('pawn-duel', 'pawn'), ('pawn-drill', 'pawn'), ('rook', None)))



class NarrationClaimTests(unittest.TestCase):
    """Recorded narration must not name app controls or lessons that do not exist; card and title edits are reviewed."""
    def setUp(self):
        self.prep = publisher.module('prepare', 'prepare-lesson-scripts.py')

    def lessons(self, text):
        return [{'id': 'castling', 'title': 'Castling', 'teaches': [], 'beats': [{'id': 'castling:0', 'say': 'Hi.', 'speak': 'Hi.'}]},
                {'id': 'fork', 'title': 'The Fork', 'teaches': [], 'beats': [{'id': 'fork:0', 'say': text, 'speak': text}]}]

    def testControlsAndMissingLessonsAreRejected(self):
        for text in ['Choose the start button in the lesson panel.', 'Open the sidebar.',
                     "You've seen this in the Scholar's Mate lesson.", 'We cover it in the castling-rules lesson.']:
            with self.subTest(text), self.assertRaises(AssertionError):
                self.prep.validate_narration_claims(self.lessons(text))

    def testEquipmentGenericAndRealLessonReferencesPass(self):
        for text in ['After moving, press the clock button.', "We'll look at it in a later lesson.",
                     'You saw this in the Castling lesson.', 'The lesson is coordination.', 'Remember the Fork lesson.']:
            with self.subTest(text):
                self.prep.validate_narration_claims(self.lessons(text))

    def testShownTextComesFromTheEditorialSource(self):
        root = HERE.parent
        content = json.loads((root / 'Content/course-scripts.en-GB.json').read_text())
        runtime = json.loads((root / 'Sources/CheckmateCore/Resources/course.json').read_text())
        projections = json.loads((root / 'Sources/CheckmateCore/Resources/projections.json').read_text())
        for li, lesson in enumerate(content['lessons']):
            self.assertEqual(runtime['stepTitles'][li], [b['label'] for b in lesson['beats']])
            self.assertEqual([f['start']['big'] for f in runtime['frames'][li]], [b['big'] for b in lesson['beats']])
            self.assertEqual({p['title'] for p in projections[li]}, {lesson['title']}, 'The agent projection names the lesson as shown')
            topics = {p['topic'] for p in runtime['puzzles'] if p['id'].startswith('course:' + lesson['id'] + ':')}
            self.assertLessEqual(topics, {lesson['title']}, 'Quick puzzles name their lesson as shown')


class AuthoredMoveTests(unittest.TestCase):
    """Moves shown in a lesson are legal chess moves on the board shown."""
    def setUp(self):
        self.prep = publisher.module('prepare', 'prepare-lesson-scripts.py')

    def testNoMoveLeavesItsOwnKingAttacked(self):
        illegal = {
            'king steps into attack': ({'e1': 'wk', 'a2': 'br'}, [['e1', 'e2']], []),
            'pinned piece moves': ({'e1': 'wk', 'e2': 'wn', 'e8': 'br'}, [['e2', 'c3']], []),
            'check ignored': ({'e1': 'wk', 'e8': 'br', 'a2': 'wp'}, [['a2', 'a3']], []),
            'en passant opens the king': ({'a5': 'wk', 'b5': 'wp', 'c5': 'bp', 'h5': 'br'}, [['b5', 'c6']], ['c5']),
        }
        for name, (board, moves, remove) in illegal.items():
            with self.subTest(name), self.assertRaisesRegex(AssertionError, 'leaves its own king in check'):
                self.prep.validate_moves(name, board, {'moves': moves, 'remove': remove})
        self.prep.validate_moves('legal', {'e1': 'wk', 'a2': 'br', 'e8': 'bk'}, {'moves': [['e1', 'f1']]})
        self.prep.validate_moves('castles', {'e1': 'wk', 'h1': 'wr'}, {'moves': [['e1', 'g1'], ['h1', 'f1']]})


if __name__ == "__main__":
    unittest.main()
