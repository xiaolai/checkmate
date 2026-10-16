"""Build, check and reproduce the bundled game library (Sources/CheckmateCore/Resources/game-library).

`Content/game-library/selection.json` names the games, chosen before any source was read; `roster.json` lists the
World Championship events. The moves come only from downloaded source files (an untracked cache, never committed)
or from the two reviewed records kept in `Content/game-library/artifacts/`; `sources.json` records each one's URL,
SHA-256 and the selected record's place in it. Each source file is parsed whole, but only the selected records are
exported. The bundle keeps the moves and generated tags (the Seven Tag Roster with our own Event, plus ECO and Opening):
no comments, NAGs, variations or other source text.

  --acquire CACHE    locate every selected record in the cached sources, write sources.json and the bundle
  --reproduce CACHE  re-derive the bundle byte for byte from the recorded sources (refuses a changed source)
  --check            offline: the bundle matches the selection and replays exactly as its manifest says
"""
import argparse
import hashlib
import importlib.util
import json
import re
import sys
import unicodedata
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / 'Content/game-library'
BUNDLE = ROOT / 'Sources/CheckmateCore/Resources/game-library'
spec = importlib.util.spec_from_file_location('provenance', ROOT / 'Tools/provenance.py')
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)
rules = provenance.rules
FILES = {'world-championship': 'world-championship.pgn', 'classic': 'classic.pgn'}
KINDS = {'game', 'traditional', 'illustrative'}
RESULTS = {'1-0', '0-1', '1/2-1/2'}
MAXIMUM_PLIES = 2000  # ReviewPolicy.maximumMainlinePlies
MAXIMUM_BYTES = 2 * 1024 * 1024
TAGS = ['Event', 'Site', 'Date', 'Round', 'White', 'Black', 'Result']
PGNMENTOR = 'https://www.pgnmentor.com/'


def load(name):
    return json.loads((CONTENT / name).read_text(encoding='utf-8'))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def folded(text):
    return ''.join(c for c in unicodedata.normalize('NFKD', text) if not unicodedata.combining(c)).lower()


def words(text):
    return re.findall(r'[a-z0-9]+', folded(text))


# Source records -----------------------------------------------------------------------------------------------------

def records(text):
    """The records of a PGN file in order, each as (tags, movetext). A record starts at a tag line after movetext."""
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    result, tags, moves = [], [], []
    for line in text.split('\n'):
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']') and not moves:
            tags.append(stripped)
        elif stripped.startswith('[') and stripped.endswith(']'):
            result.append((tags, moves))
            tags, moves = [stripped], []
        elif stripped or moves:
            moves.append(line)
    if tags:
        result.append((tags, moves))
    parsed = []
    for tag_lines, move_lines in result:
        tags = {}
        for line in tag_lines:
            match = re.fullmatch(r'\[(\w+)\s+"((?:[^"\\]|\\.)*)"\]', line)
            if match and match.group(1) not in tags:
                tags[match.group(1)] = re.sub(r'\\(.)', r'\1', match.group(2))
        parsed.append((tags, '\n'.join(move_lines)))
    return parsed


def mainline(movetext):
    """The SAN tokens of a record's main line: comments, variations, NAGs, move numbers and the result removed."""
    text = re.sub(r'\{[^}]*\}', ' ', movetext)
    text = re.sub(r';[^\n]*', ' ', text)
    while True:
        stripped = re.sub(r'\([^()]*\)', ' ', text)
        if stripped == text:
            break
        text = stripped
    assert '(' not in text and ')' not in text, 'unbalanced variation'
    tokens = []
    for token in text.split():
        token = re.sub(r'^\d+\.+', '', token)
        if not token or re.fullmatch(r'\$\d+|1-0|0-1|1/2-1/2|\*', token):
            continue
        tokens.append(re.sub(r'[!?]+$', '', token).replace('0-0-0', 'O-O-O').replace('0-0', 'O-O'))
    return tokens


# Replay and notation ------------------------------------------------------------------------------------------------

