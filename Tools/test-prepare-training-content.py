#!/usr/bin/env python3
"""Negative fixtures: each invalid training source must stop publication for its own reason. Positive fixtures and
interrupted-publication states pin what must keep working."""
import copy
import ctypes
import errno
import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('prepare_training_content', HERE / 'prepare-training-content.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

SCENARIO = {
    'id': 'mate-fixture-1', 'entry': 'mate-in-one', 'variant': 'mate', 'tier': 1, 'learner': 'w', 'cluster': 'fixture-a',
    'fen': '6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1', 'prompt': 'White to move. Find checkmate.', 'explanation': 'The rook mates on the back rank.',
    'hints': ['Look at the back rank.'], 'expected': {'moves': ['a1a8']},
    'review': {'author': 'fixture', 'reviewer': None, 'validatorVersion': tool.VALIDATOR_VERSION},
}
# A searched Increment B exercise: a goal reached within a horizon of `plies`, graded through its teaching graph.
SEARCHED = {
    'id': 'cw-fixture-1', 'entry': 'capture-wisely', 'variant': 'free-piece', 'tier': 1, 'learner': 'w', 'cluster': 'cw-fixture-a',
    'fen': '8/K7/3P4/2r4R/8/8/1k6/8 w - - 0 1', 'prompt': 'White to move. Win material.', 'explanation': 'Rxc5 takes a piece nobody defends.',
    'hints': ['Look for an enemy piece that nothing protects.'], 'check': 'material', 'goal': {'kind': 'gain', 'threshold': 1}, 'plies': 3,
    'nodes': [{'fingerprint': '8/K7/3P4/2r4R/8/8/1k6/8 w - -', 'accepted': ['h5c5'], 'replies': {'h5c5': 'b2a1'}}],
    'review': {'author': 'fixture', 'reviewer': None, 'validatorVersion': tool.VALIDATOR_VERSION},
}


def isolated(temporary):
    """The real catalog and coverage with no published scenarios: only a fixture's own scenarios are present, so a
    fixture never collides with real content and a failure can only come from its mutation."""
    source = pathlib.Path(temporary) / 'training'
    shutil.copytree(tool.SOURCE, source)
    for path in (source / 'scenarios').glob('*.json'):
        path.unlink()
    (source / 'position-game-evidence.json').write_text(json.dumps(NO_EVIDENCE))
    return source


# The position-game evidence of an isolated source: no scenario of the real content is published there.
NO_EVIDENCE = {'schemaVersion': 1, 'engine': 'fixture-engine', 'mates': {}}


def build_fixture(mutate, scenario=SCENARIO, mates=None):
    """Builds the isolated sources after one mutation of the catalog, the coverage and the fixture's scenario list, with
    `mates` as the position-game evidence's engine mates."""
    with tempfile.TemporaryDirectory(prefix='checkmate-training-content-') as temporary:
        source = isolated(temporary)
        if mates is not None:
            (source / 'position-game-evidence.json').write_text(json.dumps(dict(NO_EVIDENCE, mates=mates)))
        catalog = json.loads((source / 'catalog.json').read_text())
        coverage = json.loads((source / 'coverage.json').read_text())
        scenarios = [copy.deepcopy(scenario)]
        mutate(catalog, coverage, scenarios)
        (source / 'catalog.json').write_text(json.dumps(catalog))
        (source / 'coverage.json').write_text(json.dumps(coverage))
        (source / 'scenarios' / 'fixture.json').write_text(json.dumps({'entry': scenarios[0].get('entry', scenario['entry']), 'scenarios': scenarios}))
        return tool.build(source)


def expect_failure(label, reason, mutate):
    """The mutation stops publication, and for `reason`: a fixture that failed for another reason would leave the
    defect it names unguarded."""
    try:
        build_fixture(mutate)
    except tool.ContentError as error:
        assert reason in str(error), f'{label}: failed for another reason: {error}'
        return
    raise AssertionError(f'invalid fixture was published: {label}')


def accepted():
    """The unmutated fixture publishes: every negative fixture below differs from it by one mutation."""
    files, report = build_fixture(lambda c, v, s: None)
    manifest = json.loads(files['manifest.json'])
    assert manifest['counts']['mate-in-one']['mate'] >= 1 and manifest['validatorVersion'] == tool.VALIDATOR_VERSION and len(manifest['chessJS']) == 64
    assert report['complete'] == {'A': False, 'B': False}, 'one scenario cannot complete coverage'


def accepted_variations():
    """Valid content the checks must not reject: Swift Int's own bounds, and two exercises on one board that differ only
    in their search horizon (they ask different questions, so they are not duplicates)."""
    for bound in (tool.INT_RANGE.start, tool.INT_RANGE.stop - 1):
        build_fixture(lambda c, v, s: s[0]['expected'].update(distance=bound))
    files, _ = build_fixture(lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='cw-fixture-2', plies=5)), SEARCHED)
    assert json.loads(files['manifest.json'])['counts']['capture-wisely']['free-piece'] == 2, 'both horizons must publish'


