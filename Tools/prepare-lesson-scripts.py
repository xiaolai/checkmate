#!/usr/bin/env python3
"""Validate the lesson course and export plain-text, engine-neutral TTS inputs.

The course source is self-contained: every beat states its board (or carries the previous one), its moves and its
overlays, and every puzzle states a claim its answers are computed from. Checks are mechanical: authored moves follow
the rules of chess, check marks sit on attacked kings, arrows follow a piece's lines, and puzzle answers are exactly
the moves or squares that satisfy their claim. This never edits runtime resources, audio or saved learner progress.

A lesson's `practice` is the exercise on its invitation beat (`validate_practice_exercise`): exact fields, a beat whose
board is the FEN, checkpoint kinds and labels, two hints, bounded texts, and a teaching graph replayed with castling
rights, en passant and promotion. Checkpoints count in ANY order: the app judges each on the replayed game, and the
teaching graph, when there is one, comes first by construction. So each kind appears once and no label or text may
depend on the order, and every checkpoint must be possible from the start. `mistakes`, `offTrack` and both hints
describe the starting position only: the app shows them before the first move, and after any move it uses a generic
off-track text and a shown move instead. The independent audit (Tools/audit-lesson-rules.py) checks the chess behind
each exercise.

  --check           validate and require current exports, writing nothing
  --draft FILE...   validate draft lessons ({"lessons": [...], "puzzles": [...]}) on their own
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / 'Content/course-scripts.en-GB.json'


def _module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Tools' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rules = _module('lesson_rules')
provenance = _module('provenance')

LESSON_ID = re.compile(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$')
BEAT_KEYS = {'id', 'label', 'big', 'say', 'speak', 'set', 'moves', 'remove', 'hl', 'arrows', 'count', 'pause', 'miniGame'}
HIGHLIGHTS = {'focus', 'go', 'no', 'check'}
LEVELS = {'Foundation', 'Developing'}
VALUES = {'p': 1, 'n': 3, 'b': 3, 'r': 5, 'q': 9, 'k': 100}


def sha(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def speech_text(text):
    return re.sub(r'\b([a-h])([1-8])\b', lambda m: m.group(1).upper() + ' ' + 'one two three four five six seven eight'.split()[int(m.group(2)) - 1], text)


def fill_speech(lessons):
    """A beat without `speak` is recorded as its `say` with squares spoken (e4 becomes "E four")."""
    for lesson in lessons:
        for beat in lesson['beats']:
            if 'say' in beat and 'speak' not in beat:
                beat['speak'] = speech_text(beat['say'])
    return lessons


def lesson_frames(lesson):
    """Each beat's starting and ending view. A beat without `set` continues from the previous beat's end."""
    frames, board = [], None
    for beat in lesson['beats']:
        if 'set' in beat:
            board = copy.deepcopy(beat['set'])
        start = {'board': copy.deepcopy(board), 'hl': beat.get('hl', []), 'arrows': beat.get('arrows', []),
                 'big': beat['big'], 'counts': beat.get('count', [])[:1]}
        end = copy.deepcopy(start)
        end['counts'] = beat.get('count', [])
        for move in beat.get('moves', []):
            piece = end['board'].pop(move[0])
            end['board'][move[1]] = move[2] if len(move) > 2 else piece
        for square in beat.get('remove', []):
            del end['board'][square]
        frames.append({'start': start, 'end': end})
        board = end['board']
    return frames


def validate_moves(where, board, beat):
    """Authored moves follow the rules. Lesson boards may be partial, so this checks movement, not whose turn it is."""
    moves, remove = beat.get('moves', []), beat.get('remove', [])
    assert not (moves or remove) or board is not None, f'{where}: moves need a board'
    board = dict(board) if board is not None else None
    partner = None
    for move in moves:
        passed = None
        assert isinstance(move, list) and len(move) in (2, 3), f'{where}: a move is [from, to] or [from, to, piece]'
        origin, target = move[0], move[1]
        assert origin in board, f'{where}: no piece on {origin} to move'
        piece = board[origin]
        assert target not in board or board[target][0] != piece[0], f'{where}: {origin}-{target} lands on its own piece'
        if partner is not None:
            assert move[:2] == partner, f'{where}: castling moves the rook next ({partner[0]}-{partner[1]})'
            partner = None
        elif piece[1] == 'k' and origin[1] == target[1] and abs(rules.xy(origin)[0] - rules.xy(target)[0]) == 2:
            rank = origin[1]
            assert origin == 'e' + rank and rank == ('1' if piece[0] == 'w' else '8'), f'{where}: castling starts on the home square'
            rook, rook_to, between, path = ('h', 'f', 'fg', 'fg') if target[0] == 'g' else ('a', 'd', 'bcd', 'dc')
            assert board.get(rook + rank) == piece[0] + 'r', f'{where}: castling needs the rook on {rook}{rank}'
            assert all(f + rank not in board for f in between), f'{where}: castling needs an empty path'
            enemy = rules.other(piece[0])
            assert not any(rules.attacked(board, f + rank, enemy) for f in 'e' + path), f'{where}: castling is refused when the king is attacked on e, or on a square it crosses or lands on'
            partner = [rook + rank, rook_to + rank]
        elif piece[1] == 'p' and target not in board and origin[0] != target[0]:
            captured = passed = target[0] + origin[1]
            assert board.get(captured) == rules.other(piece[0]) + 'p' and captured in remove and origin[1] == ('5' if piece[0] == 'w' else '4'), \
                f'{where}: a pawn moves diagonally only to capture (en passant removes the passed pawn)'
        else:
            assert target in rules.destinations(board, origin), f'{where}: {piece} cannot move {origin}-{target}'
        last = '8' if piece[0] == 'w' else '1'
        if piece[1] == 'p' and target[1] == last:
            assert len(move) == 3 and move[2] in {piece[0] + p for p in 'qrbn'}, f'{where}: a pawn reaching {target} promotes'
        else:
            assert len(move) == 2, f'{where}: only a pawn reaching the last rank names a new piece'
        board[target] = move[2] if len(move) > 2 else piece
        del board[origin]
        # No move leaves its own king attacked: not a king stepping into attack, a pinned piece or an ignored check.
        assert not rules.in_check({s: p for s, p in board.items() if s != passed}, piece[0]), f'{where}: {origin}-{target} leaves its own king in check'
    assert partner is None, f'{where}: castling moves the rook in the same beat'
    for square in remove:
        assert square in board, f'{where}: nothing to remove on {square}'
        del board[square]
    if board is not None:
        rules.valid_board(board)
    return board


def validate_overlays(where, beat, end):
    """Check marks sit on attacked kings; arrows follow a piece's lines on the board they describe."""
    board = end or {}
    for mark in beat.get('hl', []):
        assert isinstance(mark, dict) and set(mark) == {'sq', 'kind'} and mark['kind'] in HIGHLIGHTS, f'{where}: highlight {mark}'
        rules.xy(mark['sq'])
        if mark['kind'] == 'check':
            king = board.get(mark['sq'], '')
            assert king[1:] == 'k' and rules.attacked(board, mark['sq'], rules.other(king[0])), f'{where}: check mark on {mark["sq"]} is not an attacked king'
    previews = [m[:2] for m in beat.get('moves', [])]
    arrows = beat.get('arrows', [])
    for arrow in arrows:
        assert isinstance(arrow, list) and len(arrow) == 2 and arrow[0] != arrow[1], f'{where}: arrow {arrow}'
        origin, target = arrow
        rules.xy(origin)
        rules.xy(target)
        if arrow in previews:
            continue
        if origin not in board:
            # A route: the arrow continues from where another arrow of this beat ends.
            assert any(a[1] == origin for a in arrows if a != arrow), f'{where}: arrow {origin}-{target} starts on an empty square'
            continue
        piece = board[origin]
        if target in rules.attacks(board, origin) or target in rules.destinations(board, origin):
            continue
        # A sliding piece's arrow may cross pieces to show a pin, skewer or blocked line; it ends on a piece.
        x0, y0 = rules.xy(origin)
        x1, y1 = rules.xy(target)
        straight = x0 == x1 or y0 == y1
        diagonal = abs(x1 - x0) == abs(y1 - y0)
        allowed = piece[1] == 'q' and (straight or diagonal) or piece[1] == 'r' and straight or piece[1] == 'b' and diagonal
        assert allowed and target in board, f'{where}: arrow {origin}-{target} does not follow the {piece} on {origin}'
    for square in beat.get('count', []):
        rules.xy(square)