def san(board, colour, castling, passed, move):
    """Standard SAN for a legal move, with the disambiguation, promotion and check or mate suffix it needs."""
    piece = board[move[0]][1]
    after, side, rights, ep = rules.advance(board, colour, castling, passed, move)
    suffix = ('#' if not rules.legal_moves(after, side, ep, rights) else '+') if rules.in_check(after, side) else ''
    if piece == 'k' and abs(ord(move[0][0]) - ord(move[1][0])) == 2:
        return ('O-O' if move[1][0] == 'g' else 'O-O-O') + suffix
    capture = move[1] in board or (piece == 'p' and move[1] == passed)
    if piece == 'p':
        text = (move[0][0] + 'x' if capture else '') + move[1] + ('=' + move[2][1].upper() if len(move) > 2 else '')
        return text + suffix
    rivals = [[square, move[1]] for square, other in board.items() if other == colour + piece and square != move[0]
              and move[1] in rules.destinations(board, square, passed, castling) and not rules.in_check(rules.play(board, [square, move[1]], passed), colour)]
    prefix = ''
    if rivals:
        if all(m[0][0] != move[0][0] for m in rivals):
            prefix = move[0][0]
        elif all(m[0][1] != move[0][1] for m in rivals):
            prefix = move[0][1]
        else:
            prefix = move[0]
    return piece.upper() + prefix + ('x' if capture else '') + move[1] + suffix


def play_game(tokens):
    """Replays SAN tokens from the start: every board, the UCI moves, canonical SAN and the final position's state."""
    board, colour, castling, passed = dict(provenance.START), 'w', 'KQkq', None
    boards, ucis, sans = [board], [], []
    for token in tokens:
        move = provenance.san_move(board, colour, castling, passed, token)
        sans.append(san(board, colour, castling, passed, move))
        ucis.append(move[0] + move[1] + (move[2][1] if len(move) > 2 else ''))
        board, colour, castling, passed = rules.advance(board, colour, castling, passed, move)
        boards.append(board)
    mated = rules.in_check(board, colour) and not rules.legal_moves(board, colour, passed, castling)
    return boards, ucis, sans, colour, mated


ENDINGS = {'checkmate', 'resignation', 'time', 'draw', 'unknown'}


def ending(game, result, mated, side_to_move):
    """How the game ended, never inferred beyond what is known: a draw, mate on the board, or a reviewed termination
    recorded in the selection with its citation. Any other decisive game is "unknown" (shown by its result alone)."""
    if result == '1/2-1/2':
        return 'draw'
    if mated:
        assert result == ('1-0' if side_to_move == 'b' else '0-1'), 'the mated side is the winner'
        return 'checkmate'
    reviewed = game.get('termination')
    if reviewed:
        assert reviewed['value'] in ('resignation', 'time') and reviewed.get('citation', '').startswith('https://'), f"{game['id']}: a termination needs a value and a citation"
        return reviewed['value']
    return 'unknown'


def opening(boards):
    """The deepest named-line position the game reaches (by placement key); ties: the longer line, then the name."""
    endpoints = {}
    for eco, name, line in provenance.opening_lines():
        endpoints.setdefault(provenance.board_key(line[-1]), []).append((len(line) - 1, name, eco))
    for board in reversed(boards[1:]):
        found = endpoints.get(provenance.board_key(board))
        if found:
            plies, name, eco = sorted(found, key=lambda item: (-item[0], item[1]))[0]
            return {'eco': eco, 'name': name}
    return None


# Bundle -------------------------------------------------------------------------------------------------------------

def round_label(event, game):
    if game['category'] == 'classic':
        return None
    if game['round'].startswith('tiebreak '):
        return 'Tiebreak game ' + game['round'].split()[-1]
    return ('Round ' if event['format'] == 'tournament' else 'Game ') + game['round']


def tag(name, value):
    return '[%s "%s"]' % (name, value.replace('\\', '\\\\').replace('"', '\\"'))


