"""Publication timing contracts; no API calls, encoding or playback."""
import copy
import importlib.util
import json
import re
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


class AssetSetIdentityTests(unittest.TestCase):
    def testARetakeOfUnchangedTextNamesANewAssetSet(self):
        take = {'requestSHA256': 'r' * 64, 'audioSHA256': 'a' * 64}
        retake = dict(take, audioSHA256='b' * 64)
        self.assertNotEqual(publisher.asset_set_identity([take], {}), publisher.asset_set_identity([retake], {}))


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



class PuzzleLinkTests(unittest.TestCase):
    """Every puzzle checks one lesson, named by its stable id; every lesson names its course section."""
    def setUp(self):
        self.prep = publisher.module('prepare', 'prepare-lesson-scripts.py')
        self.content = json.loads((HERE.parent / 'Content/course-scripts.en-GB.json').read_text())

    def testPublishedPuzzlesNameTheLessonTheyCheck(self):
        titles = {l['id']: l['title'] for l in self.content['lessons']}
        for puzzle in self.content['puzzles']:
            self.assertEqual(puzzle['topic'], titles[puzzle['lesson']], puzzle['id'])
        extras = {p['id']: p['lesson'] for p in self.content['puzzles'] if not p['id'].startswith('course:')}
        self.assertEqual(extras, {'extra-1': 'puzzles-material', 'extra-2': 'fork', 'extra-3': 'puzzles-mate', 'extra-4': 'counting-material'})
        self.prep.validate_links(self.content['lessons'], self.content['puzzles'])
        self.prep.validate_sections(self.content['lessons'])

    def testInvalidLinksAndSectionsAreRejected(self):
        lessons = [{'id': 'fork', 'title': 'The Fork', 'section': 'Tactics'}, {'id': 'pin', 'title': 'The Pin', 'section': 'Tactics'}]
        def puzzle(**fields):
            return dict({'id': 'extra-9', 'topic': 'The Fork', 'lesson': 'fork'}, **fields)
        for name, case in {'unknown lesson': puzzle(lesson='forks'), 'topic is not the title': puzzle(topic='Forks'),
                           'a course puzzle of another lesson': puzzle(id='course:pin:1')}.items():
            with self.subTest(name), self.assertRaises(AssertionError):
                self.prep.validate_links(lessons, [case])
        self.prep.validate_links(lessons, [puzzle(), puzzle(id='course:fork:1')])
        split = [dict(id='a', section='One'), dict(id='b', section='Two'), dict(id='c', section='One')]
        practice = [dict(id='rook', section='Pieces'), dict(id='rook-practice', practiceFor='rook', section='Rules')]
        for name, case in {'split section': split, 'practice outside its lesson': practice,
                           'no section': [dict(id='a')]}.items():
            with self.subTest(name), self.assertRaises(AssertionError):
                self.prep.validate_sections(case)


class ChoiceWhyTests(unittest.TestCase):
    """Every wrong choice of a choice puzzle carries its own authored line saying why it fails (L-7)."""
    def setUp(self):
        self.prep = publisher.module('prepare', 'prepare-lesson-scripts.py')
        self.content = json.loads((HERE.parent / 'Content/course-scripts.en-GB.json').read_text())

    def testEveryWrongChoiceSaysWhy(self):
        choices = [p for p in self.content['puzzles'] if p['exercise']['kind'] == 'choice']
        self.assertEqual(len(choices), 17)
        for puzzle in choices:
            exercise = puzzle['exercise']
            self.assertEqual(set(exercise['why']), set(exercise['choices']) - {exercise['answer']}, puzzle['id'])
            self.prep.validate_puzzle(puzzle)
        runtime = json.loads((HERE.parent / 'Sources/CheckmateCore/Resources/course.json').read_text())
        self.assertEqual(runtime['puzzles'], self.content['puzzles'], 'the app shows the authored lines')

    def testAMissingOrStrayLineIsRejected(self):
        base = next(p for p in self.content['puzzles'] if p['id'] == 'course:intro:1')
        def variant(why):
            puzzle = json.loads(json.dumps(base))
            puzzle['exercise']['why'] = why
            return puzzle
        cases = {'missing': {'Black': 'Black moves second.'}, 'for the answer': dict(base['exercise']['why'], White='No.'),
                 'empty': dict(base['exercise']['why'], Black=' '), 'no full stop': dict(base['exercise']['why'], Black='Black moves second')}
        for name, why in cases.items():
            with self.subTest(name), self.assertRaises(AssertionError):
                self.prep.validate_puzzle(variant(why))
        without = json.loads(json.dumps(base))
        del without['exercise']['why']
        with self.assertRaises(AssertionError):
            self.prep.validate_puzzle(without)


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


