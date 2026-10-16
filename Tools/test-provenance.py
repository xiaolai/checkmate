"""No tracked file carries wording, names or board positions of the course this app once adapted."""
import hashlib
import importlib.util
import json
import re
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


LIBRARY = ROOT / 'Sources/CheckmateCore/Resources/game-library'
START = provenance.START
replay = provenance.replay
# The allowed set pinned for opening data commit a6189a30 (Content/openings/SOURCE.md): enlarging it fails until reviewed.
ALLOWED_OPENING_BOARDS = {'2602e938d15d667a', '293dd05855c1e3ba', '2be5321eff5aecf3', '3a25b61ce10271c1', '4c87c5378487cd8f', '64399ffea6ad81c6',
                          '79c0e4fa4f4370af', '8d0d9379831c4bdd', '91af274c7d8b24c1', 'cdb97b464526c94e', 'e6cfc064b365fabe', 'f06b1252f07229d8'}
# Two games the allowance must not let in: (moves, UCI SHA-256 the earlier famous-games work cross-checked with python-chess).
OPERA = ('e4 e5 Nf3 d6 d4 Bg4 dxe5 Bxf3 Qxf3 dxe5 Bc4 Nf6 Qb3 Qe7 Nc3 c6 Bg5 b5 Nxb5 cxb5 Bxb5+ Nbd7 O-O-O Rd8 Rxd7 Rxd7 Rd1 Qe6 Bxd7+ Nxd7 Qb8+ Nxb8 Rd8#',
         'f4d7ff5795e28329aa93c2dd56d9eeda1d041d531ee6da057338c6f559911b05')
SCHOLARS = ('e4 e5 Bc4 Nc6 Qh5 Nf6 Qxf7#', 'e62997fdaaf4637738edf1c0ab824772ea84752bc73c333a64b51eb9c081c9c5')


def fen_board(fen):
    """The piece placement of a FEN as a board map; the other FEN fields are ignored, exactly as board keys ignore them."""
    board = {}
    for rank, row in zip('87654321', fen.split()[0].split('/')):
        file = 0
        for c in row:
            if c.isdigit():
                file += int(c)
            else:
                board['abcdefgh'[file] + rank] = ('w' if c.isupper() else 'b') + c.lower()
                file += 1
    return board


def library_games():
    """Every record of every category file of the game library, read by its manifest byte range (one file holds many)."""
    manifest = json.loads((LIBRARY / 'manifest.json').read_text())
    files = {name: (LIBRARY / name).read_bytes() for name in {game['file'] for game in manifest['games']}}
    for game in manifest['games']:
        text = files[game['file']][game['offset']:game['offset'] + game['length']].decode('utf-8')
        headers = re.findall(r'^\[(\w+) "([^"]*)"\]$', text, re.M)
        yield game, headers, re.sub(r'^\[.*\]$', '', text, flags=re.M)


def library_hits(boards_blocked, allowed=None):
    """Prohibited text or boards in the bundled games: manifest text, tags, title and every replayed position.

    A board passes when it is a named opening line's position (`bundled_board_hit`); `allowed` overrides that set."""
    allowed = provenance.opening_positions() if allowed is None else allowed
    hits = []
    for game, headers, movetext in library_games():
        hits += [f"{game['id']}: {hit} in {value[:60]!r}" for value in strings(game) if (hit := provenance.text_hit(value))]
        hits += [f"{game['id']}: {hit} in header {name}" for name, value in headers if (hit := provenance.text_hit(value))]
        boards, _ = replay(movetext)
        # Only the full starting position may match (Content/README.md); every later board is checked.
        for ply, board in enumerate(boards):
            key = provenance.digest(provenance.board_key(board))
            if provenance.board_key(board) != provenance.board_key(START) and key in boards_blocked and key not in allowed:
                hits.append(f"{game['id']}: original board after ply {ply}")
    return hits


def lesson_famous_game():
    """The UCI moves of the course's own famous game, castling's rook step folded into the king's move."""
    course = json.loads((ROOT / 'Content/course-scripts.en-GB.json').read_text())
    lesson = next(lesson for lesson in course['lessons'] if lesson['id'] == 'famous-game')
    steps = [move for beat in lesson['beats'] for move in beat.get('moves', [])]
    ucis, skip = [], False
    for index, (origin, target, *rest) in enumerate(steps):
        if skip:
            skip = False
            continue
        ucis.append(origin + target)
        skip = origin in ('e1', 'e8') and abs(ord(origin[0]) - ord(target[0])) == 2 and index + 1 < len(steps) and steps[index + 1][0][0] in 'ah'
    return ucis


