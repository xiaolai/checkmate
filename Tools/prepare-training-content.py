#!/usr/bin/env python3
"""Validate the authored training sources in Content/training and publish them to the asset bundle.

Structure, references, counts, novelty clusters and coverage are checked here. Chess legality and every objective's
accepted answers are re-derived by the Swift evaluators in TrainingCatalogTests, which also check the validator
version and chess.js hash pinned in the manifest below.

  python3 Tools/prepare-training-content.py           publish Sources/CheckmateCore/Resources/training/
  python3 Tools/prepare-training-content.py --check   fail unless the published files match the sources exactly
"""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Content' / 'training'
PUBLISHED = ROOT / 'Sources' / 'CheckmateCore' / 'Resources' / 'training'
COURSE = ROOT / 'Sources' / 'CheckmateCore' / 'Resources' / 'course.json'
CHESS_JS = ROOT / 'Sources' / 'CheckmateCore' / 'Resources' / 'chess.js'
SEARCH_JS = ROOT / 'Sources' / 'CheckmateCore' / 'Resources' / 'training-search.js'
# Bumped whenever an evaluator's accepted answers can change; the Swift tests require the same number.
VALIDATOR_VERSION = 1
ID = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')
SQUARE = re.compile(r'^[a-h][1-8]$')
UCI = re.compile(r'^[a-h][1-8][a-h][1-8][qrbn]?$')
FEN = re.compile(r'^([pnbrqkPNBRQK1-8]{1,8}/){7}[pnbrqkPNBRQK1-8]{1,8} [wb] (-|K?Q?k?q?) (-|[a-h][36]) \d+ [1-9]\d*$')
OBJECTIVES = {
    'reachTarget': ('movementDrill', 'selectionCorrection', ['playMove']),
    'findAttackers': ('recognitionDiagram', 'notApplicable', ['selectSquares']),
    'findDefenders': ('recognitionDiagram', 'notApplicable', ['selectSquares']),
    'kingSafeSquares': ('standardChess', 'notApplicable', ['selectSquares']),
    'mateInOne': ('standardChess', 'selectionCorrection', ['playMove']),
    'escapeCheck': ('standardChess', 'ruleError', ['playMove']),
    'classifyStatus': ('standardChess', 'notApplicable', ['chooseOption']),
    'legacyGame': ('simplifiedVariant', 'selectionCorrection', ['playMove']),
    'saveYourPiece': ('standardChess', 'selectionCorrection', ['playMove']),
    'captureWisely': ('standardChess', 'selectionCorrection', ['playMove', 'chooseOption', 'selectSquares']),
    'specialMoves': ('standardChess', 'ruleError', ['playMove', 'chooseOption', 'selectSquares']),
    'simpleTactics': ('standardChess', 'selectionCorrection', ['playMove', 'chooseOption', 'selectSquares']),
    'finishTheGame': ('standardChess', 'selectionCorrection', ['playMove']),
    'mixedPractice': ('standardChess', 'selectionCorrection', ['playMove', 'chooseOption', 'selectSquares']),
    'guidedGame': ('standardChess', 'selectionCorrection', ['playMove']),
    'positionGame': ('standardChess', 'selectionCorrection', ['playMove']),
}
GENERATED = {'reachTarget', 'findAttackers', 'findDefenders'}
LEGACY = {'pawn-duel', 'rook-sweep', 'rooks-and-pawns', 'bishop-sweep', 'bishops-and-pawns', 'queen-vs-pawns', 'knight-capture', 'knight-corners'}
SKILLS = ['movement', 'attackProtection', 'threatResponse', 'captureExchange', 'checkMateDraw', 'specialRules', 'elementaryTactics', 'convertingWin', 'gameHabits', 'diagnosis']
CONTEXTS = ['guidedExample', 'focusedPractice', 'noHintPractice', 'mixedApplication']
# Every field TrainingScenario decodes: anything else would be ignored by the app and must not steer validation here.
SCENARIO_FIELDS = {'id', 'entry', 'variant', 'tier', 'cluster', 'learner', 'prompt', 'explanation', 'hints', 'fen', 'prelude', 'diagram', 'target',
                   'drill', 'budget', 'shortest', 'choices', 'expected', 'noAction', 'reserve', 'review', 'generation', 'check', 'goal', 'plies',
                   'nodes', 'stated', 'askColor', 'focus', 'skills', 'primarySkill', 'source', 'bridge', 'workflow', 'keep'}
# TrainingCheck and TrainingGoal.Kind raw values: anything else fails to decode in the app.
CHECKS = {'defense', 'material', 'exchange', 'castle', 'castleReason', 'promotion', 'enPassant', 'enPassantChoice', 'forks', 'pins',
          'mateThreatCreate', 'mateThreatPrevent', 'kingSquares', 'status', 'diagnosis', 'ending', 'guidedGame', 'moment', 'positionGame'}