class LessonPracticeTests(unittest.TestCase):
    """Each broken practice exercise is rejected for its own reason; the published ones pass."""
    def setUp(self):
        self.prep = publisher.module('prepare', 'prepare-lesson-scripts.py')
        content = json.loads((HERE.parent / 'Content/course-scripts.en-GB.json').read_text())
        self.lessons = {lesson['id']: lesson for lesson in content['lessons']}

    def rejects(self, lesson_id, change, message):
        lesson = copy.deepcopy(self.lessons[lesson_id])
        change(lesson['practice'])
        with self.subTest(message), self.assertRaisesRegex(AssertionError, re.escape(message)):
            self.prep.validate_lesson(lesson)

    def fingerprint(self, fen, *moves):
        board, colour, castling, en_passant = self.prep.parse_fen(fen)
        position = (board, colour, castling, en_passant)
        for move in moves:
            position = self.prep.rules.advance(*position, self.prep.legal_ucis(position)[move])
        return self.prep.placement(position[0]) + ' ' + position[1]

    def testPublishedExercises(self):
        practice = {i for i, l in self.lessons.items() if 'practice' in l}
        self.assertEqual(practice, {'pawn', 'castling', 'castling-rules', 'promotion-en-passant', 'scholars-mate', 'fork', 'pin', 'skewer',
                                    'discovered-attack', 'removing-the-defender', 'two-rook-mate', 'queen-mate', 'rook-mate',
                                    'piece-values', 'puzzles-mate', 'famous-game'})
        for lesson_id in practice:
            self.assertIn('beat', self.lessons[lesson_id]['practice'], lesson_id)
            self.prep.validate_lesson(self.lessons[lesson_id])

    def testAnExerciseBeforeTheLastBeatComesBeforeItsAnswer(self):
        """A mid-lesson exercise sits on the still beat that asks for White's move; the next beat plays the answer, so
        the learner tries first and then sees it explained, and no new beat (or recording) is needed."""
        middle = set()
        for lesson_id, lesson in self.lessons.items():
            ids = [beat['id'] for beat in lesson['beats']]
            if 'practice' not in lesson or lesson['practice']['beat'] == ids[-1]:
                continue
            middle.add(lesson_id)
            index = ids.index(lesson['practice']['beat'])
            beat, after = lesson['beats'][index], lesson['beats'][index + 1]
            self.assertNotIn('moves', beat, lesson_id)
            self.assertNotIn('set', after, lesson_id)
            board, *_ = self.prep.parse_fen(lesson['practice']['fen'])
            self.assertEqual(board.get(after['moves'][0][0], '')[:1], 'w', f'{lesson_id}: the next beat shows White\'s answer')
        self.assertEqual(middle, {'piece-values', 'puzzles-mate', 'famous-game'})

    def testCastlingExerciseSaysHowToCastleInTheApp(self):
        """On the board the learner moves only the king, two squares; the app moves the rook. The goal, shown before
        the first move, says so (the lesson's narration describes castling on a real board)."""
        goal = self.lessons['castling']['practice']['goal']
        self.assertIn('move just your king two squares, from e1 to g1', goal)
        self.assertIn('the rook follows on its own', goal)

    def testFieldsBeatAndTexts(self):
        self.rejects('fork', lambda p: p.__setitem__('hint', 'x'), 'practice fields')
        self.rejects('fork', lambda p: p.pop('offTrack'), 'teaching and offTrack go together')
        self.rejects('queen-mate', lambda p: p.__setitem__('mistakes', {'d1d8': 'x'}), 'mistakes only with them')
        self.rejects('fork', lambda p: [p.pop(k) for k in list(p) if k not in ('fen', 'goal')], 'practice fields')
        self.rejects('fork', lambda p: p.__setitem__('beat', 'pin:13'), 'is not a beat of this lesson')
        self.rejects('fork', lambda p: p.__setitem__('beat', 'fork:13'), 'is not the practice position')
        self.rejects('fork', lambda p: p.__setitem__('hints', p['hints'][:1]), 'exactly two different hints')
        self.rejects('fork', lambda p: p.__setitem__('hints', [p['hints'][0]] * 2), 'exactly two different hints')
        self.rejects('fork', lambda p: p.__setitem__('success', 'x' * 221), 'more than 220')
        self.rejects('fork', lambda p: p.__setitem__('offTrack', ' padded'), 'without outer spaces')
        self.rejects('promotion-en-passant', lambda p: p.__setitem__('fen', p['fen'].replace(' d6 ', ' c6 ')), 'en passant on c6 needs')

    def testCheckpoints(self):
        def checkpoints(*items):
            return lambda p: p.__setitem__('checkpoints', list(items))
        mate = {'kind': 'mate', 'label': "Checkmate Black's king"}
        self.rejects('queen-mate', checkpoints({'kind': 'stalemate', 'label': 'x'}), 'checkpoint')
        self.rejects('queen-mate', checkpoints({'kind': 'mate', 'label': 'x' * 49}), 'more than 48')
        self.rejects('queen-mate', checkpoints(mate, mate), 'each kind appears once')
        self.rejects('queen-mate', checkpoints(mate, {'kind': 'graph', 'label': 'x'}), 'needs a teaching graph')
        self.rejects('queen-mate', checkpoints(mate, {'kind': 'mate', 'label': 'x', 'tactic': 'fork', 'gain': 1}), 'has a kind and a label')
        self.rejects('queen-mate', checkpoints(mate, {'kind': 'pawnAdvance', 'label': 'x'}), 'needs a white pawn')
        self.rejects('queen-mate', checkpoints(mate, {'kind': 'attackQueen', 'label': 'x'}), 'needs a black queen')
        self.rejects('queen-mate', lambda p: p.__setitem__('opponent', 'beginner'), 'mates are defended by defender')
        self.rejects('fork', lambda p: p.__setitem__('opponent', 'defender'), 'mates are defended by defender')
        def without_graph(p):
            for field in ('teaching', 'offTrack', 'mistakes'):
                p.pop(field, None)
        self.rejects('castling', lambda p: (without_graph(p), p.__setitem__('fen', p['fen'].replace(' KQ ', ' - '))), 'no castling right')
        # Checkpoints must be possible from the start, not merely named.
        self.rejects('castling-rules', lambda p: (without_graph(p), p.__setitem__('fen', p['fen'].replace(' KQ ', ' K '))), 'no legal castling exists at the start or in the graph')
        self.rejects('pawn', checkpoints({'kind': 'pawnAdvance', 'label': 'x'}, {'kind': 'enPassant', 'label': 'y'}), "the FEN needs its en-passant square")
        self.rejects('pawn', lambda p: (p.__setitem__('fen', p['fen'].replace(' - - ', ' - d6 ')), p.__setitem__('checkpoints', [{'kind': 'enPassant', 'label': 'x'}])), 'no legal en-passant capture at the start')
        self.rejects('castling', lambda p: p['checkpoints'].append({'kind': 'promote', 'label': 'x'}), 'every white pawn has a black pawn ahead of it')
        graph = lambda p: p['checkpoints'][0]
        self.rejects('fork', lambda p: graph(p).__setitem__('tactic', 'deflection'), 'a tactic names one of')
        for gain in (0, 2.5, True):
            self.rejects('fork', lambda p, gain=gain: graph(p).__setitem__('gain', gain), 'gain is whole material')
        self.rejects('fork', lambda p: graph(p).pop('gain'), 'a tactic names one of')

    def testTeachingGraphReplay(self):
        root = lambda p: p['teaching'][0]
        self.rejects('fork', lambda p: p['teaching'][1].__setitem__('fingerprint', root(p)['fingerprint']), 'fingerprint')
        self.rejects('castling-rules', lambda p: root(p).__setitem__('accepted', ['e1g1']), 'accepted move e1g1 is not legal')
        self.rejects('fork', lambda p: root(p)['replies'].__setitem__('g5e6', 'a8a1'), 'reply a8a1 to g5e6 is not legal')
        self.rejects('fork', lambda p: root(p).pop('next'), 'has a reply exactly when the graph continues')
        self.rejects('fork', lambda p: root(p)['next'].__setitem__('g5e6', 2), 'is not a node')
        self.rejects('fork', lambda p: root(p)['next'].__setitem__('g5e6', True), 'is not a node')
        self.rejects('fork', lambda p: p['teaching'].append(copy.deepcopy(p['teaching'][1])), 'never reached')
        self.rejects('fork', lambda p: p['teaching'][1].__setitem__('replies', {}), 'omit replies or next when empty')
        self.rejects('fork', lambda p: p['teaching'][1].update(replies={'e6f8': 'e7f8'}, next={'e6f8': 1}), 'loops back on itself')
        self.rejects('fork', lambda p: root(p)['replies'].__setitem__('g5g6', 'h7h6'), 'g5g6 is not legal, so it has no reply')
        self.rejects('fork', lambda p: p['mistakes'].__setitem__('e1-g1', 'x'), 'is not a UCI move')
        # Mistakes describe the start, so a mistake is a move node 0 does not accept.
        self.rejects('castling', lambda p: p['mistakes'].__setitem__('e1g1', 'x'), 'must be off track at node 0')
        # En passant comes only from the FEN's en-passant square.
        self.rejects('promotion-en-passant', lambda p: (p.__setitem__('fen', p['fen'].replace(' d6 ', ' - ')), p.__setitem__('checkpoints', p['checkpoints'][1:])), 'accepted move e5d6 is not legal')

        # Castling rights follow the moves: a rook that left h1 and came back no longer castles.
        def rook_went_away(p):
            fen = p['fen']
            p['teaching'] = [
                {'fingerprint': self.fingerprint(fen), 'accepted': ['h1g1'], 'replies': {'h1g1': 'a7a6'}, 'next': {'h1g1': 1}},
                {'fingerprint': self.fingerprint(fen, 'h1g1', 'a7a6'), 'accepted': ['g1h1'], 'replies': {'g1h1': 'a6a5'}, 'next': {'g1h1': 2}},
                {'fingerprint': self.fingerprint(fen, 'h1g1', 'a7a6', 'g1h1', 'a6a5'), 'accepted': ['e1g1']}]
        self.rejects('castling', rook_went_away, 'accepted move e1g1 is not legal')

    def testPromotionMovesNameTheirPiece(self):
        fen = '7k/P7/8/8/8/8/8/6K1 w - - 0 1'
        board = self.prep.parse_fen(fen)[0]
        lesson = {'id': 'promotion-drill', 'title': 'Promotion drill', 'teaches': ['Promote.'],
                  'beats': [{'id': 'promotion-drill:0', 'label': 'Your turn', 'big': '', 'say': 'Promote.', 'speak': 'Promote.', 'set': board}],
                  'practice': {'fen': fen, 'goal': 'Promote the pawn.', 'beat': 'promotion-drill:0',
                               'teaching': [{'fingerprint': self.fingerprint(fen), 'accepted': ['a7a8q', 'a7a8r']}],
                               'checkpoints': [{'kind': 'graph', 'label': 'Promote the pawn'}], 'opponent': 'beginner',
                               'hints': ['Walk the pawn to the last rank.', 'It is one step away.'], 'offTrack': 'Undo it and promote.',
                               'success': 'Promoted.'}}
        self.prep.validate_lesson(lesson)
        lesson['practice']['teaching'][0]['accepted'] = ['a7a8']
        with self.assertRaisesRegex(AssertionError, 'accepted move a7a8 is not legal'):
            self.prep.validate_lesson(lesson)


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