def claim_moves(board, exercise):
    """Every legal move for the side to move that satisfies the exercise's claim, as (from, to) pairs."""
    claim = exercise['claim']
    colour = claim.get('side', 'w')
    enemy = rules.other(colour)
    assert not rules.in_check(board, enemy), 'The side not to move cannot be in check'
    if claim['type'] == 'escape-check':
        assert rules.in_check(board, colour), 'An escape-check puzzle starts in check'
    result = set()
    for move in rules.legal_moves(board, colour, claim.get('enPassant'), claim.get('castling', '')):
        after = rules.play(board, move, claim.get('enPassant'))
        captured = board.get(move[1])
        kind = claim['type']
        if kind == 'mate':
            ok = rules.checkmated(after, enemy)
        elif kind == 'stalemate':
            ok = rules.stalemated(after, enemy)
        elif kind == 'check':
            ok = rules.in_check(after, enemy)
        elif kind == 'safe-capture':
            ok = captured is not None and not rules.attacked(after, move[1], enemy)
        elif kind == 'castle':
            ok = board[move[0]][1] == 'k' and abs(rules.xy(move[0])[0] - rules.xy(move[1])[0]) == 2
        elif kind == 'promote':
            ok = len(move) == 3
        elif kind == 'fork':
            targets = [s for s in rules.attacks(after, move[1]) if after.get(s, ' ')[0] == enemy and VALUES[after[s][1]] >= 3]
            ok = len(targets) >= 2 and not rules.attacked(after, move[1], enemy)
        elif kind in ('escape-check', 'legal'):
            ok = True
        else:
            raise AssertionError(f'Unknown move claim {kind!r}')
        if ok:
            result.add((move[0], move[1]))
    return result