class OpeningAllowanceTests(unittest.TestCase):
    def testTheAllowedSetIsTheReviewedBaseline(self):
        allowed = set(provenance.blocklist()[3]) & provenance.opening_positions()
        self.assertEqual(allowed, ALLOWED_OPENING_BOARDS)
        self.assertNotIn(provenance.digest(provenance.board_key(START)), provenance.blocklist()[3])

    def testABlockedOpeningBoardPassesInABundledGameOnly(self):
        digest = sorted(ALLOWED_OPENING_BOARDS)[0]
        board = next(board for _, _, boards in provenance.opening_lines() for board in boards if provenance.digest(provenance.board_key(board)) == digest)
        self.assertFalse(provenance.bundled_board_hit(board))
        # Course content keeps the plain check, which has no allowance.
        self.assertTrue(provenance.board_hit(board))
        # Planted in every bundled game's blocklist, a named-line board passes; the same board without the allowance fails.
        game, _, movetext = next(library_games())
        first = replay(movetext)[0][1]
        planted = set(provenance.blocklist()[3]) | {provenance.digest(provenance.board_key(first))}
        self.assertIn(provenance.digest(provenance.board_key(first)), provenance.opening_positions())
        self.assertEqual(library_hits(planted), [])
        self.assertTrue(any(hit.startswith(game['id'] + ': original board after ply 1') for hit in library_hits(planted, allowed=frozenset())))

    def testABoardOutsideEveryNamedLineStillFails(self):
        game, _, movetext = next(library_games())
        boards, _ = replay(movetext)
        late = boards[-1]
        self.assertNotIn(provenance.digest(provenance.board_key(late)), provenance.opening_positions())
        planted = set(provenance.blocklist()[3]) | {provenance.digest(provenance.board_key(late))}
        self.assertTrue(any(hit.startswith(f"{game['id']}: original board after ply {len(boards) - 1}") for hit in library_hits(planted)))

    def testPlacementKeysIgnoreTheRestOfTheFen(self):
        placement = 'r3k2r/8/8/3pP3/8/8/8/R3K2R'
        keys = {provenance.board_key(fen_board(f'{placement} {state}')) for state in ('w KQkq d6 0 1', 'b - - 5 40', 'w Kq - 12 7')}
        self.assertEqual(len(keys), 1)

    def testOperaAndScholarsMateStayOut(self):
        for moves, uci_sha in (OPERA, SCHOLARS):
            with self.subTest(moves[:20]):
                boards, ucis = replay(moves)
                self.assertEqual(hashlib.sha256(' '.join(ucis).encode()).hexdigest(), uci_sha)
                self.assertTrue(any(provenance.bundled_board_hit(board) for board in boards[1:]))


class GameLibraryTests(unittest.TestCase):
    def testReplayMatchesTheManifest(self):
        games = 0
        for game, headers, movetext in library_games():
            with self.subTest(game['id']):
                _, ucis = replay(movetext)
                names = [name for name, _ in headers]
                self.assertEqual(names[:7], ['Event', 'Site', 'Date', 'Round', 'White', 'Black', 'Result'])
                self.assertIn(names[7:], ([], ['ECO', 'Opening']))
                self.assertEqual(len(ucis), game['plies'])
                self.assertEqual(hashlib.sha256(' '.join(ucis).encode()).hexdigest(), game['uciSHA256'])
                games += 1
        self.assertGreaterEqual(games, 150, 'the walker read every record of each category file')

    def testNoBundledGameMatchesTheBlocklist(self):
        self.assertEqual(library_hits(provenance.blocklist()[3]), [])

    def testAPlantedIntermediateBoardIsRejected(self):
        game, _, movetext = next(library_games())
        boards, _ = replay(movetext)
        planted = set(provenance.blocklist()[3]) | {provenance.digest(provenance.board_key(boards[30]))}
        self.assertTrue(any(hit.startswith(game['id'] + ': original board after ply 30') for hit in library_hits(planted)))
        # The starting position stays allowed even when listed.
        self.assertEqual(library_hits(set(provenance.blocklist()[3]) | {provenance.digest(provenance.board_key(START))}), [])

    def testNoBundledGameIsTheCourseGame(self):
        lesson = lesson_famous_game()
        self.assertEqual(len(lesson), 21, 'the course game was read')
        for game, _, movetext in library_games():
            with self.subTest(game['id']):
                self.assertNotEqual(replay(movetext)[1], lesson)


if __name__ == '__main__':
    unittest.main()
