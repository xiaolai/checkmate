#!/usr/bin/env python3
"""Check on the build host that every Cedar master speaks its whole recording text. Never plays audio.

Speech synthesis sometimes stops early: 21 published clips once ended before their last sentence ("A side with no
move on its turn ..." without "loses"), and every other check passed them, because length, hashes and settings
were all consistent. This transcribes each master with whisper-1, with no prompt (a prompt of the script would let
the transcriber fill in words the audio lacks), and also its last three seconds on their own (a full transcript
often drops a short final sentence that is there). A master passes when the end of the text is heard and no run of
three or more script words is missing. Transcripts are cached by master hash; --generate makes the paid requests.

The importer refuses to publish a master without a passing record here. A clip that fails is retaken (move the
take aside, record again) or its text is reworded so it no longer ends on a short sentence the voice drops.
"""
import argparse
import difflib
import importlib.util
import io
import json
import re
import sys
import urllib.request
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import test_host
TAIL_SECONDS = 3.0
MISSING_RUN = 3

NUMBERS = dict(zip('0123456789', 'zero one two three'.split() + 'four five six'.split() + 'seven eight nine'.split()))
# Number words the transcriber writes as digits ("thirteen" as 13), spelled digit by digit like the digits are.
TENS = {'ten': 'one zero', 'eleven': 'one one', 'twelve': 'one two', 'thirteen': 'one three', 'fourteen': 'one four',
        'fifteen': 'one five', 'sixteen': 'one six', 'seventeen': 'one seven', 'eighteen': 'one eight',
        'nineteen': 'one nine', 'twenty': 'two zero', 'thirty': 'three zero', 'forty': 'four zero', 'fifty': 'five zero',
        'sixty': 'six zero'}
ORDINALS = {'first': 'one st', 'second': 'two nd', 'third': 'three rd', 'fourth': 'four th', 'fifth': 'five th',
            'sixth': 'six th', 'seventh': 'seven th', 'eighth': 'eight th'}
# British spellings in the script, American ones in a transcript: the same spoken word.
SPELLING = [(r'^(colo|behavio|favo|hono|harbo|neighbo)ur', r'\1r'), (r'^centre', 'center'), (r'^organis', 'organiz'),
            (r'^analys', 'analyz'), (r'^practis', 'practic'), (r'^chequer', 'checker'), (r'^recognis', 'recogniz')]


def words(text):
    """Spoken tokens: lower case, digits and ordinals spelled the same way on both sides, British spelling folded."""
    text = text.lower().replace('’', "'")
    # Apostrophes go, so "castle's" (a transcriber's spelling of "castles") and "castles" are one token.
    text = text.replace("'", '')
    text = re.sub(r'(\d)(st|nd|rd|th)\b', r'\1 \2', text)
    text = re.sub(r'\d', lambda m: ' ' + NUMBERS[m[0]] + ' ', text)
    out = []
    for token in re.findall(r'[a-z]+', text):
        for pattern, replacement in SPELLING:
            token = re.sub(pattern, replacement, token)
        out.extend(TENS.get(token, ORDINALS.get(token, token)).split())
    return out


SPOKEN_RANK = dict(zip('one two three four five six seven eight'.split(), '12345678'))


def squares_said(script):
    """Squares as the recording text spells them: "F six" is f6."""
    return [m[0].lower() + SPOKEN_RANK[m[1].lower()] for m in re.findall(r'\b([A-Ha-h]) (one|two|three|four|five|six|seven|eight)\b', script)]


def squares_heard(transcript):
    """Squares as a transcript writes them: "F6", "f 6" or "F-6" is f6; any other letter is kept, so a misspoken
    square ("S6") shows as a different square rather than vanishing."""
    text = re.sub(r'\b([a-zA-Z])\s?-?\s?([1-8])\b', lambda m: ' ' + m[1].lower() + m[2] + ' ', transcript)
    return re.findall(r'\b([a-z][1-8])\b', text)


def judge(script, full, tail):
    """Whether a transcript covers its script: the script's last two words end the tail transcript (or the full
    one), no run of MISSING_RUN or more script words is absent from the full transcript (except a final run the
    tail transcript holds), and every square heard in place of a script square is that square. Returns a list of
    problems; empty means it passes."""
    said, heard, ending = words(script), words(full), words(tail)
    problems = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(a=squares_said(script), b=squares_heard(full), autojunk=False).get_opcodes():
        if op == 'replace':
            problems.append('wrong square: script ' + ' '.join(squares_said(script)[i1:i2]) + ', heard ' + ' '.join(squares_heard(full)[j1:j2]))
    # Compared without spaces, so "white side" ends "whiteside" and "any more" ends "anymore", and without a final
    # s on each word, so "Black's" written "black" or "blacks" still ends the same.
    def bare(tokens):
        return ''.join(t.rstrip('s') for t in tokens)
    last = bare(said[-2:])
    if not any(bare(h).endswith(last) for h in (ending, heard)):
        problems.append('the end is not heard: expected "' + ' '.join(said[-2:]) + '", heard "' + ' '.join(ending[-4:]) + '"')
    for op, i1, i2, _, _ in difflib.SequenceMatcher(a=said, b=heard, autojunk=False).get_opcodes():
        if op == 'delete' and i2 - i1 >= MISSING_RUN:
            run = said[i1:i2]
            if i2 == len(said) and ' '.join(ending).endswith(' '.join(run[-MISSING_RUN:])):
                continue
            problems.append('missing: "' + ' '.join(run) + '"')
    return problems