def claim_squares(board, exercise):
    claim = exercise['claim']
    kind, square = claim['type'], claim.get('square')
    if kind == 'locate':
        return {s for s, p in board.items() if p == claim['piece']}
    if kind == 'destinations':
        piece = board[square]
        if piece[0] + 'k' in board.values() and rules.other(piece[0]) + 'k' in board.values():
            return {m[1] for m in rules.legal_moves(board, piece[0], claim.get('enPassant'), claim.get('castling', '')) if m[0] == square}
        return rules.destinations(board, square, claim.get('enPassant'), claim.get('castling', ''))
    if kind == 'attacks':
        return rules.attacks(board, square)
    if kind == 'attackers':
        return {s for s, p in board.items() if p[0] == claim['colour'] and square in rules.attacks(board, s)}
    if kind == 'attacked-pieces':
        return {s for s, p in board.items() if p[0] != claim['colour'] and rules.attacked(board, s, claim['colour'])}
    if kind == 'undefended':
        return {s for s, p in board.items() if p[0] == claim['colour'] and p[1] != 'k' and not rules.attacked(board, s, claim['colour'])}
    raise AssertionError(f'Unknown square claim {kind!r}')


def king_route_exists(board, origin, target):
    colour = board[origin][0]
    enemy = rules.other(colour)
    others = {s: p for s, p in board.items() if s != origin}
    seen, frontier = {origin}, [origin]
    while frontier:
        square = frontier.pop()
        if square == target:
            return True
        for step in rules.attacks({square: colour + 'k'}, square):
            if step not in seen and step not in others and not rules.attacked(others, step, enemy):
                seen.add(step)
                frontier.append(step)
    return False


def validate_puzzle(puzzle):
    where = puzzle.get('id', '?')
    assert set(puzzle) == {'id', 'title', 'topic', 'level', 'exercise', 'board', 'highlights', 'context', 'explanation'}, f'{where}: puzzle fields'
    assert puzzle['level'] in LEVELS, f'{where}: level'
    for field in ('title', 'topic', 'explanation'):
        assert isinstance(puzzle[field], str) and puzzle[field].strip(), f'{where}: {field}'
    assert isinstance(puzzle['context'], str)
    board = puzzle['board']
    exercise = puzzle['exercise']
    assert isinstance(exercise.get('prompt'), str) and exercise['prompt'].strip(), f'{where}: prompt'
    kind = exercise['kind']
    if board is not None:
        rules.valid_board(board)
    for mark in puzzle['highlights']:
        assert isinstance(mark, dict) and set(mark) == {'sq', 'kind'} and mark['kind'] in HIGHLIGHTS, f'{where}: highlight {mark}'
    if kind == 'choice':
        assert set(exercise) == {'kind', 'prompt', 'choices', 'answer'}, f'{where}: choice fields'
        choices = exercise['choices']
        assert 2 <= len(choices) <= 4 and len(set(choices)) == len(choices) and exercise['answer'] in choices, f'{where}: choices'
        return
    assert board is not None and isinstance(exercise.get('claim'), dict), f'{where}: a board puzzle states a claim'
    if kind == 'squares':
        assert set(exercise) <= {'kind', 'prompt', 'answers', 'allowNone', 'claim'}, f'{where}: squares fields'
        answers = exercise['answers']
        assert len(set(answers)) == len(answers), f'{where}: repeated answer'
        expected = claim_squares(board, exercise)
        assert set(answers) == expected, f'{where}: answers {sorted(answers)} but the claim gives {sorted(expected)}'
        assert answers or exercise.get('allowNone'), f'{where}: an empty answer needs allowNone'
    elif kind == 'move':
        assert set(exercise) <= {'kind', 'prompt', 'from', 'to', 'alternatives', 'claim'}, f'{where}: move fields'
        accepted = {tuple(m) for m in exercise.get('alternatives', [[exercise['from'], exercise['to']]])}
        assert (exercise['from'], exercise['to']) in accepted, f'{where}: the reference move is accepted'
        expected = claim_moves(board, exercise)
        assert expected and accepted == expected, f'{where}: accepted {sorted(accepted)} but the claim gives {sorted(expected)}'
    elif kind == 'path':
        assert set(exercise) == {'kind', 'prompt', 'from', 'to', 'claim'} and exercise['claim'] == {'type': 'king-route'}, f'{where}: path fields'
        assert board.get(exercise['from'], ' ')[1:] == 'k' and king_route_exists(board, exercise['from'], exercise['to']), f'{where}: no safe king route'
    else:
        raise AssertionError(f'{where}: unknown exercise kind {kind!r}')