class GuardAndStageTests(unittest.TestCase):
    """Guard lines and sentence-timed stages: what is accepted, and when each appears."""
    def setUp(self):
        self.prep = publisher.module('prepare', 'prepare-lesson-scripts.py')

    def check(self, board, beat):
        start = dict(board)
        end = self.prep.validate_moves('beat', dict(board), beat)
        self.prep.validate_overlays('beat', beat, end, start)

    def testGuardsMustHoldOnTheBoardTheyDescribe(self):
        board = {'e6': 'wk', 'e7': 'wq', 'e8': 'bk', 'a1': 'wr', 'h1': 'br'}
        self.check(board, {'guards': [['e6', 'e7']]})
        self.check(board, {'guards': [['e7', 'd8']]})  # an empty square it covers
        rejected = {'an enemy piece is an attack': [['e7', 'e8']], 'out of reach': [['e6', 'e4']],
                    'no piece': [['d6', 'e7']], 'a line through a piece': [['a1', 'h1']]}
        for name, guards in rejected.items():
            with self.subTest(name), self.assertRaisesRegex(AssertionError, 'does not guard'):
                self.check(board, {'guards': guards})
        with self.assertRaisesRegex(AssertionError, 'drawn twice'):
            self.check(board, {'guards': [['e7', 'd8']], 'arrows': [['e7', 'd8']]})
        with self.assertRaisesRegex(AssertionError, 'drawn twice'):
            self.check(board, {'guards': [['e6', 'e7'], ['e6', 'e7']]})

    def testAnArrowOntoItsOwnPieceIsAGuard(self):
        board = {'c3': 'wp', 'd4': 'wp', 'd1': 'wr', 'd3': 'wb', 'd7': 'bq'}
        with self.assertRaisesRegex(AssertionError, 'draw it as a guard'):
            self.check(board, {'arrows': [['c3', 'd4']]})
        # A blocked line is drawn through the blocker to its target, not stopped on it.
        self.check(board, {'arrows': [['d1', 'd7']]})

    def testAnotherPieceThatCouldMakeTheMoveIsAPreview(self):
        board = {'e1': 'wk', 'b1': 'wn', 'f3': 'wn', 'e8': 'bk', 'b8': 'bn'}
        beat = {'moves': [['b1', 'd2']], 'arrows': [['b1', 'd2'], ['f3', 'd2']]}
        self.check(board, beat)
        self.assertEqual(self.prep.move_previews(board, beat), [['b1', 'd2'], ['f3', 'd2']])
        # Not of the mover's side, or not able to reach the square: no preview.
        self.assertEqual(self.prep.move_previews(board, {'moves': [['b8', 'd7']], 'arrows': [['f3', 'd2']]}), [['b8', 'd7']])
        self.assertEqual(self.prep.move_previews(board, {'moves': [['b1', 'c3']], 'arrows': [['f3', 'c3']]}), [['b1', 'c3']])

    def testAGuardAppearsOnlyOnceItShowsTheEndRelationForGood(self):
        def reveal(board, beat, guard):
            return self.prep.guard_reveal(self.prep.beat_boards(board, beat), guard)
        # The queen arrives on the square the king guards: from her landing, not while e7 is still empty.
        self.assertEqual(reveal({'e6': 'wk', 'h7': 'wq', 'e8': 'bk'}, {'moves': [['h7', 'e7']]}, ['e6', 'e7']), 1)
        # Untouched by the moves: from the start.
        self.assertEqual(reveal({'e6': 'wk', 'e7': 'wq', 'a2': 'wp'}, {'moves': [['a2', 'a3']]}, ['e6', 'e7']), 0)
        # The guard arrives with the first move and stays: from that landing (the d-pawn guarding e4).
        self.assertEqual(reveal({'d2': 'wp', 'e4': 'wp', 'b8': 'bn'}, {'moves': [['d2', 'd3'], ['b8', 'c6']]}, ['d3', 'e4']), 1)
        # Broken later in the beat (the guard moves away, its target is captured, or a piece blocks its line): never.
        broken = {
            'the guard relocates': ({'d3': 'wq', 'e4': 'wn', 'a7': 'bp'}, {'moves': [['a7', 'a6'], ['d3', 'd1']]}, ['d3', 'e4']),
            'the target is captured': ({'c3': 'wn', 'e4': 'wp', 'd5': 'bp'}, {'moves': [['d5', 'e4']]}, ['c3', 'e4']),
            'a blocker enters': ({'a1': 'wr', 'h1': 'wr', 'c3': 'bn'}, {'moves': [['c3', 'd1']]}, ['a1', 'h1']),
        }
        for name, (board, beat, guard) in broken.items():
            with self.subTest(name):
                self.assertIsNone(reveal(board, beat, guard))
                with self.assertRaisesRegex(AssertionError, 'does not guard'):
                    self.check(board, dict(beat, guards=[guard]))
        # A removal that opens the line: after the removal, not before.
        board, beat = {'a1': 'wr', 'h1': 'wr', 'd1': 'bn', 'a8': 'bk'}, {'remove': ['d1']}
        self.assertEqual(reveal(board, beat, ['a1', 'h1']), 1)

    def testStagesAreWellFormed(self):
        board = {'e8': 'bk', 'f7': 'bp', 'e1': 'wk', 'f2': 'wp'}
        f7, f2 = {'sq': 'f7', 'kind': 'focus'}, {'sq': 'f2', 'kind': 'focus'}
        good = [{'hl': [f7], 'guards': [['e8', 'f7']]}, {'hl': [f2], 'guards': [['e1', 'f2']]}]
        self.check(board, {'stages': good})
        self.assertEqual(self.prep.overlays({'stages': good}), {'hl': [f7, f2], 'arrows': [], 'guards': [['e8', 'f7'], ['e1', 'f2']]})
        rejected = {
            'one stage': ({'stages': good[:1]}, 'two or more'),
            'moves': ({'stages': good, 'moves': [['f2', 'f3']]}, 'no moves'),
            'removals': ({'stages': good, 'remove': ['f2']}, 'no moves'),
            'overlays beside the stages': ({'stages': good, 'hl': [f7]}, 'in its stages'),
            'an empty stage': ({'stages': [good[0], {}]}, 'a stage holds'),
            'an unknown field': ({'stages': [good[0], {'count': ['f2']}]}, 'a stage holds'),
            'the same item twice': ({'stages': [good[0], {'hl': [f7]}]}, 'two stages'),
            'two kinds on one square': ({'stages': [good[0], {'hl': [{'sq': 'f7', 'kind': 'no'}]}]}, 'two highlight kinds'),
        }
        for name, (beat, message) in rejected.items():
            with self.subTest(name), self.assertRaisesRegex(AssertionError, message):
                self.check(board, beat)

    def testStartFramesShowTheFirstStageAndRevealedGuards(self):
        prep = self.prep
        f7, f2 = {'sq': 'f7', 'kind': 'focus'}, {'sq': 'f2', 'kind': 'focus'}
        lesson = {'beats': [
            {'big': '', 'set': {'e8': 'bk', 'f7': 'bp', 'e1': 'wk', 'f2': 'wp'},
             'stages': [{'hl': [f7], 'guards': [['e8', 'f7']]}, {'hl': [f2], 'guards': [['e1', 'f2']]}]},
            {'big': '', 'set': {'e6': 'wk', 'h7': 'wq', 'e8': 'bk', 'a2': 'wp'}, 'moves': [['h7', 'e7']],
             'guards': [['e6', 'e7']]}]}
        frames = prep.lesson_frames(lesson)
        publisher.stage_overlays(frames, lesson['beats'])
        self.assertEqual((frames[0]['start']['hl'], frames[0]['start']['guards']), ([f7], [['e8', 'f7']]))
        self.assertEqual((frames[0]['end']['hl'], frames[0]['end']['guards']), ([f7, f2], [['e8', 'f7'], ['e1', 'f2']]))
        self.assertEqual((frames[1]['start']['guards'], frames[1]['end']['guards']), ([], [['e6', 'e7']]))

    def testCuesAreBoundToTheirAnchorPhrases(self):
        root = HERE.parent
        content = json.loads((root / 'Content/course-scripts.en-GB.json').read_text())
        self.prep.fill_speech(content['lessons'])
        sounds = json.loads((root / 'Content/course-sounds.json').read_text())['sounds']
        timing = json.loads((root / 'Content/narration-packaging.json').read_text())['timing']
        manifest = json.loads((root / 'Sources/CheckmateCore/Resources/course-narration.json').read_text())
        assets = {a['id']: a for a in manifest['assets']}
        phrases, cues = publisher.authored_cues()
        original = publisher.authored_cues
        cases = {
            'an anchor changed, narration unchanged': (dict(phrases, **{'scholars-mate:1': ['Black pawn']}), cues, 'Stale action cue anchors'),
            'a cue without phrases': ({k: v for k, v in phrases.items() if k != 'scholars-mate:1'}, cues, 'Anchor phrases and aligned cues differ'),
            'a staged beat without its cue': ({k: v for k, v in phrases.items() if k != 'scholars-mate:1'},
                                              {k: v for k, v in cues.items() if k != 'scholars-mate:1'}, 'A staged beat needs aligned anchor'),
            'stage cues at the very start': (phrases, dict(cues, **{'scholars-mate:1': dict(cues['scholars-mate:1'], fractions=[0])}), 'Invalid stage cue timing'),
            'a boolean cue': (phrases, dict(cues, **{'scholars-mate:1': dict(cues['scholars-mate:1'], fractions=[True])}), 'Invalid action cue timing'),
        }
        try:
            for name, (p, c, message) in cases.items():
                def authored(p=p, c=c):
                    assert set(p) == set(c), 'Anchor phrases and aligned cues differ'
                    return p, c
                publisher.authored_cues = authored
                with self.subTest(name), self.assertRaisesRegex(AssertionError, message):
                    publisher.build_course(sounds, copy.deepcopy(content), assets, timing, {'voice': 'cedar'})
        finally:
            publisher.authored_cues = original


if __name__ == "__main__":
    unittest.main()
