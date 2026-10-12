"""No tracked file carries wording, names or board positions of the course this app once adapted."""
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('provenance', ROOT / 'Tools/provenance.py')
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)
BINARY = {'.m4a', '.wav', '.png', '.jpg', '.icns', '.dmg', '.zip', '.gz', '.pdf', '.ttf', '.otf', '.car', '.a', '.dylib'}


# Test hosts receive the tree without its .git folder, so the walk skips what the repository ignores.
UNTRACKED = {'.git', '.build', '.swiftpm', 'build', 'evidence', 'recordings', 'dev-docs', '__pycache__', '.cc-suite'}


def tracked_files():
    listed = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, capture_output=True)
    if listed.returncode == 0 and (ROOT / '.git').exists():
        return listed.stdout.decode().split('\0')
    return [str(path.relative_to(ROOT)) for path in ROOT.rglob('*')
            if path.is_file() and not UNTRACKED & set(path.relative_to(ROOT).parts) and not any(part.startswith('.build') for part in path.relative_to(ROOT).parts) and not path.name.startswith('.env')]


def strings(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, str):
        yield value


class NormalisationTests(unittest.TestCase):
    def testSpellingsShareOneTokenStream(self):
        expected = ['pawn', 'duel', 'game']
        for text in ['Pawn Duel game', 'pawn-duel game', 'pawn_duel_game', 'pawnDuelGame', 'PAWN DUEL, game!', 'pawn‑duel game']:
            with self.subTest(text):
                self.assertEqual(provenance.tokens(text), expected)

    def testBoardKeyIgnoresInsertionOrder(self):
        self.assertEqual(provenance.board_key({'e4': 'wp', 'a1': 'wr'}), provenance.board_key({'a1': 'wr', 'e4': 'wp'}))

    def testBlocklistHoldsDigestsOnly(self):
        data = json.loads((ROOT / 'Content/provenance-blocklist.json').read_text())
        for key in ('shingles', 'allowedShingles', 'names', 'boards'):
            self.assertTrue(all(len(d) == 16 and set(d) <= set('0123456789abcdef') for d in data[key]), key)
        self.assertGreater(len(data['shingles']), 1000)
        self.assertGreater(len(data['boards']), 100)


class TrackedFileTests(unittest.TestCase):
    def testNoTrackedTextFileMatches(self):
        files = tracked_files()
        scanned, hits = 0, []
        for name in filter(None, files):
            path = ROOT / name
            if path.suffix.lower() in BINARY or not path.is_file() or name == 'Content/provenance-blocklist.json':
                continue
            try:
                text = path.read_text(encoding='utf-8')
            except UnicodeDecodeError:
                continue
            scanned += 1
            # JSON is checked string by string, keys and values apart, so a key never joins the text beside it.
            if path.suffix in ('.json', '.jsonl'):
                documents = [json.loads(line) for line in text.splitlines() if line.strip()] if path.suffix == '.jsonl' else [json.loads(text)]
                hits += [f'{name}: {hit} in {value[:60]!r}' for document in documents for value in strings(document) if (hit := provenance.text_hit(value))]
                continue
            for number, line in enumerate(text.splitlines(), 1):
                hit = provenance.text_hit(line)
                if hit:
                    hits.append(f'{name}:{number}: {hit}')
        self.assertGreater(scanned, 300, 'the scan reached the tracked files')
        self.assertEqual(hits, [])

    def testNoPublishedBoardMatches(self):
        course = json.loads((ROOT / 'Sources/CheckmateCore/Resources/course.json').read_text())
        boards = [frame[end]['board'] for lesson in course['frames'] for frame in lesson for end in ('start', 'end')]
        boards += [puzzle['board'] for puzzle in course['puzzles']]
        start = provenance.board_key({f + r: c + p for f, p in zip('abcdefgh', 'rnbqkbnr') for r, c in (('1', 'w'), ('8', 'b'))}
                                     | {f + r: c + 'p' for f in 'abcdefgh' for r, c in (('2', 'w'), ('7', 'b'))})
        matched = [b for b in boards if b and provenance.board_hit(b) and provenance.board_key(b) != start]
        self.assertGreater(len(boards), 1000)
        self.assertEqual(matched, [])


if __name__ == '__main__':
    unittest.main()