def parse_fen(text):
    placement, colour, castling, en_passant, *_ = text.split()
    board = {}
    rows = placement.split('/')
    assert len(rows) == 8, 'A FEN has eight ranks'
    for row, rank in zip(rows, '87654321'):
        file = 0
        for char in row:
            if char.isdigit():
                file += int(char)
            else:
                assert char.lower() in 'pnbrqk', f'FEN piece {char!r}'
                board[rules.FILES[file] + rank] = ('w' if char.isupper() else 'b') + char.lower()
                file += 1
        assert file == 8, f'FEN rank {rank} has {file} files'
    return board, colour, '' if castling == '-' else castling, None if en_passant == '-' else en_passant


def placement(board):
    """The first FEN field (piece placement) of a board."""
    rows = []
    for rank in '87654321':
        row, empty = '', 0
        for file in rules.FILES:
            piece = board.get(file + rank)
            if piece is None:
                empty += 1
                continue
            row += (str(empty) if empty else '') + (piece[1].upper() if piece[0] == 'w' else piece[1])
            empty = 0
        rows.append(row + (str(empty) if empty else ''))
    return '/'.join(rows)


def validate_practice_position(where, practice):
    """A practice position is a legal, unfinished game with White to move, not taken from the original course.

    Returns the position (board, castling rights, en-passant square) the exercise starts from.
    """
    assert isinstance(practice, dict) and isinstance(practice.get('fen'), str), f'{where}: practice states a FEN'
    board, colour, castling, en_passant = parse_fen(practice['fen'])
    rules.valid_board(board)
    assert colour == 'w', f'{where}: practice starts with White to move'
    assert sorted(p for p in board.values() if p[1] == 'k') == ['bk', 'wk'], f'{where}: practice has both kings'
    for right, king, rook in (('K', 'e1', 'h1'), ('Q', 'e1', 'a1'), ('k', 'e8', 'h8'), ('q', 'e8', 'a8')):
        if right in castling:
            assert board.get(king, '')[1:] == 'k' and board.get(rook, '')[1:] == 'r', f'{where}: castling right {right} needs the king and rook at home'
    if en_passant is not None:
        # White to move: Black's pawn has just stepped from rank 7 to rank 5, passing over the en-passant square.
        file = en_passant[0]
        assert en_passant[1] == '6' and board.get(file + '5') == 'bp' and en_passant not in board and file + '7' not in board, \
            f'{where}: en passant on {en_passant} needs a black pawn that has just made a double step past it'
    assert not rules.in_check(board, 'b'), f'{where}: the side not to move is in check'
    assert rules.legal_moves(board, 'w', en_passant, castling), f'{where}: White has no legal move'
    assert not provenance.board_hit(board), f'{where}: a practice position from the original course'
    return board, castling, en_passant


# The in-lesson exercise on a lesson's invitation step. The Swift decoder (CheckmateDomain/LessonPractice.swift) reads
# these exact names; the independent audit (Tools/audit-lesson-rules.py) checks the chess behind them.
PRACTICE_FIELDS = {'fen', 'goal', 'beat', 'checkpoints', 'opponent', 'hints', 'success'}
GRAPH_FIELDS = {'teaching', 'offTrack'}
CHECKPOINT_KINDS = {'graph', 'castle', 'enPassant', 'promote', 'pawnAdvance', 'pawnCapture', 'attackQueen', 'mate'}
TACTICS = {'fork', 'pin', 'skewer', 'discovered', 'removeDefender'}
NODE_FIELDS = {'fingerprint', 'accepted', 'replies', 'next'}
TEXT_LIMIT, LABEL_LIMIT = 220, 48
UCI = re.compile(r'^([a-h][1-8])([a-h][1-8])([qrbn]?)$')


def practice_text(where, value, limit=TEXT_LIMIT):
    assert isinstance(value, str) and value.strip() == value and value, f'{where}: a non-empty text without outer spaces'
    assert len(value) <= limit, f'{where}: {len(value)} characters, more than {limit}'


def uci_move(where, text, colour):
    """A UCI move ("e2e4", "a7a8q") as a lesson-rules move for `colour`."""
    match = UCI.match(text) if isinstance(text, str) else None
    assert match and match[1] != match[2], f'{where}: {text!r} is not a UCI move'
    return [match[1], match[2]] + ([colour + match[3]] if match[3] else [])


def legal_ucis(position):
    board, colour, castling, en_passant = position
    return {m[0] + m[1] + (m[2][1] if len(m) > 2 else ''): m for m in rules.legal_moves(board, colour, en_passant, castling)}


