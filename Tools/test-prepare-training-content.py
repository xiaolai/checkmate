#!/usr/bin/env python3
"""Negative fixtures: each invalid training source must stop publication with a reason."""
import copy
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


def isolated(temporary):
    """The real catalog and coverage with no published scenarios: only a fixture's own scenarios are present, so a
    fixture never collides with real content and a failure can only come from its mutation."""
    source = pathlib.Path(temporary) / 'training'
    shutil.copytree(tool.SOURCE, source)
    for path in (source / 'scenarios').glob('*.json'):
        path.unlink()
    return source


def expect_failure(label, mutate):
    with tempfile.TemporaryDirectory(prefix='checkmate-training-content-') as temporary:
        source = isolated(temporary)
        catalog = json.loads((source / 'catalog.json').read_text())
        coverage = json.loads((source / 'coverage.json').read_text())
        scenarios = [copy.deepcopy(SCENARIO)]
        mutate(catalog, coverage, scenarios)
        (source / 'catalog.json').write_text(json.dumps(catalog))
        (source / 'coverage.json').write_text(json.dumps(coverage))
        (source / 'scenarios' / 'fixture.json').write_text(json.dumps({'entry': scenarios[0].get('entry', 'mate-in-one'), 'scenarios': scenarios}))
        try:
            tool.build(source)
        except tool.ContentError:
            return
        raise AssertionError(f'invalid fixture was published: {label}')


def accepted():
    """The unmutated fixture publishes: every negative fixture below differs from it by one mutation."""
    with tempfile.TemporaryDirectory(prefix='checkmate-training-content-') as temporary:
        source = isolated(temporary)
        (source / 'scenarios' / 'fixture.json').write_text(json.dumps({'entry': 'mate-in-one', 'scenarios': [SCENARIO]}))
        files, report = tool.build(source)
        manifest = json.loads(files['manifest.json'])
        assert manifest['counts']['mate-in-one']['mate'] >= 1 and manifest['validatorVersion'] == tool.VALIDATOR_VERSION and len(manifest['chessJS']) == 64
        assert report['complete'] == {'A': False, 'B': False}, 'one scenario cannot complete coverage'


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


def entry(catalog, name):
    return next(e for e in catalog['entries'] if e['id'] == name)


def main():
    accepted()
    complete_and_withdrawn()
    cases = {
        'mirrored twin in another cluster': lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', fen='1k6/ppp5/8/8/8/8/8/1K5R w - - 0 1', cluster='fixture-b')),
        'colour-flipped twin in another cluster': lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', fen='r5k1/8/8/8/8/8/5PPP/6K1 b - - 0 1', learner='b', cluster='fixture-b')),
        'reserved cluster in the practice pool': lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', fen='7k/6pp/8/8/8/8/8/R5K1 w - - 0 1', reserve=True)),
        'five-field FEN': lambda c, v, s: s[0].update(fen='6k1/5ppp/8/8/8/8/8/R5K1 w - - 0'),
        'bad FEN piece': lambda c, v, s: s[0].update(fen='6x1/5ppp/8/8/8/8/8/R5K1 w - - 0 1'),
        'duplicate scenario id': lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), fen='7k/5ppp/8/8/8/8/8/R5K1 w - - 0 1')),
        'duplicate position and rule state': lambda c, v, s: s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2')),
        'unknown variant': lambda c, v, s: s[0].update(variant='smothered'),
        'tier beyond entry tiers': lambda c, v, s: s[0].update(tier=4),
        'missing cluster': lambda c, v, s: s[0].pop('cluster'),
        'missing oracle answer': lambda c, v, s: s[0].pop('expected'),
        'bad oracle move': lambda c, v, s: s[0].update(expected={'moves': ['a1a9']}),
        'missing review': lambda c, v, s: s[0].pop('review'),
        'stale validator': lambda c, v, s: s[0]['review'].update(validatorVersion=tool.VALIDATOR_VERSION + 1),
        'no hints': lambda c, v, s: s[0].update(hints=[]),
        'scenario for a generated entry': lambda c, v, s: s[0].update(entry='find-attackers'),
        'rule mode mismatch': lambda c, v, s: entry(c, 'mate-in-one').update(ruleMode='movementDrill'),
        'illegal-input policy mismatch': lambda c, v, s: entry(c, 'escape-check').update(illegalInput='selectionCorrection'),
        'legacy without a game': lambda c, v, s: entry(c, 'pawn-duel').pop('legacyKind'),
        'game listed twice': lambda c, v, s: entry(c, 'rook-sweep').update(legacyKind='pawn-duel'),
        'unknown lesson link': lambda c, v, s: entry(c, 'mate-in-one')['lessonLinks'].append('no-such-lesson'),
        'empty rules': lambda c, v, s: entry(c, 'mate-in-one').update(rules=[]),
        'A count changed': lambda c, v, s: c['entries'].remove(entry(c, 'knight-corners')),
        'coverage row missing': lambda c, v, s: v['rows'].pop(),
        'coverage unknown variant': lambda c, v, s: v['rows'][2]['focusedPractice'].append({'increment': 'B', 'entry': 'save-your-piece', 'variant': 'teleport', 'minimum': 1}),
        'coverage unknown lesson': lambda c, v, s: v['rows'][0]['guidedExample'].append({'increment': 'A', 'lesson': 'missing'}),
        'null and empty prelude twins': lambda c, v, s: (s[0].update(prelude=None), s.append(dict(copy.deepcopy(s[0]), id='mate-fixture-2', prelude=[], cluster='fixture-b'))),
        'expected that is not an object': lambda c, v, s: s[0].update(expected=[]),
        'review author not a string': lambda c, v, s: s[0]['review'].update(author=123),
        'boolean validator version': lambda c, v, s: s[0]['review'].update(validatorVersion=True),
        'boolean catalog schema version': lambda c, v, s: c.update(schemaVersion=True),
        'scenario id ending in a newline': lambda c, v, s: s[0].update(id='mate-fixture\n'),
    }
    for label, mutate in cases.items():
        expect_failure(label, mutate)
    print(json.dumps({'passed': True, 'negativeFixtures': len(cases)}))


if __name__ == '__main__':
    sys.exit(main())
