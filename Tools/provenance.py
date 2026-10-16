"""Recognise material from the course this app's lessons once adapted, without the repository containing it.

`Content/provenance-blocklist.json` holds truncated SHA-256 digests only: every eight-word run of the original
wording, the original names (lesson, game and card titles, identifiers in any spelling), and every original board
position. Text is compared after the same normalisation used to build the list, so case, punctuation, curly quotes,
hyphens, underscores and camelCase spellings all match. A small reviewed allowance covers stock chess phrases that any
course says the same way.

Bundled historical games (the game library) have one more, narrow allowance: a board that is a position of a named
standard opening line (`Content/openings`, Lichess chess-openings, CC0) passes for them even when the list has it.
Lessons and every other caller keep `board_hit`, which has no such allowance.
"""
import csv
import hashlib
import importlib.util
import json
import re
import unicodedata
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BLOCKLIST = ROOT / 'Content/provenance-blocklist.json'
OPENINGS = ROOT / 'Content/openings'
SHINGLE = 8
_rules_spec = importlib.util.spec_from_file_location('lesson_rules', ROOT / 'Tools/lesson_rules.py')
rules = importlib.util.module_from_spec(_rules_spec)
_rules_spec.loader.exec_module(rules)
START = {f + r: c + p for f, p in zip('abcdefgh', 'rnbqkbnr') for r, c in (('1', 'w'), ('8', 'b'))} | {f + r: c + 'p' for f in 'abcdefgh' for r, c in (('2', 'w'), ('7', 'b'))}


def digest(text):
    return hashlib.sha256(('provenance-v1|' + text).encode('utf-8')).hexdigest()[:16]


def tokens(text):
    text = unicodedata.normalize('NFKC', text)
    text = re.sub(r'([a-z0-9])([A-Z])', r'\1 \2', text)
    return re.findall(r'[a-z0-9]+', text.lower())


def board_key(board):
    return ','.join(f'{square}={board[square]}' for square in sorted(board))


@lru_cache(maxsize=1)
def blocklist():
    data = json.loads(BLOCKLIST.read_text())
    assert data['schemaVersion'] == 1 and data['shingle'] == SHINGLE
    return (set(data['shingles']) - set(data['allowedShingles']), set(data['names']),
            sorted({int(n) for n in data['nameLengths']}), set(data['boards']))


def text_hit(text):
    """A description of the first original phrase or name in `text`, or None."""
    shingles, names, lengths, _ = blocklist()
    words = tokens(text)
    for size in lengths:
        for i in range(len(words) - size + 1):
            if digest(' '.join(words[i:i + size])) in names:
                return f'an original name ({size} word{"s" if size > 1 else ""} at word {i + 1})'
    for i in range(len(words) - SHINGLE + 1):
        if digest(' '.join(words[i:i + SHINGLE])) in shingles:
            return f'original wording (eight words from word {i + 1})'
    return None


def board_hit(board):
    return bool(board) and digest(board_key(board)) in blocklist()[3]


def san_move(board, colour, castling, passed, san):
    """The one legal move `san` names in this position, as [from, to] or [from, to, promotion]; anything else fails.

    Only the named piece's candidate moves are tested for legality, which keeps replaying thousands of lines quick."""
    plain = san.rstrip('+#')
    if plain in ('O-O', 'O-O-O'):
        rank = '1' if colour == 'w' else '8'
        kind, file, rank_, target, promotion = 'K', 'e', rank, ('g' if plain == 'O-O' else 'c') + rank, None
        if board.get('e' + rank) != colour + 'k':
            raise AssertionError(f'{san} is not exactly one legal move')
    else:
        match = re.fullmatch(r'([NBRQK]?)([a-h]?)([1-8]?)x?([a-h][1-8])(?:=([NBRQ]))?', plain)
        assert match, f'Unreadable move {san}'
        kind, file, rank_, target, promotion = match.groups()
        if not kind and 'x' not in plain:
            file = target[0]  # a pawn that does not capture stays on its file
    piece = colour + (kind.lower() or 'p')
    found = []
    for square, occupant in board.items():
        if occupant != piece or not square.startswith(file) or not square.endswith(rank_) or target not in rules.destinations(board, square, passed, castling):
            continue
        last = target[1] in '18' and piece[1] == 'p'
        if last != bool(promotion):
            continue
        move = [square, target, colour + promotion.lower()] if promotion else [square, target]
        if not rules.in_check(rules.play(board, move, passed), colour):
            found.append(move)
    # Castling is the king's two-square step only; a one-square king move never reads as O-O.
    if plain in ('O-O', 'O-O-O'):
        found = [m for m in found if m[0] == 'e' + target[1]]
    assert len(found) == 1, f'{san} is not exactly one legal move'
    return found[0]


def replay(movetext):
    """Every board of a standard-start game in SAN, with its UCI moves; a move that is not exactly one legal move fails."""
    board, colour, castling, passed = dict(START), 'w', 'KQkq', None
    boards, ucis = [board], []
    for san in movetext.split():
        if re.fullmatch(r'\d+\.+|1-0|0-1|1/2-1/2|\*', san):
            continue
        san = re.sub(r'^\d+\.+', '', san)
        move = san_move(board, colour, castling, passed, san)
        ucis.append(move[0] + move[1] + (move[2][1] if len(move) > 2 else ''))
        board, colour, castling, passed = rules.advance(board, colour, castling, passed, move)
        boards.append(board)
    return boards, ucis


@lru_cache(maxsize=1)
def opening_lines():
    """Every named line of the vendored opening files: (eco, name, its boards from the start, one per ply)."""
    lines = []
    for path in sorted(OPENINGS.glob('*.tsv')):
        with path.open(encoding='utf-8', newline='') as handle:
            rows = list(csv.reader(handle, delimiter='\t'))
        assert rows and rows[0] == ['eco', 'name', 'pgn'], f'{path.name}: unexpected columns'
        lines += [(eco, name, tuple(replay(pgn)[0])) for eco, name, pgn in rows[1:]]
    assert lines, 'no named opening lines'
    return lines


@lru_cache(maxsize=1)
def opening_positions():
    """Digests of every prefix position of every named line, keyed exactly as `board_hit` keys boards."""
    return frozenset(digest(board_key(board)) for _, _, boards in opening_lines() for board in boards)


def bundled_board_hit(board):
    """`board_hit` for a bundled historical game: a named opening line's position is allowed."""
    return board_hit(board) and digest(board_key(board)) not in opening_positions()