def movetext(sans, result):
    parts = []
    for index, move in enumerate(sans):
        parts.append((f'{index // 2 + 1}. ' if index % 2 == 0 else '') + move)
    parts.append(result)
    lines, line = [], ''
    for part in parts:
        if line and len(line) + 1 + len(part) > 79:
            lines.append(line)
            line = part
        else:
            line = f'{line} {part}' if line else part
    lines.append(line)
    return '\n'.join(lines)


def known_year(date):
    """The year a Date tag states, or '' when it leaves the year unknown."""
    return date[:4] if date[:4].isdigit() else ''


def event_span(event):
    """An event's years as the app names them: "1886", or "1890–91" for a match that ran into the next year."""
    first, last = event['years'][0], event['years'][-1]
    return str(first) if first == last else f"{first}–{str(last)[-2:]}"


def derive(game, source_tags, source_moves, events):
    """One bundled record and its manifest entry from a selected game and its source record."""
    tokens = mainline(source_moves)
    boards, ucis, sans, side, mated = play_game(tokens)
    result = source_tags.get('Result')
    assert result == game['result'], f"{game['id']}: the source's result is {result}, the selection says {game['result']}"
    assert 1 <= len(ucis) <= MAXIMUM_PLIES, f"{game['id']}: {len(ucis)} plies"
    named = opening(boards)
    event = events.get(game['event'])
    date = source_tags.get('Date') or '????.??.??'
    # The selection's date is only what the source's Date tag states: never a month or day it leaves unknown.
    known = [part for part in date.split('.') if part.isdigit()]
    assert [part for part in game['date'].split('.') if part] == known, \
        f"{game['id']}: the selection's date {game['date']} is not the source's known date {date}"
    if game['category'] == 'world-championship':
        # An event over two years is named by its span ("1890–91"). A game's own year is kept only when the source
        # dates it within such an event (a month is known); otherwise the year is not known and none is claimed.
        span = event_span(event)
        year = int(date[:4]) if date[:4].isdigit() else None
        if year is not None and len(set(event['years'])) > 1 and len(known) < 2:
            year = None
        assert year is None or year in event['years'], f"{game['id']}: dated {year}, outside the event's years"
        event_tag = f"{event['name']} {span}"
        title = f"{game['white']} – {game['black']}, {event['name']} {span}, {round_label(event, game)}"
        round_tag = game['round']
    else:
        year = int(date[:4]) if date[:4].isdigit() else None
        event_tag = source_tags.get('Event') or '?'
        title = game['name']
        round_tag = '?'
    site = source_tags.get('Site') or '?'
    tags = [tag('Event', event_tag), tag('Site', site), tag('Date', date), tag('Round', round_tag), tag('White', game['white']),
            tag('Black', game['black']), tag('Result', result)]
    if named:
        tags += [tag('ECO', named['eco']), tag('Opening', named['name'])]
    record = ('\n'.join(tags) + '\n\n' + movetext(sans, result) + '\n').encode('utf-8')
    entry = {'id': game['id'], 'category': game['category'], 'event': game['event'], 'kind': game['kind'], 'white': game['white'],
             'black': game['black'], 'site': site, 'date': date, 'year': year, 'round': round_tag, 'roundLabel': round_label(event, game) if event else None,
             'result': result, 'title': title, 'opening': named, 'plies': len(ucis), 'finalSAN': sans[-1], 'ending': ending(game, result, mated, side),
             'uciSHA256': sha256(' '.join(ucis).encode())}
    return record, entry