def validate_teaching(where, teaching, start):
    """Replay the teaching graph from the practice position. Returns every position the graph reaches with White to
    move: each node, and the position after each move that completes the graph (White's next turn, before Black's).

    Node 0 is the practice position. At every node White is to move and `fingerprint` is the node's piece placement
    and side to move. Each accepted move is legal; its authored reply (Black, legal) exists exactly when `next` names
    the node the graph continues at, so an accepted move without `next` completes the graph and has no reply. A reply
    for a move that is not accepted is a refutation of that legal off-track move. Indices are in range, every node is
    reachable, no path loops, so every path through accepted moves ends at a completed graph.
    """
    assert isinstance(teaching, list) and teaching, f'{where}: teaching lists its nodes'
    reached, positions = set(), []

    def visit(index, position, path):
        assert index not in path, f'{where}: teaching node {index} loops back on itself'
        here = f'{where}: teaching node {index}'
        node = teaching[index]
        assert isinstance(node, dict) and {'fingerprint', 'accepted'} <= set(node) <= NODE_FIELDS, f'{here}: fields'
        board, colour = position[:2]
        assert colour == 'w', f'{here}: White is to move at every node'
        assert node['fingerprint'] == placement(board) + ' w', f'{here}: fingerprint {node["fingerprint"]!r}, but the position is {placement(board)} w'
        legal = legal_ucis(position)
        accepted, replies, following = node['accepted'], node.get('replies', {}), node.get('next', {})
        assert isinstance(accepted, list) and accepted and len(set(accepted)) == len(accepted), f'{here}: accepted moves'
        assert isinstance(replies, dict) and isinstance(following, dict), f'{here}: replies and next map moves'
        assert ('replies' not in node or replies) and ('next' not in node or following), f'{here}: omit replies or next when empty'
        for move in accepted:
            uci_move(here, move, 'w')
            assert move in legal, f'{here}: accepted move {move} is not legal'
            assert (move in replies) == (move in following), f'{here}: {move} has a reply exactly when the graph continues after it'
        assert set(following) <= set(accepted), f'{here}: next names only accepted moves'
        for move, target in following.items():
            assert isinstance(target, int) and not isinstance(target, bool) and 0 <= target < len(teaching), f'{here}: next[{move}] = {target!r} is not a node'
        for move, reply in replies.items():
            uci_move(here, move, 'w')
            assert move in legal, f'{here}: {move} is not legal, so it has no reply'
            after = rules.advance(*position, legal[move])
            uci_move(here, reply, 'b')
            assert reply in legal_ucis(after), f'{here}: reply {reply} to {move} is not legal'
        positions.append(position)
        reached.add(index)
        for move in accepted:
            after = rules.advance(*position, legal[move])
            if move in following:
                visit(following[move], rules.advance(*after, legal_ucis(after)[replies[move]]), path | {index})
            else:
                positions.append((after[0], 'w', after[2], None))

    visit(0, start, frozenset())
    assert reached == set(range(len(teaching))), f'{where}: teaching nodes {sorted(set(range(len(teaching))) - reached)} are never reached'
    return positions


def castling_moves(position):
    board = position[0]
    return [m for m in legal_ucis(position).values() if board[m[0]] == 'wk' and abs(rules.xy(m[0])[0] - rules.xy(m[1])[0]) == 2]


def can_promote(board):
    """A white pawn with no black pawn ahead of it on its file, so it can reach the last rank without capturing."""
    return any(piece == 'wp' and not any(board.get(square[0] + rank) == 'bp' for rank in '12345678' if rank > square[1])
               for square, piece in board.items())