# A position game's goals (mini-game plan D3) and the piece types it may keep: never the king.
POSITION_GOALS = {'checkmate', 'promoteAndHold'}
KEEPABLE = ('q', 'r', 'b', 'n', 'p')
GOAL_KINDS = {'survive', 'gain', 'hold'} | POSITION_GOALS
# The evaluators whose scenario is where a playable game starts: a position only, with no oracle answer.
GAME_CHECKS = ('ending', 'guidedGame', 'positionGame')


class ContentError(Exception):
    pass


def fail(message):
    raise ContentError(message)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n'


def is_text(value, limit=None):
    return isinstance(value, str) and bool(value.strip()) and (limit is None or len(value) <= limit)


def texts(value, limit=None):
    """A nonempty list of nonempty strings: a bare string would otherwise pass as a list of characters."""
    return isinstance(value, list) and bool(value) and all(is_text(item, limit) for item in value)


# Swift's Int on every platform the app ships for: a JSON integer outside it passes Python but fails to decode.
INT_RANGE = range(-2 ** 63, 2 ** 63)


def is_int(value):
    """The one integer check for every authored integer: a JSON integer (not a boolean, which Python counts as one)
    that a Swift Int decodes."""
    return isinstance(value, int) and not isinstance(value, bool) and value in INT_RANGE


def is_flag(value):
    return isinstance(value, bool)


def strings(value):
    """A list of strings, possibly empty: what a Swift [String] decodes."""
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def one_of(names):
    return lambda value: isinstance(value, str) and value in names


def string_map(value, is_value):
    return isinstance(value, dict) and all(isinstance(key, str) and is_value(item) for key, item in value.items())


def is_goal(goal):
    """TrainingGoal: a kind, an integer threshold, an optional target square and an optional draw flag."""
    return isinstance(goal, dict) and one_of(GOAL_KINDS)(goal.get('kind')) and is_int(goal.get('threshold')) \
        and (goal.get('target') is None or isinstance(goal['target'], str)) and (goal.get('drawOK') is None or is_flag(goal['drawOK']))


def is_node(node):
    """TrainingTeachingNode: a fingerprint, accepted moves, replies by move and an optional next index by move."""
    return isinstance(node, dict) and isinstance(node.get('fingerprint'), str) and strings(node.get('accepted')) \
        and string_map(node.get('replies'), lambda reply: isinstance(reply, str)) and (node.get('next') is None or string_map(node['next'], is_int))


# The Swift type of each optional TrainingScenario field not checked elsewhere, and of each TrainingExpected field: a
# value the app cannot decode stops publication here rather than the app. null decodes as absent.
DECODED = {
    'budget': is_int, 'shortest': is_flag, 'choices': strings, 'noAction': is_flag, 'reserve': is_flag,
    'check': one_of(CHECKS), 'goal': is_goal, 'plies': is_int, 'nodes': lambda nodes: isinstance(nodes, list) and all(map(is_node, nodes)),
    'stated': strings, 'askColor': lambda color: isinstance(color, str), 'focus': strings,
    'skills': lambda skills: isinstance(skills, list) and all(map(one_of(SKILLS), skills)), 'primarySkill': one_of(SKILLS), 'source': is_text,
    'bridge': one_of(LEGACY), 'workflow': lambda workflow: isinstance(workflow, str), 'keep': strings,
}
EXPECTED_DECODED = {'squares': strings, 'moves': strings, 'choices': strings, 'wrong': strings,
                    'choice': lambda choice: isinstance(choice, str), 'distance': is_int}