def tail_wav(path, seconds=TAIL_SECONDS):
    with wave.open(str(path)) as source:
        rate, frames = source.getframerate(), source.getnframes()
        source.setpos(max(0, frames - int(rate * seconds)))
        data, params = source.readframes(frames), source.getparams()
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as target:
        target.setparams(params)
        target.writeframes(data)
    return buffer.getvalue()


def transcribe(audio, key, recorder):
    boundary = 'checkmate-' + uuid.uuid4().hex
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{n}"\r\n\r\n{v}\r\n'.encode()
             for n, v in [('model', 'whisper-1'), ('language', 'en'), ('response_format', 'json'), ('temperature', '0')]]
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="clip.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + audio + b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    request = urllib.request.Request('https://api.openai.com/v1/audio/transcriptions', data=b''.join(parts),
                                     headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'multipart/form-data; boundary=' + boundary})
    try:
        with urllib.request.build_opener(recorder.NoRedirect).open(request, timeout=180) as response:
            return json.load(response)['text']
    except Exception:
        raise ValueError('Transcription request failed; no response body logged') from None


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Tools' / file)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def coverage_dir(recordings):
    return Path(recordings).parent / 'coverage'


def passing(recordings, master):
    """The importer's gate: a cached, passing coverage record for exactly this master's audio and text."""
    file = coverage_dir(recordings) / (master['audioSHA256'] + '.json')
    if not file.exists():
        return False
    record = json.loads(file.read_text())
    return record.get('textSHA256') == master['textSHA256'] and not record.get('problems')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--generate', action='store_true', help='Perform paid transcription requests for uncached masters')
    parser.add_argument('--api-key-stdin', action='store_true')
    parser.add_argument('--recordings', type=Path, default=ROOT / 'recordings/cedar')
    args = parser.parse_args()
    test_host.require('the narration coverage check', role='build')
    verifier = module('verifier', 'verify-lesson-recordings.py')
    recorder = verifier.recorder
    profile = json.loads((ROOT / 'Content/narration-profile.cedar.json').read_text())
    units = {u['id']: u for u in recorder.load_units(ROOT / 'Content/lesson-narration.en-GB.jsonl')}
    masters, missing, failures = verifier.verify(profile, list(units.values()), args.recordings)
    if missing or failures:
        raise ValueError('Incomplete or invalid recordings; run the verifier')
    cache = coverage_dir(args.recordings)
    cache.mkdir(exist_ok=True)
    uncached = [m for m in masters if not (cache / (m['audioSHA256'] + '.json')).exists()]
    print(json.dumps({'masters': len(masters), 'uncached': len(uncached), 'mode': 'generate' if args.generate else 'check'}), flush=True)
    key = (sys.stdin.read().strip() if args.api_key_stdin else recorder.api_key()) if args.generate and uncached else None

    def job(master):
        file = cache / (master['audioSHA256'] + '.json')
        if file.exists():
            record = json.loads(file.read_text())
        elif key:
            audio = args.recordings / master['file']
            if recorder.digest(audio.read_bytes()) != master['audioSHA256']:
                raise ValueError('Stale master ' + master['id'])
            record = {'id': master['id'], 'textSHA256': master['textSHA256'], 'audioSHA256': master['audioSHA256'],
                      'full': transcribe(audio.read_bytes(), key, recorder), 'tail': transcribe(tail_wav(audio), key, recorder)}
        else:
            return master['id'], ['not transcribed yet']
        record['problems'] = judge(units[master['id']]['text'], record['full'], record['tail'])
        recorder.atomic_write(file, (json.dumps(record, ensure_ascii=False, indent=1) + '\n').encode())
        return master['id'], record['problems']

    with ThreadPoolExecutor(max_workers=4) as executor:
        results = dict(executor.map(job, masters))
    failed = {i: p for i, p in results.items() if p}
    for identity, problems in sorted(failed.items()):
        print(identity + ': ' + '; '.join(problems), flush=True)
    print(json.dumps({'checked': len(results), 'failed': len(failed)}), flush=True)
    if failed:
        raise SystemExit(1)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(str(error)) from None