def validate_practice_exercise(lesson, frames):
    """A lesson's practice is the exercise on its invitation step, judged against `beat`'s board.

    Fields are exact: `fen`, `goal`, `beat`, `checkpoints`, `opponent`, `hints` and `success` always; `teaching` and
    `offTrack` together, for a forced opening; `mistakes` only with them. Checkpoints count in ANY order (the app
    judges each on the replayed game; the teaching graph, when present, comes first by construction), so no label or
    text may depend on their order and a kind appears at most once. A `graph` checkpoint needs a teaching graph; for a
    tactic it also names the tactic and the integer material the line must win, which only the audit reads. Mates are
    defended by `defender`, everything else by `beginner`. Hints are exactly two (the app adds a third stage itself).

    `mistakes`, `offTrack` and the hints describe the starting position only (the app shows them before the first move),
    so a `mistakes` move is off track there: it is not one of node 0's accepted moves.

    Every checkpoint is possible from the start: `enPassant` needs the FEN's en-passant square and a legal White
    en-passant capture at once; `promote` a white pawn with no black pawn ahead on its file; `pawnAdvance` and
    `pawnCapture` a white pawn; `attackQueen` a black queen; `castle` a legal castling move at the start, at a teaching
    node, or right after a move that completes the graph.
    """
    where, practice = lesson['id'], lesson['practice']
    board, castling, en_passant = validate_practice_position(where, practice)
    practice_text(f'{where}: practice goal', practice.get('goal'))
    fields = set(practice)
    assert PRACTICE_FIELDS <= fields and fields - PRACTICE_FIELDS in (set(), GRAPH_FIELDS, GRAPH_FIELDS | {'mistakes'}), \
        f'{where}: practice fields {sorted(fields)}; teaching and offTrack go together, mistakes only with them'
    for field in ('success', 'offTrack'):
        if field in practice:
            practice_text(f'{where}: practice {field}', practice[field])
    ids = [beat['id'] for beat in lesson['beats']]
    assert practice['beat'] in ids, f'{where}: practice beat {practice["beat"]!r} is not a beat of this lesson'
    frame = frames[ids.index(practice['beat'])]
    assert frame['start']['board'] == board == frame['end']['board'], f'{where}: the board of {practice["beat"]} is not the practice position'
    hints = practice['hints']
    assert isinstance(hints, list) and len(hints) == 2 and hints[0] != hints[1], f'{where}: exactly two different hints'
    for hint in hints:
        practice_text(f'{where}: hint', hint)
    checkpoints = practice['checkpoints']
    assert isinstance(checkpoints, list) and checkpoints, f'{where}: checkpoints say what counts as doing it'
    kinds = []
    for checkpoint in checkpoints:
        assert isinstance(checkpoint, dict) and checkpoint.get('kind') in CHECKPOINT_KINDS, f'{where}: checkpoint {checkpoint!r}'
        kind = checkpoint['kind']
        if kind == 'graph' and ('tactic' in checkpoint or 'gain' in checkpoint):
            assert set(checkpoint) == {'kind', 'label', 'tactic', 'gain'} and checkpoint['tactic'] in TACTICS, f'{where}: a tactic names one of {sorted(TACTICS)} and its gain'
            gain = checkpoint['gain']
            assert isinstance(gain, int) and not isinstance(gain, bool) and gain >= 1, f'{where}: gain is whole material won, at least 1'
        else:
            assert set(checkpoint) == {'kind', 'label'}, f'{where}: a {kind} checkpoint has a kind and a label'
        practice_text(f'{where}: {kind} label', checkpoint['label'], LABEL_LIMIT)
        kinds.append(kind)
    assert len(set(kinds)) == len(kinds), f'{where}: checkpoints count in any order, so each kind appears once'
    assert 'graph' not in kinds or 'teaching' in practice, f'{where}: a graph checkpoint needs a teaching graph'
    assert practice['opponent'] == ('defender' if 'mate' in kinds else 'beginner'), f'{where}: mates are defended by defender, everything else by beginner'
    start = (board, 'w', castling, en_passant)
    if set(kinds) & {'enPassant', 'promote', 'pawnAdvance', 'pawnCapture'}:
        assert 'wp' in board.values(), f'{where}: a pawn checkpoint needs a white pawn'
    if 'enPassant' in kinds:
        assert en_passant is not None, f"{where}: en passant is a checkpoint, so the FEN needs its en-passant square"
        assert any(m[1] == en_passant and board[m[0]] == 'wp' for m in legal_ucis(start).values()), f'{where}: no legal en-passant capture at the start'
    if 'promote' in kinds:
        assert can_promote(board), f'{where}: promotion is a checkpoint, but every white pawn has a black pawn ahead of it'
    if 'attackQueen' in kinds:
        assert 'bq' in board.values(), f'{where}: attacking the queen needs a black queen'
    positions = validate_teaching(where, practice['teaching'], start) if 'teaching' in practice else [start]
    if 'castle' in kinds:
        assert set(castling) & set('KQ'), f'{where}: castling is a checkpoint, but White has no castling right'
        assert any(castling_moves(position) for position in positions), f'{where}: castling is a checkpoint, but no legal castling exists at the start or in the graph'
    mistakes = practice.get('mistakes', {})
    assert isinstance(mistakes, dict) and ('mistakes' not in practice or mistakes), f'{where}: mistakes map moves to feedback'
    for move, text in mistakes.items():
        uci_move(f'{where}: mistakes', move, 'w')
        assert move not in practice['teaching'][0]['accepted'], f'{where}: mistakes describe the start, so {move} must be off track at node 0'
        practice_text(f'{where}: mistake {move}', text)