def read(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        fail(f'{path.name}: {error}')


def check_entry_contract(entry, seen, legacy):
    """An entry's identity and evaluation contract: its id, objective, rule mode, illegal-input policy, actions, mini-game,
    origin, increment and delivery. `seen` and `legacy` collect the ids and mini-games listed so far. Returns its id."""
    if not isinstance(entry, dict):
        fail(f'catalog: every entry is an object, found {entry!r}')
    name = entry.get('id', '?')
    if not isinstance(name, str) or not ID.fullmatch(name) or len(name) > 48 or name in seen:
        fail(f'catalog: invalid or duplicate entry id {name!r}')
    seen.add(name)
    objective = entry.get('objective')
    if not isinstance(objective, str) or objective not in OBJECTIVES:
        fail(f'{name}: unknown objective {objective!r}')
    mode, policy, actions = OBJECTIVES[objective]
    if (entry.get('ruleMode'), entry.get('illegalInput'), entry.get('actions')) != (mode, policy, actions):
        fail(f'{name}: rule mode, illegal-input policy and actions must be {mode}, {policy}, {actions}')
    if (objective == 'legacyGame') != ('legacyKind' in entry) or (objective == 'legacyGame' and (not isinstance(entry['legacyKind'], str) or entry['legacyKind'] not in LEGACY)):
        fail(f'{name}: a legacy entry names exactly one existing mini-game')
    if 'legacyKind' in entry:
        if entry['legacyKind'] in legacy:
            fail(f'{name}: mini-game listed twice')
        legacy.add(entry['legacyKind'])
    if entry.get('origin') != ('existing' if objective == 'legacyGame' else 'new'):
        fail(f'{name}: only legacy games are existing entries')
    if entry.get('increment') not in ('A', 'B') or entry.get('delivery') not in ('pilot', 'release'):
        fail(f'{name}: invalid increment or delivery')
    return name


def check_entry_presentation(name, entry):
    """What the learner reads about an entry: its title, summary, plain rules and the skills it lists."""
    if not is_text(entry.get('title')) or not is_text(entry.get('summary')):
        fail(f'{name}: a title and a summary are required')
    if not texts(entry.get('rules'), 400):
        fail(f'{name}: plain rules are required')
    if not texts(entry.get('skills')) or any(skill not in SKILLS for skill in entry['skills']) or len(set(entry['skills'])) != len(entry['skills']):
        fail(f'{name}: invalid skills')


def check_entry_references(name, entry, lessons):
    """What an entry names elsewhere or offers for selection: its variants, linked lessons and tiers."""
    if not isinstance(entry.get('variants'), list) or any(not isinstance(variant, str) or not ID.fullmatch(variant) for variant in entry['variants']):
        fail(f'{name}: invalid variant')
    if entry['objective'] != 'legacyGame' and not entry.get('variants'):
        fail(f'{name}: a new exercise lists its variants')
    if not isinstance(entry.get('lessonLinks'), list) or not all(isinstance(lesson, str) for lesson in entry['lessonLinks']):
        fail(f'{name}: lesson links are a list of lesson ids')
    missing = [lesson for lesson in entry['lessonLinks'] if lesson not in lessons]
    if missing:
        fail(f'{name}: unknown lesson links {missing}')
    if not is_int(entry.get('tiers')) or entry['tiers'] not in (1, 2, 3):
        fail(f'{name}: one to three tiers')


def check_catalog_counts(entries):
    """The aggregate shape of the catalog: Increment A is the eight existing games and seven new exercises."""
    counts = {}
    for entry in entries:
        counts[(entry['increment'], entry['origin'])] = counts.get((entry['increment'], entry['origin']), 0) + 1
    if counts.get(('A', 'existing')) != 8 or counts.get(('A', 'new')) != 7:
        fail(f'catalog: increment A must be eight existing and seven new entries, found {counts}')


def check_catalog(catalog, lessons):
    if not isinstance(catalog, dict):
        fail('catalog: the catalog is an object')
    # is_int: JSON true would otherwise equal 1 here, and the app decodes both versions as integers.
    if not is_int(catalog.get('schemaVersion')) or catalog['schemaVersion'] != 1 or not is_int(catalog.get('contentVersion')) or catalog['contentVersion'] < 1:
        fail('catalog: unsupported schema or content version')
    entries = catalog.get('entries')
    if not isinstance(entries, list) or not entries:
        fail('catalog: no entries')
    seen, legacy = set(), set()
    for entry in entries:
        name = check_entry_contract(entry, seen, legacy)
        check_entry_presentation(name, entry)
        check_entry_references(name, entry, lessons)
    check_catalog_counts(entries)
    return {entry['id']: entry for entry in entries}


def check_review(name, review):
    # The types TrainingReview decodes: a nonempty author, a reviewer that is null or nonempty, an integer version.
    if not isinstance(review, dict) or not is_text(review.get('author')) or 'reviewer' not in review \
            or (review['reviewer'] is not None and not is_text(review['reviewer'])):
        fail(f'{name}: review metadata needs author and reviewer (null until an editor reviews it)')
    if not is_int(review.get('validatorVersion')) or review['validatorVersion'] != VALIDATOR_VERSION:
        fail(f'{name}: validated with validator {review.get("validatorVersion")}, current is {VALIDATOR_VERSION}')


def context_moves(scenario):
    """The prelude as moves: absent, null and empty all mean the position is played from as written."""
    return scenario.get('prelude') or []


# Every TrainingScenario field that defines the question asked of a position, beside the position itself: the side
# the learner acts for, the evaluator and its goal and search horizon, the stated line, asked colour, target and
# options, and the diagram, drill and move budget of the other rule modes. Explanations, hints, focus squares, the
# teaching graph and the oracle answer describe or grade the question rather than define it.
EXERCISE_FIELDS = ('learner', 'check', 'goal', 'plies', 'stated', 'askColor', 'target', 'choices', 'diagram', 'drill', 'budget', 'shortest', 'keep')


def position_key(scenario):
    """Position identity, for novelty: the board with every rule state that changes its legal moves, after any context
    moves. The FEN's move counters are left out, so renumbering a position cannot make a repeat look new."""
    return canonical({'fen': ' '.join(scenario['fen'].split()[:4]), 'prelude': context_moves(scenario)})


def exercise_key(scenario):
    """Exercise identity, for rejecting duplicates: the position and every field that defines the question asked of it.
    Two exercises that differ in any of them (a longer search horizon, another stated line) ask different questions."""
    return canonical({'position': position_key(scenario), **{field: scenario.get(field) for field in EXERCISE_FIELDS}})


def symmetric_forms(fen):
    """The approved symmetry for clusters: a file mirror and a colour flip (ranks reversed, colours and the side to
    move swapped). Only for positions without castling rights or an en-passant square, whose meaning they keep; any
    other position is its own only form, with that rule state, since castling and en passant change its legal moves."""
    placement, turn, castling, passant = fen.split()[:4]
    rows = placement.split('/')
    if castling != '-' or passant != '-':
        return {' '.join((placement, turn, castling, passant))}
    expand = lambda rs: [''.join('1' * int(c) if c.isdigit() else c for c in r) for r in rs]
    flipped = [r.swapcase() for r in reversed(rows)]
    forms = set()
    for candidate, side in ((rows, turn), (flipped, 'b' if turn == 'w' else 'w')):
        for oriented in (expand(candidate), [r[::-1] for r in expand(candidate)]):
            forms.add('/'.join(oriented) + ' ' + side)
    return forms


def check_placement(name, scenario, entry):
    """Where a scenario sits in the catalog: only fields the app reads, its entry, variant, tier, learner and cluster."""
    unknown = sorted(set(scenario) - SCENARIO_FIELDS)
    if unknown:
        fail(f'{name}: fields the app does not read {unknown}')
    if scenario.get('entry') != entry['id'] or scenario.get('variant') not in entry['variants']:
        fail(f'{name}: entry or variant does not match the catalog')
    if not is_int(scenario.get('tier')) or scenario['tier'] not in range(1, entry['tiers'] + 1) or scenario.get('learner') not in ('w', 'b'):
        fail(f'{name}: invalid tier or learner colour')
    if not is_text(scenario.get('cluster')):
        fail(f'{name}: every scenario names its novelty cluster')


def check_position(name, scenario):
    """The board a scenario presents: a complete FEN, its context moves and any marked square."""
    if not isinstance(scenario.get('fen'), str) or not FEN.fullmatch(scenario['fen']):
        fail(f'{name}: standard-chess scenarios need a complete six-field FEN')
    prelude = scenario.get('prelude')
    if prelude is not None and (not isinstance(prelude, list) or any(not isinstance(move, str) or not UCI.fullmatch(move) for move in prelude)):
        fail(f'{name}: invalid prelude move')
    if scenario.get('target') is not None and (not isinstance(scenario['target'], str) or not SQUARE.fullmatch(scenario['target'])):
        fail(f'{name}: invalid target square')


def check_presentation(name, scenario):
    """What the learner reads: the prompt, the explanation and at least one concept hint."""
    if not is_text(scenario.get('prompt')) or not is_text(scenario.get('explanation')):
        fail(f'{name}: prompt and explanation are required')
    if not texts(scenario.get('hints')):
        fail(f'{name}: at least one concept hint is required')


def check_oracle(name, scenario):
    """The authored answer: present unless the scenario is a game start, with well-formed moves and squares. Returns
    `expected` as an object ({} when absent)."""
    # Increment B keeps its oracle in the teaching graph (`nodes`) or `expected`; a playable game start is a
    # position only. The Swift validators re-derive every one of them.
    # The authored value itself is checked: a falsy non-object such as [] would pass as {} yet fail to decode.
    if scenario.get('expected') is not None and not isinstance(scenario['expected'], dict):
        fail(f'{name}: expected is an object or null, found {scenario["expected"]!r}')
    expected = scenario.get('expected') or {}
    if scenario.get('check') in GAME_CHECKS:
        if expected or scenario.get('nodes'):
            fail(f'{name}: a game start is a position only')
    elif not (expected or scenario.get('nodes')):
        fail(f'{name}: the authored oracle answer is required')
    for field, pattern in (('moves', UCI), ('squares', SQUARE)):
        values = expected.get(field, [])
        if not isinstance(values, list) or any(not isinstance(value, str) or not pattern.fullmatch(value) for value in values):
            fail(f'{name}: invalid expected {field} {values!r}')
    return expected


def check_scenario(name, scenario, entry):
    """Structure of one scenario against its catalog entry, before any comparison with other scenarios."""
    check_placement(name, scenario, entry)
    check_position(name, scenario)
    check_presentation(name, scenario)
    check_decoded(name, scenario, check_oracle(name, scenario))
    check_position_game(name, scenario)
    check_review(name, scenario.get('review'))


def check_position_game(name, scenario):
    """A position game (mini-game plan D3): a checkmate or promoteAndHold goal with threshold 0 and nothing else, the piece
    types it keeps the learner's at the start, and a pawn race's one learner pawn. Only a position game uses either.
    Legality and who moves are re-derived by the Swift validators."""
    goal, keep = scenario.get('goal'), scenario.get('keep')
    if scenario.get('check') != 'positionGame':
        if isinstance(goal, dict) and goal.get('kind') in POSITION_GOALS:
            fail(f'{name}: a {goal["kind"]} goal belongs to a position game')
        if keep is not None:
            fail(f'{name}: only a position game keeps piece types')
        return
    if not isinstance(goal, dict) or goal.get('kind') not in POSITION_GOALS or goal.get('threshold') != 0 or isinstance(goal.get('threshold'), bool) \
            or goal.get('target') is not None or goal.get('drawOK') is not None or scenario.get('plies') is not None:
        fail(f'{name}: a position game\'s goal is checkmate or promoteAndHold, with threshold 0 and no target, draw rule or horizon')
    placement = scenario['fen'].split()[0]
    mine = [piece.lower() for piece in placement if piece.isalpha() and (piece.isupper() == (scenario['learner'] == 'w'))]
    if keep is not None and (not keep or len(set(keep)) != len(keep) or any(kept not in KEEPABLE or kept not in mine for kept in keep)):
        fail(f'{name}: a position game keeps piece types the learner has, each of {KEEPABLE} at most once')
    if goal['kind'] == 'promoteAndHold' and mine.count('p') != 1:
        fail(f'{name}: a pawn race starts with exactly one learner pawn')


def check_decoded(name, scenario, expected):
    """Every remaining field has the type the app decodes. A curated scenario is standard chess with a review, so it
    carries no diagram, drill or generation record."""
    present = sorted(field for field in ('diagram', 'drill', 'generation') if scenario.get(field) is not None)
    if present:
        fail(f'{name}: a curated scenario has no {present}')
    for fields, values, label in ((DECODED, scenario, ''), (EXPECTED_DECODED, expected, 'expected ')):
        for field, valid in fields.items():
            if values.get(field) is not None and not valid(values[field]):
                fail(f'{name}: invalid {label}{field} {values[field]!r}')


def scenario_document(path, entries):
    """One scenario file: its scenario list and the curated catalog entry they all belong to."""
    document = read(path)
    if not isinstance(document, dict) or not isinstance(document.get('scenarios', []), list):
        fail(f'{path.name}: a scenario file is an object with a list of scenarios')
    entry = entries.get(document.get('entry')) if isinstance(document.get('entry'), str) else None
    if not entry or entry['objective'] == 'legacyGame' or entry['objective'] in GENERATED:
        fail(f'{path.name}: scenarios belong to a curated entry, not {document.get("entry")!r}')
    return document.get('scenarios', []), entry


def register_novelty(name, scenario, exercises, clusters):
    """Rejects a repeated exercise, and a position (or its symmetric twin) filed under another novelty cluster."""
    # A mixed case may reuse another entry's published exercise, but only by naming it as its source; it keeps that
    # position's novelty cluster. A guided-game start is where a game begins, not a practice position: the initial
    # setup may also be an Increment A board. Any other repeat is a duplicate.
    exercise = exercise_key(scenario)
    key = (scenario['entry'], exercise) if scenario.get('source') or scenario.get('workflow') == 'guided-game' else exercise
    if key in exercises:
        fail(f'{name}: duplicates {exercises[key]} (same position and question)')
    exercises[key] = name
    # Different questions on one board are one novelty cluster within an entry. Without context moves the approved
    # symmetries count as the same board; with them the position after those moves is compared as it stands.
    form = (scenario['entry'], position_key(scenario) if context_moves(scenario) else min(symmetric_forms(scenario['fen'])))
    if form in clusters and clusters[form][0] != scenario['cluster']:
        fail(f'{name}: the same position as {clusters[form][1]} (up to symmetry) must share its cluster {clusters[form][0]!r}')
    clusters.setdefault(form, (scenario['cluster'], name))


def check_sources(scenarios):
    """A reused position names a published original that is not itself a reuse, with the same moves and cluster."""
    by_id = {s['id']: s for s in scenarios}
    for scenario in scenarios:
        if not scenario.get('source'):
            continue
        original = by_id.get(scenario['source'])
        if not original or original.get('source') or (original.get('fen'), context_moves(original)) != (scenario.get('fen'), context_moves(scenario)) or original['cluster'] != scenario['cluster']:
            fail(f"{scenario['id']}: its source {scenario['source']!r} must be a published position it repeats (same position and context moves), with the same cluster")


def check_scenarios(files, entries):
    scenarios, ids, exercises, clusters = [], set(), {}, {}
    for path in files:
        listed, entry = scenario_document(path, entries)
        for scenario in listed:
            if not isinstance(scenario, dict):
                fail(f'{path.name}: every scenario is an object, found {scenario!r}')
            name = scenario.get('id', '?')
            if not isinstance(name, str) or not ID.fullmatch(name) or name in ids:
                fail(f'{path.name}: invalid or duplicate scenario id {name!r}')
            ids.add(name)
            check_scenario(name, scenario, entry)
            register_novelty(name, scenario, exercises, clusters)
            scenarios.append(scenario)
    check_sources(scenarios)
    return sorted(scenarios, key=lambda s: (s['entry'], s['variant'], s['id']))


KINDS = ('lesson', 'generated', 'legacy', 'entry', 'mixedSkill', 'bridge', 'workflow')


def requirement_kind(requirement):
    """The single kind a requirement names, after checking the fields every kind needs."""
    if not isinstance(requirement, dict):
        fail(f'coverage: every requirement is an object, found {requirement!r}')
    kinds = [kind for kind in KINDS if kind in requirement]
    if len(kinds) != 1 or requirement.get('increment') not in ('A', 'B'):
        fail(f'coverage: a requirement names one kind of {KINDS} and increment A or B, found {requirement!r}')
    kind = kinds[0]
    if not isinstance(requirement[kind], str):
        fail(f'coverage: {kind} names an id, found {requirement!r}')
    if kind in ('entry', 'mixedSkill', 'workflow') and (not is_int(requirement.get('minimum')) or requirement['minimum'] < 1):
        fail(f'coverage: a {kind} requirement needs a positive minimum, found {requirement!r}')
    return kind


def entry_matches(requirement):
    """The scenarios an entry requirement counts: its variant, from its tier upwards, for its learner colour."""
    tier, learner = requirement.get('tier'), requirement.get('learner')
    if (tier is not None and (not is_int(tier) or tier not in (1, 2, 3))) or learner not in (None, 'w', 'b'):
        fail(f'coverage: invalid tier or learner in {requirement!r}')
    for key in ('clusters', 'noAction'):
        if key in requirement and (not is_int(requirement[key]) or requirement[key] < 0):
            fail(f'coverage: {key} must be a count in {requirement!r}')
    return lambda s: s['entry'] == requirement['entry'] and s['variant'] == requirement['variant'] and (tier is None or s['tier'] >= tier) and (learner is None or s['learner'] == learner)


def covers(requirement, entry):
    """A requirement names content of its own increment or earlier: later content cannot certify it."""
    if entry['increment'] > requirement['increment']:
        fail(f"coverage: {entry['id']} is increment {entry['increment']} content, so it cannot meet the increment {requirement['increment']} requirement {requirement!r}")


def evaluate(kind, requirement, entries, scenarios, lessons, mixed):
    """(needed, found) for one requirement. Scenarios and mixed cases count only from the requirement's increment or
    earlier; a requirement naming a later entry directly is an authoring error."""
    available = lambda s: entries[s['entry']]['increment'] <= requirement['increment']
    scenarios, mixed = list(filter(available, scenarios)), list(filter(available, mixed))
    if kind == 'lesson':
        if requirement['lesson'] not in lessons:
            fail(f'coverage: unknown lesson {requirement["lesson"]}')
        return 1, 1
    if kind == 'generated':
        entry = entries.get(requirement['generated'])
        if not entry or entry['objective'] not in GENERATED:
            fail(f'coverage: {requirement["generated"]} is not a generated entry')
        covers(requirement, entry)
        tiers = requirement.get('tiers')
        if not isinstance(tiers, list) or not tiers or not all(is_int(t) and t in (1, 2, 3) for t in tiers) or len(set(tiers)) != len(tiers):
            fail(f'coverage: {requirement["generated"]} needs a nonempty list of distinct tiers from 1 to 3, found {tiers!r}')
        return len(tiers), len([t for t in tiers if t <= entry['tiers']])
    if kind == 'legacy':
        games = [e for e in entries.values() if e.get('legacyKind') == requirement['legacy']]
        for game in games:
            covers(requirement, game)
        return 1, len(games)
    if kind == 'entry':
        entry = entries.get(requirement['entry'])
        if not entry or requirement.get('variant') not in entry['variants']:
            fail(f'coverage: unknown entry variant {requirement["entry"]}/{requirement.get("variant")}')
        covers(requirement, entry)
        matching = list(filter(entry_matches(requirement), scenarios))
        needed, found = requirement['minimum'], len(matching)
        if len({s['cluster'] for s in matching}) < requirement.get('clusters', 0) or sum(1 for s in matching if s.get('noAction')) < requirement.get('noAction', 0):
            found = min(found, needed - 1)
        return needed, found
    if kind == 'mixedSkill':
        return requirement['minimum'], sum(1 for s in mixed if requirement['mixedSkill'] in s.get('skills', []))
    if kind == 'bridge':
        return 1, int(any(s.get('bridge') == requirement['bridge'] for s in scenarios))
    return requirement['minimum'], sum(1 for s in scenarios if s.get('workflow') == requirement['workflow'])


def mixed_balanced(policy, mixed):
    """Whether the mixed pool is large enough, lists each policy skill in at least its minimum number of cases, and no
    primary skill exceeds its share of the cases actually published. A pool at its minimum size that is still too
    concentrated stops publication; a smaller or thinner pool is incomplete."""
    primary = {}
    for s in mixed:
        # The shape the app requires of a mixed case: its skills, with the primary skill among them.
        if not texts(s.get('skills')) or s.get('primarySkill') not in s['skills']:
            fail(f"{s['id']}: a mixed case lists its skills and primary skill")
        primary[s['primarySkill']] = primary.get(s['primarySkill'], 0) + 1
    concentrated = bool(mixed) and max(primary.values()) > policy['maximumPrimaryShare'] * len(mixed)
    if len(mixed) >= policy['minimumCases'] and concentrated:
        fail(f'coverage: one primary skill exceeds {policy["maximumPrimaryShare"]:.0%} of mixed cases')
    thin = [skill for skill in policy['skills'] if sum(1 for s in mixed if skill in s['skills']) < policy['minimumPerSkill']]
    return len(mixed) >= policy['minimumCases'] and not concentrated and not thin


def coverage_report(coverage, entries, scenarios, lessons):
    if not isinstance(coverage, dict) or not is_int(coverage.get('schemaVersion')) or coverage['schemaVersion'] != 1 or coverage.get('contexts') != CONTEXTS:
        fail('coverage: unsupported schema or contexts')
    rows = coverage.get('rows')
    # An empty context would be met by nothing at all: every skill names its evidence in every context.
    if not isinstance(rows, list) or not all(isinstance(row, dict) and all(isinstance(row.get(context), list) and row[context] for context in CONTEXTS) for row in rows):
        fail('coverage: every row is an object listing at least one requirement for each context')
    if sorted(str(row.get('skill')) for row in rows) != sorted(SKILLS):
        fail('coverage: every skill row appears exactly once')
    policy = coverage.get('mixedPolicy')
    if not isinstance(policy, dict) or not isinstance(policy.get('entry'), str) or policy['entry'] not in entries \
            or not is_int(policy.get('minimumCases')) or policy['minimumCases'] < 1 \
            or not is_int(policy.get('minimumPerSkill')) or policy['minimumPerSkill'] < 1 \
            or not texts(policy.get('skills')) or any(skill not in SKILLS for skill in policy['skills']) or len(set(policy['skills'])) != len(policy['skills']) \
            or isinstance(policy.get('maximumPrimaryShare'), bool) or not isinstance(policy.get('maximumPrimaryShare'), (int, float)) or not 0 < policy['maximumPrimaryShare'] <= 1:
        fail('coverage: the mixed policy names its entry, a positive minimum case count, its skills with a positive minimum each, and a primary-skill share')
    mixed = [s for s in scenarios if s['entry'] == policy['entry']]
    report = []
    for row in rows:
        for context in CONTEXTS:
            for requirement in row[context]:
                kind = requirement_kind(requirement)
                needed, found = evaluate(kind, requirement, entries, scenarios, lessons, mixed)
                report.append({'skill': row['skill'], 'context': context, 'increment': requirement['increment'], 'requirement': {k: v for k, v in requirement.items() if k != 'increment'}, 'needed': needed, 'found': found, 'met': found >= needed})
    balanced = mixed_balanced(policy, mixed)
    mixed_increment = entries[policy['entry']]['increment']
    # An increment with no requirement of its own has no coverage evidence, so it is not complete.
    complete = {inc: any(r['increment'] == inc for r in report) and all(r['met'] for r in report if r['increment'] <= inc)
                and (balanced or mixed_increment > inc) for inc in ('A', 'B')}
    return {'complete': complete, 'requirements': report, 'learnerEvidence': 'not observed'}


def build(source=SOURCE):
    lessons = {lesson['id'] for lesson in read(COURSE)['lessons']}
    catalog = read(source / 'catalog.json')
    entries = check_catalog(catalog, lessons)
    scenarios = check_scenarios(sorted((source / 'scenarios').glob('*.json')), entries)
    coverage = read(source / 'coverage.json')
    report = coverage_report(coverage, entries, scenarios, lessons)
    files = {'catalog.json': canonical(catalog), 'coverage.json': canonical(coverage), 'scenarios.json': canonical({'schemaVersion': 1, 'scenarios': scenarios})}
    counts, novelty = {}, {}
    for s in scenarios:
        counts.setdefault(s['entry'], {}).setdefault(s['variant'], 0)
        counts[s['entry']][s['variant']] += 1
        report_entry = novelty.setdefault(s['entry'], {'positions': 0, 'practiceClusters': set(), 'reserveClusters': set(), 'tiers': {}, 'colours': {}})
        report_entry['positions'] += 1
        report_entry['reserveClusters' if s.get('reserve') else 'practiceClusters'].add(s['cluster'])
        report_entry['tiers'][str(s['tier'])] = report_entry['tiers'].get(str(s['tier']), 0) + 1
        report_entry['colours'][s['learner']] = report_entry['colours'].get(s['learner'], 0) + 1
    for name, report_entry in novelty.items():
        if report_entry['practiceClusters'] & report_entry['reserveClusters']:
            fail(f'{name}: a reserved cluster also appears in the practice pool')
        report_entry['practiceClusters'] = len(report_entry['practiceClusters'])
        report_entry['reserveClusters'] = len(report_entry['reserveClusters'])
    manifest = {'schemaVersion': 1, 'contentVersion': catalog['contentVersion'], 'validatorVersion': VALIDATOR_VERSION,
                'chessJS': hashlib.sha256(CHESS_JS.read_bytes()).hexdigest(), 'trainingSearch': hashlib.sha256(SEARCH_JS.read_bytes()).hexdigest(),
                'files': {name: hashlib.sha256(text.encode()).hexdigest() for name, text in sorted(files.items())},
                'counts': counts, 'novelty': novelty, 'coverage': report}
    files['manifest.json'] = canonical(manifest)
    return files, report


def staging(published):
    """The sibling directory a publication writes and checks the next bundle in. A sibling shares the published
    directory's file system, which the atomic exchange in publish requires."""
    return published.with_name(f'.{published.name}.staged')


# <sys/stdio.h>: exchange two existing paths, or rename only onto a path that does not exist, in one step.
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004


def renamex_np(source, destination, flags):
    """macOS renamex_np(2): one atomic rename with `flags`. A failure raises with the system's reason; there is no
    multi-step substitute, since any sequence of plain renames has a moment without a published bundle."""
    try:
        call = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True).renamex_np
    except (OSError, AttributeError) as error:
        fail(f'atomic publication needs renamex_np from the macOS C library: {error}')
    call.argtypes, call.restype = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint), ctypes.c_int
    if call(os.fsencode(source), os.fsencode(destination), flags) != 0:
        code = ctypes.get_errno()
        fail(f'renamex_np({source}, {destination}, {flags:#x}) failed: [Errno {code}] {os.strerror(code)}')