def complete_and_withdrawn():
    """The real sources complete Increment A; withdrawing one curated entry's content loses that coverage."""
    files, report = tool.build(tool.SOURCE)
    assert report['complete']['A'] is True, 'the published sources must complete Increment A coverage'
    novelty = json.loads(files['manifest.json'])['novelty']
    for name in ('mate-in-one', 'king-safe-squares', 'escape-check', 'check-mate-stalemate'):
        assert novelty[name]['reserveClusters'] >= 10 and novelty[name]['positions'] >= 30 and set(novelty[name]['colours']) == {'w', 'b'}, name
    with tempfile.TemporaryDirectory(prefix='checkmate-training-content-') as temporary:
        source = pathlib.Path(temporary) / 'training'
        shutil.copytree(tool.SOURCE, source)
        (source / 'scenarios' / 'escape-check.json').unlink()
        _, report = tool.build(source)
        assert report['complete']['A'] is False, 'withdrawing Escape Check content kept Increment A complete'
        assert any(not row['met'] and 'escape-check' in json.dumps(row['requirement']) for row in report['requirements']), 'the lost requirement is not reported'


# Position games (mini-game plan D3) in the catalog's own entries: a pawn race (an exact promoteAndHold success by the
# KPK oracle, White's king outside the black king's reach of the a-pawn) and a two-bishop mate with its engine mate.
POSITION = {
    'id': 'race-fixture-1', 'entry': 'pawn-race', 'variant': 'kpk', 'tier': 1, 'learner': 'w', 'cluster': 'race-fixture-a',
    'fen': '8/8/8/8/P7/8/6k1/K7 w - - 0 1', 'prompt': 'Promote the pawn and keep the new piece.', 'explanation': 'The pawn runs.',
    'hints': ['Count the moves to the last rank.'], 'check': 'positionGame', 'goal': {'kind': 'promoteAndHold', 'threshold': 0},
    'review': {'author': 'fixture', 'reviewer': None, 'validatorVersion': tool.VALIDATOR_VERSION},
}
BISHOPS = dict(POSITION, id='bishops-fixture-1', entry='two-bishop-mate', variant='kbbk', cluster='bishops-fixture-a', fen='4k3/8/8/8/8/8/8/2B1KB2 w - - 0 1',
               goal={'kind': 'checkmate', 'threshold': 0}, keep=['b'])
MATE = {'line': [], 'nodes': 2000000, 'mate': 18}


def with_position_entry(mutate):
    """The mutation, on the catalog that already has the position-game entries."""
    return mutate