def validate_lesson(lesson):
    where = lesson.get('id', '?')
    assert LESSON_ID.match(where), f'{where}: lesson ids are lowercase words joined by hyphens'
    assert set(lesson) <= {'id', 'title', 'teaches', 'mascot', 'practiceFor', 'practice', 'beats'}, f'{where}: lesson fields'
    assert isinstance(lesson['title'], str) and lesson['title'].strip(), f'{where}: title'
    assert lesson['teaches'] and all(isinstance(t, str) and t.strip() for t in lesson['teaches']), f'{where}: takeaways'
    assert lesson.get('mascot') is None or lesson['mascot'] in rules.PIECES, f'{where}: mascot'
    assert lesson['beats'], f'{where}: beats'
    board = None
    for index, beat in enumerate(lesson['beats']):
        key = beat.get('id')
        assert key == f'{where}:{index}', f'{where}: beat {index} is {key!r}, expected {where}:{index}'
        assert set(beat) <= BEAT_KEYS, f'{key}: unknown fields {sorted(set(beat) - BEAT_KEYS)}'
        for field in ('label', 'say', 'speak'):
            assert isinstance(beat.get(field), str) and beat[field].strip(), f'{key}: {field}'
        assert isinstance(beat.get('big'), str), f'{key}: every beat states its title card, empty for none'
        assert len(beat['label']) <= 40, f'{key}: step labels stay short'
        if 'set' in beat:
            assert beat['set'] is None or isinstance(beat['set'], dict), f'{key}: set'
            board = copy.deepcopy(beat['set'])
            if board is not None:
                rules.valid_board(board)
        assert 'pause' not in beat or isinstance(beat['pause'], (int, float)) and 0 < beat['pause'] <= 5, f'{key}: pause'
        assert 'miniGame' not in beat or beat['miniGame'] is True, f'{key}: miniGame'
        board = validate_moves(key, board, beat)
        validate_overlays(key, beat, board)
    if 'practice' in lesson:
        validate_practice_exercise(lesson, lesson_frames(lesson))


def validate_practice(lessons):
    """A practice lesson names its parent: the nearest main lesson before it. Parents are never practice lessons."""
    parent = None
    for lesson in lessons:
        if 'practiceFor' not in lesson:
            parent = lesson['id']
            continue
        target = lesson['practiceFor']
        assert isinstance(target, str), f"practiceFor must name a lesson: {lesson['id']}"
        assert target != lesson['id'], f"A lesson cannot practise itself: {lesson['id']}"
        assert target == parent, f"{lesson['id']} must practise the nearest main lesson before it ({parent}), not {target}"


# Narration is recorded audio: it must not describe controls, whose names and places change without re-recording.
# A chess clock's button is equipment, not an app control.
UI_WORDS = re.compile(r"\b(?<!clock )(buttons?|panels?|sidebar|toolbar|tabs?)\b", re.I)
LESSON_REFERENCE = re.compile(r"((?:[\w'’-]+ ){1,6})lesson\b", re.I)
GENERIC_LESSON = {'a', 'an', 'the', 'this', 'that', 'each', 'every', 'next', 'previous', 'last', 'later', 'earlier', 'first', 'new', 'own', 'whole', 'one'}


# How a notation is said out loud: the transcript shows it too, or the text stops where the voice goes on.
SAID_AS = re.compile(r"\b(read|said) as\b", re.I)


def validate_narration_claims(lessons):
    """Recorded narration names no app control, any lesson it names by title exists under that title, and the
    transcript keeps every "read as" / "said as" the recording speaks."""
    titles = {l['title'].lower() for l in lessons} | {l['title'].lower().removeprefix('the ') for l in lessons}
    for lesson in lessons:
        for beat in lesson['beats']:
            spoken, shown = len(SAID_AS.findall(beat.get('speak') or beat['say'])), len(SAID_AS.findall(beat['say']))
            assert spoken == shown, f"{beat['id']}: the recording says how a notation is pronounced {spoken} time(s), the transcript {shown}"
        texts = [(b['id'], b[k]) for b in lesson['beats'] for k in ('say', 'speak')] + [(lesson['id'], t) for t in lesson.get('teaches', [])]
        for where, text in texts:
            word = UI_WORDS.search(text)
            assert not word, f"{where}: narration names an app control ({word.group(0)!r}); describe the action instead"
            for match in LESSON_REFERENCE.finditer(text):
                words = match.group(1).split()
                if words[-1].lower() in GENERIC_LESSON:
                    continue
                named = any(' '.join(words[i:]).lower() in titles for i in range(len(words)))
                assert named, f"{where}: narration names a lesson that does not exist: {match.group(0)!r}"


def strings(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, str):
        yield value


def boards(lessons, puzzles):
    for lesson in lessons:
        for frame in lesson_frames(lesson):
            for endpoint in ('start', 'end'):
                if frame[endpoint]['board']:
                    yield lesson['id'], frame[endpoint]['board']
    for puzzle in puzzles:
        if puzzle['board']:
            yield puzzle['id'], puzzle['board']