def bundle(selection, roster, source_records):
    """The category files and manifest for the selection, from each game's source record."""
    events = {event['id']: event for event in roster['events']}
    files = {category: b'' for category in FILES}
    games = []
    for game in selection['games']:
        record, entry = derive(game, *source_records[game['id']], events)
        category = game['category']
        if files[category]:
            files[category] += b'\n'
        entry |= {'file': FILES[category], 'offset': len(files[category]), 'length': len(record), 'sha256': sha256(record)}
        files[category] += record
        games.append(entry)
    counts = {category: sum(1 for game in games if game['category'] == category) for category in FILES}
    manifest = {'schemaVersion': 1, 'about': 'Generated by Tools/build-game-library.py; do not edit.', 'counts': counts,
                'events': [{key: event[key] for key in ('id', 'name', 'years', 'format', 'players')} for event in roster['events']], 'games': games}
    return {FILES[c]: data for c, data in files.items()} | {'manifest.json': (json.dumps(manifest, indent=1, ensure_ascii=False) + '\n').encode('utf-8')}


def write_bundle(outputs):
    BUNDLE.mkdir(parents=True, exist_ok=True)
    for stale in BUNDLE.iterdir():
        if stale.name not in outputs:
            stale.unlink()
    for name, data in outputs.items():
        (BUNDLE / name).write_bytes(data)


# Sources ------------------------------------------------------------------------------------------------------------

def artifact_bytes(cache, artifact):
    path = ROOT / artifact['repository'] if artifact.get('repository') else cache / artifact['cache']
    if not path.is_file():
        raise SystemExit(f"The source {artifact.get('repository') or artifact['cache']} is missing (expected at {path}).")
    data = path.read_bytes()
    if sha256(data) != artifact['sha256']:
        raise SystemExit(f"{artifact['cache']} differs from the recorded source (SHA-256 {sha256(data)}, recorded {artifact['sha256']}); refusing it.")
    if artifact.get('member'):
        with zipfile.ZipFile(path) as archive:
            data = archive.read(artifact['member'])
    return data


def source_text(data):
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError:
        return data.decode('latin-1')


# The selection writes players' names in their usual English spelling; some sources use another transliteration.
SPELLINGS = {'bogoljubov': 'bogoljubow', 'janowski': 'janowsky', 'korchnoi': 'kortschnoj'}


def matches(name, source):
    return name == '?' or {SPELLINGS.get(word, word) for word in words(name)} <= set(words(source))


def locate(game, recs, events):
    """The indexes of the records that can be the selected game: by round for a championship game (exactly one), by
    pairing, year and result for a classic (a player's collection can hold several; the moves' hash picks one)."""
    def players(tags):
        return matches(game['white'], tags.get('White', '')) and matches(game['black'], tags.get('Black', ''))
    if game['category'] == 'world-championship':
        tiebreak = game['round'].startswith('tiebreak ')
        number = game['round'].split()[-1]
        event = events[game['event']]
        def round_of(tags):
            return tags.get('Round', '').split('.')[0]
        def is_tiebreak(tags):
            return bool(re.search(r'playoff|rapid|tie|tb|blitz', tags.get('Event', ''), re.I))
        if event['format'] == 'tournament':
            found = [i for i, (tags, _) in enumerate(recs) if players(tags) and tags.get('Result') == game['result'] and round_of(tags) == number]
        else:
            found = [i for i, (tags, _) in enumerate(recs) if round_of(tags) == number and is_tiebreak(tags) == tiebreak]
    else:
        found = [i for i, (tags, _) in enumerate(recs) if players(tags) and known_year(tags.get('Date', '')) == game['date'][:4] and tags.get('Result') == game['result']]
    if game['category'] == 'world-championship' and len(found) != 1:
        raise SystemExit(f"{game['id']}: {len(found)} matching records in the source")
    for index in found:
        tags = recs[index][0]
        if not players(tags) or tags.get('Result') != game['result']:
            raise SystemExit(f"{game['id']}: the source has {tags.get('White')} - {tags.get('Black')} {tags.get('Result')}")
    return found


def uci_digest(moves):
    return sha256(' '.join(play_game(mainline(moves))[1]).encode())