def position_games():
    """The objective publishes, with both goals and `keep`, its reachable goal recorded in the manifest; each malformed
    position game stops publication for its own reason, and neither its goals nor `keep` may be borrowed by another
    evaluator. Returns the negative fixtures run."""
    files, _ = build_fixture(lambda c, v, s: None, POSITION)
    manifest = json.loads(files['manifest.json'])
    assert manifest['counts']['pawn-race'] == {'kpk': 1}, 'a pawn race publishes'
    oracle = manifest['positionGames']['race-fixture-1']['oracle']
    assert oracle['promoteAndHold'] == 'success' and oracle['fen'] == POSITION['fen'] and oracle['generator']['tool'] == 'kpk-oracle' and len(oracle['generator']['sourceHash']) == 64, oracle
    files, _ = build_fixture(lambda c, v, s: None, BISHOPS, mates={'bishops-fixture-1': MATE})
    manifest = json.loads(files['manifest.json'])
    assert manifest['counts']['two-bishop-mate'] == {'kbbk': 1}, 'a two-bishop mate publishes'
    assert manifest['positionGames']['bishops-fixture-1'] == dict(MATE, goal='checkmate', engine='fixture-engine'), manifest['positionGames']
    evidence = {
        'a drawn pawn race': ('exact promoteAndHold success', POSITION, None, lambda c, v, s: s[0].update(fen='8/8/8/4k3/8/4K3/4P3/8 w - - 0 1')),
        'a pawn race the oracle cannot read': ('the KPK oracle cannot judge this start', POSITION, None, lambda c, v, s: s[0].update(fen='4k3/8/8/8/8/8/4P3/4K3 w - - 3 1')),
        'a mate without evidence': ('names its engine mate', BISHOPS, {}, lambda c, v, s: None),
        'evidence for an unpublished game': ('not published checkmate position games', BISHOPS, {'bishops-fixture-1': MATE, 'tb-nowhere': MATE}, lambda c, v, s: None),
        'evidence for a pawn race': ('not published checkmate position games', POSITION, {'race-fixture-1': MATE}, lambda c, v, s: None),
        'too few nodes': ('1000 to 5000000 nodes', BISHOPS, {'bishops-fixture-1': dict(MATE, nodes=10)}, lambda c, v, s: None),
        'a mate for the defender': ('a mate in 1 to 100 moves', BISHOPS, {'bishops-fixture-1': dict(MATE, mate=-3)}, lambda c, v, s: None),
        'an evidence line that is not UCI': ('at most 400 moves in UCI', BISHOPS, {'bishops-fixture-1': dict(MATE, line=['Bd3'])}, lambda c, v, s: None),
        'an evidence field too many': ('a line, a node count and a mate distance', BISHOPS, {'bishops-fixture-1': dict(MATE, score=1)}, lambda c, v, s: None),
        'a position game removed': ('the position games', POSITION, None, lambda c, v, s: c['entries'].remove(entry(c, 'pawn-war'))),
        'a position game variant added': ('the position games', POSITION, None, lambda c, v, s: entry(c, 'cut-down-chess')['variants'].append('kings')),
    }
    for label, (reason, base, mates, mutate) in evidence.items():
        try:
            build_fixture(mutate, base, mates)
        except tool.ContentError as error:
            assert reason in str(error), f'{label}: failed for another reason: {error}'
            continue
        raise AssertionError(f'unproved position game was published: {label}')
    cases = {
        'no goal': ("goal is checkmate or promoteAndHold", lambda c, v, s: s[0].pop('goal')),
        'a threshold': ("goal is checkmate or promoteAndHold", lambda c, v, s: s[0]['goal'].update(threshold=1)),
        'a boolean threshold': ("invalid goal", lambda c, v, s: s[0]['goal'].update(threshold=False)),
        'a horizon': ("goal is checkmate or promoteAndHold", lambda c, v, s: s[0].update(plies=3)),
        'a search goal': ("goal is checkmate or promoteAndHold", lambda c, v, s: s[0].update(goal={'kind': 'gain', 'threshold': 1})),
        'an unknown goal': ("invalid goal", lambda c, v, s: s[0].update(goal={'kind': 'holdDraw', 'threshold': 0})),
        'two learner pawns': ('exactly one learner pawn', lambda c, v, s: s[0].update(fen='4k3/8/8/8/8/8/3PP3/4K3 w - - 0 1')),
        'no learner pawn': ('exactly one learner pawn', lambda c, v, s: s[0].update(fen='4k3/8/8/8/8/8/4p3/4K3 w - - 0 1')),
        'keeping what the learner lacks': ('keeps piece types the learner has', lambda c, v, s: s[0].update(keep=['q'])),
        'keeping the king': ('keeps piece types the learner has', lambda c, v, s: s[0].update(keep=['k'])),
        'keeping a type twice': ('keeps piece types the learner has', lambda c, v, s: s[0].update(keep=['p', 'p'])),
        'keeping nothing': ('keeps piece types the learner has', lambda c, v, s: s[0].update(keep=[])),
        'keep that is not a list': ("invalid keep 'p'", lambda c, v, s: s[0].update(keep='p')),
        'an oracle answer': ('a game start is a position only', lambda c, v, s: s[0].update(expected={'moves': ['e2e4']})),
    }
    for label, (reason, mutate) in cases.items():
        try:
            build_fixture(with_position_entry(mutate), POSITION)
        except tool.ContentError as error:
            assert reason in str(error), f'{label}: failed for another reason: {error}'
            continue
        raise AssertionError(f'invalid position game was published: {label}')
    borrowed = {
        'keep on another evaluator': ('only a position game keeps piece types', SCENARIO, lambda c, v, s: s[0].update(keep=['r'])),
        "a position game's goal on a search": ('goal belongs to a position game', SEARCHED, lambda c, v, s: s[0].update(goal={'kind': 'checkmate', 'threshold': 0})),
    }
    for label, (reason, base, mutate) in borrowed.items():
        try:
            build_fixture(mutate, base)
        except tool.ContentError as error:
            assert reason in str(error), f'{label}: failed for another reason: {error}'
            continue
        raise AssertionError(f'a borrowed position-game field was published: {label}')
    return len(cases) + len(borrowed) + len(evidence)