def recover(published):
    """Settles an interrupted publication. The published directory only ever changes in one atomic exchange, so it
    always holds one whole bundle; the only leftover is the staged directory, holding either the next bundle (stopped
    before the exchange, partly written or not) or the previous one (stopped after it, partly removed or not). Either
    way it is not published and is discarded."""
    staged = staging(published)
    if staged.exists():
        shutil.rmtree(staged)
    sync(published.parent)


def sync(path):
    """Flushes a file's contents, or a directory's entries (its renames), to disk before the next step relies on them."""
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def outdated(files, published):
    """The names that keep `published` from being exactly `files`: missing, different, obsolete, or the staged
    directory an interrupted publication leaves behind."""
    stale = [name for name, text in files.items() if not (published / name).is_file() or (published / name).read_text(encoding='utf-8') != text]
    extra = [path.name for path in published.iterdir() if path.name not in files] if published.exists() else []
    leftovers = [staging(published).name] if staging(published).exists() else []
    return sorted(stale + extra + leftovers)


def publish(files, published):
    """Replaces the published bundle as a whole: the next bundle is written and verified in a staged sibling, then one
    renamex_np call exchanges it with the published directory (or, on a first publication, renames it into place only
    if nothing is there), and the staged path, now holding the previous bundle, is removed. The published path names a
    whole bundle at every moment; an interruption leaves only the staged directory, which recover() discards."""
    published.parent.mkdir(parents=True, exist_ok=True)
    recover(published)
    # The directory holds only generated files; anything else is not this tool's to discard with the old bundle.
    foreign = sorted(path.name for path in published.iterdir() if not path.is_file()) if published.exists() else []
    if foreign:
        fail(f'{published} holds {foreign}, which are not generated files; remove them by hand')
    staged = staging(published)
    staged.mkdir()
    for name, text in files.items():
        with open(staged / name, 'w', encoding='utf-8') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
    sync(staged)
    if outdated(files, staged):
        fail(f'the staged bundle in {staged} does not match the prepared files: {outdated(files, staged)}')
    renamex_np(staged, published, RENAME_SWAP if published.exists() else RENAME_EXCL)
    sync(published.parent)
    if staged.exists():
        shutil.rmtree(staged)


def main(argv):
    # Parsed before anything is built or written: a typo such as --checkk must not fall through to publication.
    parser = argparse.ArgumentParser(description='Validate the authored training sources and publish them to the asset bundle.')
    parser.add_argument('--check', action='store_true', help='fail unless the published files match the sources exactly')
    check = parser.parse_args(argv).check
    try:
        files, report = build()
    except ContentError as error:
        print(f'training content invalid: {error}', file=sys.stderr)
        return 1
    if check:
        outdated_names = outdated(files, PUBLISHED)
        if outdated_names:
            print(f'published training content is out of date: {outdated_names}; run Tools/prepare-training-content.py', file=sys.stderr)
            return 1
    else:
        try:
            publish(files, PUBLISHED)
        except ContentError as error:
            print(f'training content not published: {error}', file=sys.stderr)
            return 1
    unmet = [r for r in report['requirements'] if not r['met']]
    print(json.dumps({'complete': report['complete'], 'unmet': len(unmet)}))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
