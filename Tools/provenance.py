"""Recognise material from the course this app's lessons once adapted, without the repository containing it.

`Content/provenance-blocklist.json` holds truncated SHA-256 digests only: every eight-word run of the original
wording, the original names (lesson, game and card titles, identifiers in any spelling), and every original board
position. Text is compared after the same normalisation used to build the list, so case, punctuation, curly quotes,
hyphens, underscores and camelCase spellings all match. A small reviewed allowance covers stock chess phrases that any
course says the same way.
"""
import hashlib
import json
import re
import unicodedata
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BLOCKLIST = ROOT / 'Content/provenance-blocklist.json'
SHINGLE = 8


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
