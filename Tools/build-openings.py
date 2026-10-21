"""Build or check the bundled opening book (Sources/CheckmateCore/Resources/openings.tsv) from `Content/openings`.

Each row is one position some named opening line passes through, keyed by the first three FEN fields (placement, side
to move, castling rights; the en-passant square is left out so a double step that allows no capture still matches).
A position that ends a named line also carries that line's ECO code and name; when several lines end on the same
position the longer line wins, then the name, as the game library does. Matching positions rather than move strings
is what lets a game reached by another move order find its opening. The source and its CC0 dedication are recorded in
`Content/openings/SOURCE.md`.

  --check   offline: the bundled file is exactly what this script would write
"""
import argparse
import csv
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'Sources/CheckmateCore/Resources/openings.tsv'
spec = importlib.util.spec_from_file_location('provenance', ROOT / 'Tools/provenance.py')
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)
rules = provenance.rules


def placement(board):
    ranks = []
    for rank in '87654321':
        row, empty = '', 0
        for file in 'abcdefgh':
            piece = board.get(file + rank)
            if piece is None:
                empty += 1
                continue
            row += (str(empty) if empty else '') + (piece[1].upper() if piece[0] == 'w' else piece[1])
            empty = 0
        ranks.append(row + (str(empty) if empty else ''))
    return '/'.join(ranks)


def keys(pgn):
    """The position key after every ply of a standard-start line, the start included."""
    board, colour, castling, passed = dict(provenance.START), 'w', 'KQkq', None
    found = [f'{placement(board)} {colour} {castling or "-"}']
    for san in pgn.split():
        if san[0].isdigit():
            continue
        move = provenance.san_move(board, colour, castling, passed, san)
        board, colour, castling, passed = rules.advance(board, colour, castling, passed, move)
        found.append(f'{placement(board)} {colour} {castling or "-"}')
    return found


def build():
    theory, named = set(), {}
    for path in sorted((ROOT / 'Content/openings').glob('*.tsv')):
        with path.open(encoding='utf-8', newline='') as handle:
            rows = list(csv.reader(handle, delimiter='\t'))
        assert rows and rows[0] == ['eco', 'name', 'pgn'], f'{path.name}: unexpected columns'
        for eco, name, pgn in rows[1:]:
            assert '\t' not in name and '\n' not in name, f'{name!r}: unreadable name'
            line = keys(pgn)
            theory.update(line)
            named.setdefault(line[-1], []).append((len(line) - 1, name, eco))
    assert named, 'no named opening lines'
    out = ['epd\teco\tname']
    for key in sorted(theory):
        best = sorted(named.get(key, []), key=lambda item: (-item[0], item[1]))
        out.append('\t'.join([key, best[0][2], best[0][1]] if best else [key, '', '']))
    return '\n'.join(out) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    text = build()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding='utf-8') != text:
            print(f'{OUTPUT.relative_to(ROOT)} is out of date; run Tools/build-openings.py', file=sys.stderr)
            return 1
        return 0
    OUTPUT.write_text(text, encoding='utf-8')
    print(f'wrote {OUTPUT.relative_to(ROOT)}: {text.count(chr(10)) - 1} positions')
    return 0


if __name__ == '__main__':
    sys.exit(main())