def source_records(cache, sources, selection):
    """Every selected game's (tags, movetext) from the cached sources, checked against sources.json."""
    roster = {event['id']: event for event in load('roster.json')['events']}
    parsed, result = {}, {}
    for game in selection['games']:
        entry = sources['games'][game['id']]
        artifact = sources['artifacts'][entry['artifact']]
        if entry['artifact'] not in parsed:
            parsed[entry['artifact']] = records(source_text(artifact_bytes(cache, artifact)))
        recs = parsed[entry['artifact']]
        index = entry['record'] - 1
        assert 0 <= index < len(recs), f"{game['id']}: record {entry['record']} is not in {entry['artifact']}"
        assert index in locate(game, recs, roster), f"{game['id']}: the recorded record is not the selected game"
        tags, moves = recs[index]
        assert sha256(json.dumps([tags, moves], sort_keys=True).encode()) == entry['recordSHA256'], f"{game['id']}: the source record changed"
        result[game['id']] = (tags, moves)
    return result


def acquire(cache):
    """Writes sources.json for the selection from the cache (`artifacts.json` there lists each file's URL)."""
    selection, roster = load('selection.json'), load('roster.json')
    events = {event['id']: event for event in roster['events']}
    listing = json.loads((cache / 'artifacts.json').read_text())
    artifacts, games = {}, {}
    for game in selection['games']:
        pick = listing['games'][game['id']]
        name = pick['artifact']
        described = listing['artifacts'][name] | pick
        where = {'repository': described['repository']} if described.get('repository') else {'cache': described['cache']}
        data = (ROOT / described['repository'] if described.get('repository') else cache / described['cache']).read_bytes()
        artifact = {'url': described['url'], **where, 'sha256': sha256(data)} | ({'member': described['member']} if described.get('member') else {})
        if described.get('note'):
            artifact['note'] = described['note']
        artifacts[name] = artifact
        recs = records(source_text(artifact_bytes(cache, artifact)))
        found = locate(game, recs, events)
        if described.get('uciSHA256'):
            found = [i for i in found if uci_digest(recs[i][1]).startswith(described['uciSHA256'])]
        if len(found) != 1:
            raise SystemExit(f"{game['id']}: {len(found)} matching records in {name}")
        index = found[0]
        tags, moves = recs[index]
        # A source that states how the game ended must agree with the reviewed termination (none is ever inferred).
        if tags.get('Termination') and game['result'] != '1/2-1/2':
            assert game.get('termination'), f"{game['id']}: the source says {tags['Termination']!r}; record a reviewed termination"
        games[game['id']] = {'artifact': name, 'record': index + 1, 'recordSHA256': sha256(json.dumps([tags, moves], sort_keys=True).encode())}
    sources = {'schemaVersion': 1, 'about': 'Where each bundled game came from: the downloaded file (URL and SHA-256) and the 1-based position of its record there. The files themselves are kept only in an untracked cache.',
               'artifacts': dict(sorted(artifacts.items())), 'games': games}
    (CONTENT / 'sources.json').write_text(json.dumps(sources, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
    for game in selection['games']:
        game['source'] = f"{games[game['id']]['artifact']}#{games[game['id']]['record']}"
    (CONTENT / 'selection.json').write_text(json.dumps(selection, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
    outputs = bundle(selection, roster, source_records(cache, sources, selection))
    write_bundle(outputs)
    print(f"Acquired {len(selection['games'])} games from {len(artifacts)} sources.")


def reproduce(cache):
    if not cache.is_dir():
        print(f'The source cache {cache} is absent: nothing was reproduced.', file=sys.stderr)
        return 2
    selection, roster, sources = load('selection.json'), load('roster.json'), load('sources.json')
    outputs = bundle(selection, roster, source_records(cache, sources, selection))
    differing = sorted(name for name, data in outputs.items() if not (BUNDLE / name).is_file() or (BUNDLE / name).read_bytes() != data)
    extra = sorted(path.name for path in BUNDLE.iterdir() if path.name not in outputs)
    if differing or extra:
        print(f'The bundle differs from its sources: {differing + extra}', file=sys.stderr)
        return 1
    print(f"Reproduced {len(selection['games'])} games byte for byte from {len(sources['artifacts'])} sources.")
    return 0


# Check --------------------------------------------------------------------------------------------------------------

def bundled_records(manifest):
    """(entry, record bytes) for every manifest game, reading exactly its byte range; the ranges tile each file."""
    data = {name: (BUNDLE / name).read_bytes() for name in FILES.values()}
    covered = {name: 0 for name in FILES.values()}
    for entry in manifest['games']:
        name = entry['file']
        assert name == FILES[entry['category']], f"{entry['id']}: file {name}"
        start = entry['offset']
        assert start == covered[name] + (1 if covered[name] else 0), f"{entry['id']}: records do not follow each other"
        record = data[name][start:start + entry['length']]
        assert len(record) == entry['length'] and sha256(record) == entry['sha256'], f"{entry['id']}: record bytes do not match the manifest"
        covered[name] = start + entry['length']
        yield entry, record
    for name, end in covered.items():
        assert end == len(data[name]), f'{name}: bytes outside every record'


def check():
    selection, roster, sources = load('selection.json'), load('roster.json'), load('sources.json')
    manifest = json.loads((BUNDLE / 'manifest.json').read_text(encoding='utf-8'))
    events = {event['id']: event for event in roster['events']}
    assert manifest['events'] == [{key: event[key] for key in ('id', 'name', 'years', 'format', 'players')} for event in roster['events']], 'the manifest events are not the roster'
    assert [g['id'] for g in manifest['games']] == [g['id'] for g in selection['games']], 'the bundle is not the selection'
    assert len({g['id'] for g in selection['games']}) == len(selection['games']), 'duplicate ids'
    total = sum((BUNDLE / name).stat().st_size for name in (*FILES.values(), 'manifest.json'))
    assert total < MAXIMUM_BYTES, f'the bundle is {total} bytes'
    for (entry, record), game in zip(bundled_records(manifest), selection['games']):
        gid = game['id']
        assert re.fullmatch(r'[a-z0-9]+(-[a-z0-9]+)*', gid) and game['kind'] in KINDS and game['category'] in FILES, gid
        assert game['source'] == f"{sources['games'][gid]['artifact']}#{sources['games'][gid]['record']}", f'{gid}: source'
        assert re.fullmatch(r'[0-9a-f]{64}', sources['artifacts'][sources['games'][gid]['artifact']]['sha256']), f'{gid}: artifact hash'
        for key in ('category', 'event', 'kind', 'white', 'black', 'result'):
            assert entry[key] == game[key], f'{gid}: {key}'
        recs = records(record.decode('utf-8'))
        assert len(recs) == 1, f'{gid}: one record per byte range'
        tags, moves = recs[0]
        assert list(tags) == TAGS + (['ECO', 'Opening'] if entry['opening'] else []), f'{gid}: tags {list(tags)}'
        assert not re.search(r'[{};()$!?]', moves), f'{gid}: comments, variations or NAGs'
        source = (tags, moves)
        rebuilt, again = derive(game, *source, events)
        assert rebuilt == record, f'{gid}: the record is not in canonical form'
        fixed = {key: entry[key] for key in again}
        assert fixed == again, f'{gid}: manifest fields differ from the replay: ' + ', '.join(k for k in again if again[k] != entry[k])
        assert entry['round'] == (game['round'] if game['category'] != 'classic' else '?'), f'{gid}: round'
    covered = {g['event'] for g in manifest['games'] if g['event']}
    missing = [e for e in events if e not in covered]
    assert not missing, f'roster events without a game: {missing}'
    print(f"Game library check passed: {len(manifest['games'])} games, {len(covered)} of {len(events)} events, {total} bytes.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--acquire', type=Path, metavar='CACHE')
    mode.add_argument('--reproduce', type=Path, metavar='CACHE')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.acquire:
        acquire(args.acquire)
        return 0
    if args.reproduce:
        return reproduce(args.reproduce)
    return check()


if __name__ == '__main__':
    sys.exit(main())