class Interrupted(Exception):
    """Stands in for a process stopped part way through publication."""


def bundle(directory):
    """A directory's files by name, or None when it does not exist."""
    return {path.name: path.read_text(encoding='utf-8') for path in directory.iterdir()} if directory.exists() else None


def publication():
    """The published path names one whole bundle at every moment: each leftover an interruption can produce is
    recovered without touching it, --check reports a leftover until then, the exchange's failure leaves it untouched,
    and a later run publishes exactly the new files."""
    old = {'catalog.json': 'old catalog\n', 'manifest.json': 'old manifest\n', 'obsolete.json': 'old only\n'}
    new = {'catalog.json': 'new catalog\n', 'manifest.json': 'new manifest\n'}

    def write(directory, files):
        directory.mkdir()
        for name, text in files.items():
            (directory / name).write_text(text, encoding='utf-8')

    # Each leftover state: what is on disk after the interruption. Only the staged directory is ever left over, holding
    # the next bundle (stopped before the exchange) or the previous one (stopped after it); published is never touched.
    states = {
        'staged partly written': ({'published': old, 'staged': {'catalog.json': 'new cat'}}, old),
        'staged complete, nothing exchanged': ({'published': old, 'staged': new}, old),
        'first publication, staged only': ({'staged': new}, None),
        'exchanged, previous bundle not yet removed': ({'published': new, 'staged': old}, new),
        'exchanged, previous bundle partly removed': ({'published': new, 'staged': {'manifest.json': 'old manifest\n'}}, new),
    }
    for label, (layout, recovered) in states.items():
        with tempfile.TemporaryDirectory(prefix='checkmate-training-publish-') as temporary:
            published = pathlib.Path(temporary) / 'training'
            staged = tool.staging(published)
            for role, files in layout.items():
                write({'published': published, 'staged': staged}[role], files)
            assert tool.outdated(new, published), f'{label}: --check passed over an interrupted publication'
            tool.recover(published)
            assert bundle(published) == recovered and not staged.exists(), f'{label}: recovered to {bundle(published)}'
            tool.publish(new, published)
            assert bundle(published) == new and tool.outdated(new, published) == [], f'{label}: the next run did not publish exactly the new bundle'

    exchange, remove = tool.renamex_np, tool.shutil.rmtree

    def observed(published, expected_before):
        """Wraps the exchange and every removal so each sees the published bundle whole: `expected_before` until the
        exchange returns, the new bundle afterwards. Returns the calls made to the exchange."""
        calls, state = [], {'expected': expected_before}

        def checked(where):
            assert bundle(published) == state['expected'], f'{where}: the published bundle was {bundle(published)}'

        def exchanging(source, destination, flags):
            checked('before the exchange')
            calls.append(flags)
            exchange(source, destination, flags)
            state['expected'] = new
            checked('after the exchange')

        def removing(path, *arguments, **keywords):
            checked(f'removing {path}')
            remove(path, *arguments, **keywords)
            checked(f'after removing {path}')

        tool.renamex_np, tool.shutil.rmtree = exchanging, removing
        return calls

    # A real publication over an existing bundle exchanges once, and a first publication renames exclusively; the
    # published path holds a whole bundle before, between and after every step that changes the disk.
    for previous, flags in ((old, tool.RENAME_SWAP), (None, tool.RENAME_EXCL)):
        with tempfile.TemporaryDirectory(prefix='checkmate-training-publish-') as temporary:
            published = pathlib.Path(temporary) / 'training'
            if previous:
                write(published, previous)
            try:
                calls = observed(published, previous)
                tool.publish(new, published)
            finally:
                tool.renamex_np, tool.shutil.rmtree = exchange, remove
            assert calls == [flags], f'expected one renamex_np call with {flags:#x}, made {calls}'
            assert bundle(published) == new and not tool.staging(published).exists()

    # The exchange fails as the system call reports it (here a forced EIO, then a real one: an existing destination for
    # an exclusive rename): publication stops loudly and the published bundle is untouched and whole.
    def failing(source, destination, flags):
        ctypes.set_errno(errno.EIO)
        return -1

    with tempfile.TemporaryDirectory(prefix='checkmate-training-publish-') as temporary:
        published = pathlib.Path(temporary) / 'training'
        write(published, old)
        library = tool.ctypes.CDLL
        tool.ctypes.CDLL = lambda *arguments, **keywords: type('Libc', (), {'renamex_np': staticmethod(ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint, use_errno=True)(failing))})()
        try:
            tool.publish(new, published)
            raise AssertionError('a failed exchange was reported as a publication')
        except tool.ContentError as error:
            assert f'[Errno {errno.EIO}]' in str(error), error
        finally:
            tool.ctypes.CDLL = library
        assert bundle(published) == old, f'a failed exchange changed the published bundle: {bundle(published)}'
        staged = tool.staging(published)
        assert bundle(staged) == new and tool.outdated(new, published), 'a failed exchange must leave only the staged bundle, which --check reports'
        try:
            tool.renamex_np(staged, published, tool.RENAME_EXCL)
            raise AssertionError('an exclusive rename replaced an existing bundle')
        except tool.ContentError as error:
            assert f'[Errno {errno.EEXIST}]' in str(error), error
        assert bundle(published) == old and bundle(staged) == new
        tool.publish(new, published)
        assert bundle(published) == new and not staged.exists(), 'the run after a failed exchange did not publish'

    # Stopped after the exchange, before the previous bundle is removed: the new bundle is already published whole.
    with tempfile.TemporaryDirectory(prefix='checkmate-training-publish-') as temporary:
        published = pathlib.Path(temporary) / 'training'
        write(published, old)

        def interrupted(path, *arguments, **keywords):
            if path == tool.staging(published) and bundle(published) == new:
                raise Interrupted
            remove(path, *arguments, **keywords)

        tool.shutil.rmtree = interrupted
        try:
            tool.publish(new, published)
            raise AssertionError('publication was not interrupted after the exchange')
        except Interrupted:
            pass
        finally:
            tool.shutil.rmtree = remove
        assert bundle(published) == new and bundle(tool.staging(published)) == old, 'the exchange did not swap the two bundles'
        tool.recover(published)
        assert bundle(published) == new and not tool.staging(published).exists()

    # A directory the tool did not write stops publication before anything changes.
    with tempfile.TemporaryDirectory(prefix='checkmate-training-publish-') as temporary:
        published = pathlib.Path(temporary) / 'training'
        write(published, old)
        (published / 'notes').mkdir()
        try:
            tool.publish(new, published)
            raise AssertionError('a foreign directory was discarded with the old bundle')
        except tool.ContentError as error:
            assert 'not generated files' in str(error), error
        assert (published / 'notes').is_dir() and (published / 'catalog.json').read_text() == old['catalog.json']
        assert not tool.staging(published).exists(), 'a refused publication left a staged directory'


