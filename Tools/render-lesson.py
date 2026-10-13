#!/usr/bin/env python3
"""Print lessons as text boards, beat by beat, for authoring and review. Never edits anything.

  python3 Tools/render-lesson.py LESSON_ID...          lessons from the course source
  python3 Tools/render-lesson.py --draft FILE [ID...]  lessons from a draft file

Each beat shows its narration, its moves and the board after them. Uppercase is White, lowercase Black; highlights
are marked beside the board, and arrows, guards and counted squares are listed. A staged beat lists its stages
in the order they appear.
"""
import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prepare', ROOT / 'Tools/prepare-lesson-scripts.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
LETTER = {'p': 'p', 'n': 'n', 'b': 'b', 'r': 'r', 'q': 'q', 'k': 'k'}


def board_text(board, marks):
    if board is None:
        return ['  (no board)']
    lines = []
    for rank in '87654321':
        row = []
        for file in 'abcdefgh':
            piece = board.get(file + rank)
            cell = (piece[1].upper() if piece[0] == 'w' else piece[1]) if piece else '.'
            row.append(cell + marks.get(file + rank, ' '))
        lines.append(f'  {rank} ' + ' '.join(row))
    lines.append('    ' + '  '.join('abcdefgh'))
    return lines


def render(lesson):
    out = [f"=== {lesson['id']} — {lesson['title']}" + (f" (practice for {lesson['practiceFor']})" if 'practiceFor' in lesson else '')]
    if 'practice' in lesson:
        out.append(f"practice position: {lesson['practice']['fen']} — {lesson['practice']['goal']}")
    symbol = {'focus': '*', 'go': '+', 'no': 'x', 'check': '!'}
    for beat, frame in zip(lesson['beats'], prepare.lesson_frames(lesson)):
        out.append('')
        out.append(f"[{beat['id']}] {beat['label']}" + (f"   card: {beat['big']!r}" if beat['big'] else ''))
        out.append(f"  say: {beat['say']}")
        if beat.get('moves'):
            out.append('  moves: ' + ', '.join('-'.join(m[:2]) + (f'={m[2]}' if len(m) > 2 else '') for m in beat['moves']))
        if beat.get('remove'):
            out.append('  removes: ' + ', '.join(beat['remove']))
        for number, stage in enumerate(beat.get('stages', [beat]), 1):
            prefix = f'  stage {number} ' if 'stages' in beat else '  '
            if stage.get('arrows'):
                out.append(prefix + 'arrows: ' + ', '.join(f'{a}->{b}' for a, b in stage['arrows']))
            if stage.get('guards'):
                out.append(prefix + 'guards: ' + ', '.join(f'{a}=>{b}' for a, b in stage['guards']))
            if stage.get('hl'):
                out.append(prefix + 'marks: ' + ' '.join(f"{h['sq']}{symbol[h['kind']]}({h['kind']})" for h in stage['hl']))
        if beat.get('count'):
            out.append('  counts: ' + ' '.join(beat['count']))
        marks = {h['sq']: symbol[h['kind']] for h in frame['end']['hl']}
        out.extend(board_text(frame['end']['board'], marks))
    return '\n'.join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('lessons', nargs='*')
    parser.add_argument('--draft', type=Path)
    args = parser.parse_args()
    source = json.loads((args.draft or prepare.CONTENT).read_text())
    for lesson in source['lessons']:
        if not args.lessons or lesson['id'] in args.lessons:
            print(render(lesson))
            print()
    for puzzle in source.get('puzzles', []):
        if not args.lessons or any(puzzle['id'].startswith(f'course:{lesson}:') for lesson in args.lessons):
            exercise = puzzle['exercise']
            print(f"--- puzzle {puzzle['id']} — {puzzle['title']} ({exercise['kind']}): {exercise['prompt']}")
            print('\n'.join(board_text(puzzle['board'], {h['sq']: '*' for h in puzzle['highlights']})))
            print(f"  answer: {json.dumps({k: v for k, v in exercise.items() if k not in ('kind', 'prompt')})}")
            print(f"  explanation: {puzzle['explanation']}\n")


if __name__ == '__main__':
    main()