def validate(content, draft=False):
    if not draft:
        assert content['schemaVersion'] == 3
        assert content['publicationState'] in ('awaiting_recordings', 'published')
        assert content['locale'] == 'en-GB'
        assert 'voices' not in content, 'Editorial source must not carry generated narration metadata.'
        assert not content['exercises'] and not content['retiredExerciseIDs'], 'Lessons are continuous narration; exercises belong in Quick puzzles.'
    lessons, puzzles = content['lessons'], content['puzzles']
    ids = [l['id'] for l in lessons]
    assert len(set(ids)) == len(ids), 'Lesson ids are unique'
    for lesson in lessons:
        validate_lesson(lesson)
    if not draft:
        validate_practice(lessons)
    validate_narration_claims(lessons)
    puzzle_ids = [p['id'] for p in puzzles]
    assert len(set(puzzle_ids)) == len(puzzle_ids), 'Puzzle ids are unique'
    for puzzle in puzzles:
        validate_puzzle(puzzle)
    # Nothing of the original course returns: no wording, name or board position.
    # Puzzle explanations are also recorded, from their spoken form.
    spoken = [speech_text(p['explanation']) for p in puzzles]
    for text in [*strings({'lessons': lessons, 'puzzles': puzzles}), *spoken]:
        hit = provenance.text_hit(text)
        assert not hit, f'Original course material in {text[:80]!r}: {hit}'
    for where, board in boards(lessons, puzzles):
        assert not provenance.board_hit(board), f'{where}: a board position from the original course'
    return {b['id'] for l in lessons for b in l['beats']}


def outputs(content):
    lines = ['# Checkmate lesson scripts — British English', '',
             ('Published native course text with Cedar narration.' if content['publicationState'] == 'published' else 'Course text for recording. Status: awaiting recordings. This is not the currently bundled narration.'), '',
             'Lessons play continuously; standalone puzzles are separate.', '']
    narration = []
    for number, lesson in enumerate(content['lessons'], 1):
        lines += [f"## {number}. {lesson['title']}", '', '### Takeaways', '']
        lines += ['- ' + item for item in lesson['teaches']]
        lines += ['', '### Narration', '']
        for beat in lesson['beats']:
            lines += [f"**{beat['id']}** — {beat['label']}", '', beat['say'], '']
            if beat['speak'] != beat['say']:
                lines += ['Recording text: ' + beat['speak'], '']
            narration.append({'id': beat['id'], 'lessonId': lesson['id'], 'beatIndex': int(beat['id'].rsplit(':', 1)[1]),
                              'locale': content['locale'], 'displayText': beat['say'], 'text': beat['speak'],
                              'sha256': sha(beat['speak']), 'outputStem': f"voice-v2/{lesson['id']}/{int(beat['id'].rsplit(':', 1)[1]):02d}"})
    lines += ['## Standalone puzzle feedback', '']
    feedback = []
    for puzzle in content['puzzles']:
        lines += [f"### {puzzle['id']}", '', 'Question: ' + puzzle['exercise']['prompt'], '']
        if puzzle['context']:
            lines += ['Context: ' + puzzle['context'], '']
        lines += ['Answer explanation: ' + puzzle['explanation'], '']
        # Optional feedback audio is separate from sequential lesson clips.
        text = speech_text(puzzle['explanation'])
        feedback.append({'id': puzzle['id'] + ':feedback', 'locale': content['locale'],
                         'displayText': puzzle['explanation'], 'text': text, 'sha256': sha(text), 'delivery': 'optional_feedback'})

    def jsonl(records):
        return ''.join(json.dumps(record, ensure_ascii=False) + '\n' for record in records)
    return {'lesson-scripts.en-GB.md': '\n'.join(lines),
            'lesson-narration.en-GB.jsonl': jsonl(narration),
            'puzzle-feedback.en-GB.jsonl': jsonl(feedback)}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='Validate and require current exports without writing files.')
    parser.add_argument('--draft', nargs='+', type=Path, help='Validate draft lesson files on their own.')
    args = parser.parse_args()
    if args.draft:
        for path in args.draft:
            draft = json.loads(path.read_text())
            fill_speech(draft['lessons'])
            validate({'lessons': draft['lessons'], 'puzzles': draft.get('puzzles', [])}, draft=True)
            print(f'{path}: ok ({sum(len(l["beats"]) for l in draft["lessons"])} beats, {len(draft.get("puzzles", []))} puzzles)')
        return
    content = json.loads(CONTENT.read_text())
    ids = validate(content)
    for name, text in outputs(content).items():
        path = ROOT / 'Content' / name
        if args.check:
            assert path.exists() and path.read_text() == text, f'Stale export: {path}'
        else:
            path.write_text(text)
    print(json.dumps({'lessons': len(content['lessons']), 'segments': len(ids), 'puzzles': len(content['puzzles']),
                      'words': sum(len(b['say'].split()) for l in content['lessons'] for b in l['beats']),
                      'publicationState': content['publicationState']}, indent=2))


if __name__ == '__main__':
    main()