def entry(catalog, name):
    return next(e for e in catalog['entries'] if e['id'] == name)


def main():
    accepted()
    accepted_variations()
    complete_and_withdrawn()
    cases = {
        'mirrored twin in another cluster': ('must share its cluster', lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', fen='1k6/ppp5/8/8/8/8/8/1K5R w - - 0 1', cluster='fixture-b'))),
        'colour-flipped twin in another cluster': ('must share its cluster', lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', fen='r5k1/8/8/8/8/8/5PPP/6K1 b - - 0 1', learner='b', cluster='fixture-b'))),
        'another question on one board in another cluster': ('must share its cluster', lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', target='a8', cluster='fixture-b'))),
        'same position after context moves in another cluster': ('must share its cluster', lambda c, v, s: (s[0].update(prelude=['a1a2']), s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', target='a8', cluster='fixture-b')))),
        'reserved cluster in the practice pool': ('a reserved cluster also appears in the practice pool', lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', fen='7k/6pp/8/8/8/8/8/R5K1 w - - 0 1', reserve=True))),
        'five-field FEN': ('complete six-field FEN', lambda c, v, s: s[0].update(fen='6k1/5ppp/8/8/8/8/8/R5K1 w - - 0')),
        'bad FEN piece': ('complete six-field FEN', lambda c, v, s: s[0].update(fen='6x1/5ppp/8/8/8/8/8/R5K1 w - - 0 1')),
        'duplicate scenario id': ("duplicate scenario id 'mate-fixture-1'", lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), fen='7k/5ppp/8/8/8/8/8/R5K1 w - - 0 1'))),
        'duplicate position and question': ('duplicates mate-fixture-1', lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2'))),
        'duplicate with renumbered move counters': ('duplicates mate-fixture-1', lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', fen='6k1/5ppp/8/8/8/8/8/R5K1 w - - 7 30'))),
        'unknown variant': ('entry or variant does not match the catalog', lambda c, v, s: s[0].update(variant='smothered')),
        'tier beyond entry tiers': ('invalid tier or learner colour', lambda c, v, s: s[0].update(tier=4)),
        'missing cluster': ('names its novelty cluster', lambda c, v, s: s[0].pop('cluster')),
        'missing oracle answer': ('the authored oracle answer is required', lambda c, v, s: s[0].pop('expected')),
        'bad oracle move': ("invalid expected moves ['a1a9']", lambda c, v, s: s[0].update(expected={'moves': ['a1a9']})),
        'missing review': ('review metadata needs author and reviewer', lambda c, v, s: s[0].pop('review')),
        'stale validator': (f'validated with validator {tool.VALIDATOR_VERSION + 1}', lambda c, v, s: s[0]['review'].update(validatorVersion=tool.VALIDATOR_VERSION + 1)),
        'no hints': ('at least one concept hint is required', lambda c, v, s: s[0].update(hints=[])),
        'scenario for a generated entry': ("scenarios belong to a curated entry, not 'find-attackers'", lambda c, v, s: s[0].update(entry='find-attackers')),
        'rule mode mismatch': ('mate-in-one: rule mode, illegal-input policy and actions must be', lambda c, v, s: entry(c, 'mate-in-one').update(ruleMode='movementDrill')),
        'illegal-input policy mismatch': ('escape-check: rule mode, illegal-input policy and actions must be', lambda c, v, s: entry(c, 'escape-check').update(illegalInput='selectionCorrection')),
        'legacy without a game': ('pawn-duel: a legacy entry names exactly one existing mini-game', lambda c, v, s: entry(c, 'pawn-duel').pop('legacyKind')),
        'game listed twice': ('rook-sweep: mini-game listed twice', lambda c, v, s: entry(c, 'rook-sweep').update(legacyKind='pawn-duel')),
        'unknown lesson link': ("unknown lesson links ['no-such-lesson']", lambda c, v, s: entry(c, 'mate-in-one')['lessonLinks'].append('no-such-lesson')),
        'empty rules': ('mate-in-one: plain rules are required', lambda c, v, s: entry(c, 'mate-in-one').update(rules=[])),
        'A count changed': ('increment A must be eight existing and seven new entries', lambda c, v, s: c['entries'].remove(entry(c, 'knight-corners'))),
        'coverage row missing': ('every skill row appears exactly once', lambda c, v, s: v['rows'].pop()),
        'coverage unknown variant': ('unknown entry variant save-your-piece/teleport', lambda c, v, s: v['rows'][2]['focusedPractice'].append({'increment': 'B', 'entry': 'save-your-piece', 'variant': 'teleport', 'minimum': 1})),
        'coverage unknown lesson': ('unknown lesson missing', lambda c, v, s: v['rows'][0]['guidedExample'].append({'increment': 'A', 'lesson': 'missing'})),
        'A requirement naming a B entry': ('capture-wisely is increment B content, so it cannot meet the increment A requirement', lambda c, v, s: v['rows'][0]['focusedPractice'].append({'increment': 'A', 'entry': 'capture-wisely', 'variant': 'free-piece', 'minimum': 1})),
        'empty coverage context': ('at least one requirement for each context', lambda c, v, s: v['rows'][0].update(guidedExample=[])),
        'null and empty prelude twins': ('duplicates mate-fixture-1', lambda c, v, s: (s[0].update(prelude=None), s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', prelude=[], cluster='fixture-b')))),
        'expected that is not an object': ('expected is an object or null, found []', lambda c, v, s: s[0].update(expected=[])),
        'review author not a string': ('review metadata needs author and reviewer', lambda c, v, s: s[0]['review'].update(author=123)),
        'boolean validator version': ('validated with validator True', lambda c, v, s: s[0]['review'].update(validatorVersion=True)),
        'boolean catalog schema version': ('unsupported schema or content version', lambda c, v, s: c.update(schemaVersion=True)),
        'scenario id ending in a newline': ('invalid or duplicate scenario id', lambda c, v, s: s[0].update(id='mate-fixture\n')),
        # Values Python would accept but the app's decoder rejects.
        'reserve as a string': ("invalid reserve 'false'", lambda c, v, s: s[0].update(reserve='false')),
        'noAction as an integer': ('invalid noAction 1', lambda c, v, s: s[0].update(noAction=1)),
        'nodes as a string': ("invalid nodes 'invalid'", lambda c, v, s: s[0].update(nodes='invalid')),
        'expected choice as a list': ('invalid expected choice []', lambda c, v, s: s[0]['expected'].update(choice=[])),
        'diagram on a curated scenario': ("a curated scenario has no ['diagram']", lambda c, v, s: s[0].update(diagram={'a1': 'wr'})),
        'integer beyond Swift Int': (f'invalid expected distance {2 ** 63}', lambda c, v, s: s[0]['expected'].update(distance=2 ** 63)),
        'integer below Swift Int': (f'invalid expected distance {-2 ** 63 - 1}', lambda c, v, s: s[0]['expected'].update(distance=-2 ** 63 - 1)),
        'content version beyond Swift Int': ('unsupported schema or content version', lambda c, v, s: c.update(contentVersion=2 ** 63)),
    }
    for label, (reason, mutate) in cases.items():
        expect_failure(label, reason, mutate)
    positional = position_games()
    publication()
    print(json.dumps({'passed': True, 'negativeFixtures': len(cases) + positional}))


if __name__ == '__main__':
    sys.exit(main())
