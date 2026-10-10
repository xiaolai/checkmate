#!/usr/bin/env python3
"""Record staged lessons with OpenAI Cedar. Never plays or activates recordings.

Default is a dry run. --generate requires --sample, --lesson or --all.
Each completed WAV has a provenance sidecar; both must validate before reuse.
"""
import argparse
import hashlib
import html
import io
import json
import math
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = 'https://api.openai.com/v1/audio/speech'
MAX_INPUT_CHARACTERS = 4096
KEY_LINE = re.compile(r'^\s*(?:export\s+)?OPENAI_API_KEY=(?:"([^"\n]*)"|\'([^\'\n]*)\'|(\S*))')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def api_key():
    value = os.environ.get('OPENAI_API_KEY', '').strip()
    if value:
        return value
    path = Path.home() / '.aienv'
    if path.exists():
        for line in path.read_text().splitlines():
            match = KEY_LINE.match(line)
            if match:
                value = next(v for v in match.groups() if v is not None).strip()
                if value:
                    return value
    raise ValueError('OPENAI_API_KEY is missing from the environment or ~/.aienv')


def payload(profile, text, speed=None):
    body = {name: profile[name] for name in ('model', 'voice', 'instructions', 'response_format', 'speed')}
    if speed is not None:
        body['speed'] = speed
    if body['voice'] != 'cedar' or body['response_format'] != 'wav':
        raise ValueError('This recording pipeline requires Cedar WAV masters')
    if not math.isfinite(body['speed']) or not 0.25 <= body['speed'] <= 4:
        raise ValueError('Speed must be finite and within 0.25…4')
    if not text.strip() or len(text) > MAX_INPUT_CHARACTERS:
        raise ValueError('Empty or oversized recording text')
    body['input'] = text
    return body


def request_hash(body):
    return digest(json.dumps(body, sort_keys=True, ensure_ascii=False, allow_nan=False).encode())


def load_units(path):
    units = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    seen = set()
    for unit in units:
        if unit['id'] in seen or unit['sha256'] != digest(unit['text'].encode()):
            raise ValueError('Duplicate ID or stale text hash: ' + unit['id'])
        if not re.fullmatch(r'[a-z0-9-]+', unit['lessonId']) or unit['beatIndex'] < 0:
            raise ValueError('Invalid output identity')
        if unit['id'] != f"{unit['lessonId']}:{unit['beatIndex']}":
            raise ValueError('Mismatched segment identity')
        seen.add(unit['id'])
    return units


def audio_info(data):
    with wave.open(io.BytesIO(data)) as audio:
        frames, rate = audio.getnframes(), audio.getframerate()
        if frames <= 0 or rate <= 0:
            raise ValueError('Empty WAV recording')
        samples = audio.readframes(frames)
        frame_width = audio.getnchannels() * audio.getsampwidth()
        # Speech responses may use a streaming WAV data-length sentinel.
        streaming_length = frames == 0xffffffff // frame_width
        if streaming_length:
            frames = len(samples) // frame_width
        if frames <= 0 or len(samples) != frames * frame_width or not any(samples):
            raise ValueError('Truncated or silent WAV recording')
        return {'seconds': frames / rate, 'sampleRate': rate, 'channels': audio.getnchannels(),
                'sampleWidth': audio.getsampwidth(), 'bytes': len(data)}


def finalize_wav(data):
    """Resolve streaming headers to a finite WAV without changing PCM samples."""
    audio_info(data)
    with wave.open(io.BytesIO(data)) as source:
        output = io.BytesIO()
        with wave.open(output, 'wb') as target:
            target.setnchannels(source.getnchannels())
            target.setsampwidth(source.getsampwidth())
            target.setframerate(source.getframerate())
            target.writeframes(source.readframes(source.getnframes()))
    return output.getvalue()


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(dir=path.parent, suffix='.part')
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Refusing an API redirect')


def generate(body, profile, key):
    opener = urllib.request.build_opener(NoRedirect)
    encoded = json.dumps(body, ensure_ascii=False, allow_nan=False).encode()
    for attempt in range(profile['retryAttempts']):
        request = urllib.request.Request(ENDPOINT, data=encoded, headers={
            'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        try:
            with opener.open(request, timeout=profile['requestTimeoutSeconds']) as response:
                return response.read(), response.headers.get('x-request-id')
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt + 1 == profile['retryAttempts']:
                # Never print remote response bodies or request headers.
                raise ValueError(f'OpenAI HTTP {error.code}; recording stopped') from None
            delay = profile['retryBackoffSeconds'] * 2 ** attempt
            try:
                delay = max(delay, float(error.headers.get('Retry-After', '0')))
            except ValueError:
                pass
            time.sleep(min(delay, profile['maxRetryDelaySeconds']))
        except (urllib.error.URLError, TimeoutError, OSError):
            # A timeout may follow a completed paid request. No blind retry.
            raise ValueError('Network failure; no automatic retry of an ambiguous request') from None


def record(unit, body, profile, output, render):
    identity = request_hash(body)
    directory = output / unit['lessonId']
    directory.mkdir(parents=True, exist_ok=True)
    stem = f"{unit['beatIndex']:02d}-{identity}"
    audio_path, sidecar = directory / (stem + '.wav'), directory / (stem + '.json')
    if audio_path.exists() and sidecar.exists():
        metadata, audio = json.loads(sidecar.read_text()), audio_path.read_bytes()
        if metadata['requestSHA256'] == identity and metadata['audioSHA256'] == digest(audio) and metadata['id'] == unit['id']:
            audio_info(audio)
            finalized = finalize_wav(audio)
            if finalized != audio:
                metadata['sourceAudioSHA256'] = metadata['audioSHA256']
                metadata['audioSHA256'] = digest(finalized)
                metadata['audio'] = audio_info(finalized)
                atomic_write(audio_path, finalized)
                atomic_write(sidecar, (json.dumps(metadata, ensure_ascii=False, indent=2) + '\n').encode())
            return metadata, True
        raise ValueError('Cached recording failed integrity check: ' + unit['id'])
    if audio_path.exists() or sidecar.exists():
        raise ValueError('Incomplete recording pair; inspect before regeneration: ' + str(audio_path))
    # Preflight local writes before spending credits.
    fd, temporary = tempfile.mkstemp(dir=directory, suffix='.preflight')
    os.close(fd)
    os.unlink(temporary)
    audio, request_id = render(body)
    source_hash = digest(audio)
    audio = finalize_wav(audio)
    metadata = {'schemaVersion': 1, 'id': unit['id'], 'textSHA256': unit['sha256'],
                'requestSHA256': identity, 'audioSHA256': digest(audio), 'profileId': profile['id'],
                'request': body, 'requestId': request_id, 'file': str(audio_path.relative_to(output)),
                'sourceAudioSHA256': source_hash,
                'audio': audio_info(audio), 'reviewState': 'awaiting_listening_review'}
    atomic_write(audio_path, audio)
    atomic_write(sidecar, (json.dumps(metadata, ensure_ascii=False, indent=2) + '\n').encode())
    return metadata, False


def audition_page(profile, output):
    rows = []
    for sidecar in output.glob('*/*.json'):
        metadata = json.loads(sidecar.read_text())
        if metadata['id'] in profile['auditionIds'] and metadata['profileId'] == profile['id']:
            rows.append(metadata)
    rows.sort(key=lambda row: (profile['auditionIds'].index(row['id']), -row['request']['speed']))
    cards = []
    for row in rows:
        text = html.escape(row['request']['input'])
        label = html.escape(f"{row['id']} — speed {row['request']['speed']:g}")
        file = html.escape(row['file'], quote=True)
        cards.append(f'<article><h2>{label}</h2><p>{text}</p><audio controls preload="none" aria-label="{label}" src="{file}"></audio></article>')
    page = '''<!doctype html><html lang="en-GB"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Checkmate — Cedar audition</title><style>
:root{color-scheme:light dark}body{font-family:system-ui;max-width:48rem;margin:2rem auto;padding:0 1rem;line-height:1.5}
article{border-bottom:1px solid GrayText;padding:1rem 0}h2{font-size:1rem}audio{width:100%}
</style><h1>Cedar lesson audition</h1><p>AI-generated recording masters for review. Compare natural pacing, pronunciation and consistency with the live coach. Playback starts only when you press Play.</p>'''
    atomic_write(output / 'audition.html', (page + ''.join(cards) + '</html>').encode())


def record_batch(units, bodies, profile, output, render, jobs, progress):
    """Keep only jobs requests in flight; stop scheduling after any failure."""
    results = [None] * len(units)
    work = iter(enumerate(zip(units, bodies)))
    executor = ThreadPoolExecutor(max_workers=jobs)
    pending = {}

    def submit():
        try:
            index, (unit, body) = next(work)
        except StopIteration:
            return False
        pending[executor.submit(record, unit, body, profile, output, render)] = index
        return True

    try:
        for _ in range(jobs):
            submit()
        while pending:
            done, _ = wait(pending, return_when=FIRST_COMPLETED)
            # Resolve all finished futures before scheduling more paid work.
            completed = [(future, future.result()) for future in done]
            for future, (metadata, cached) in completed:
                index = pending.pop(future)
                results[index] = metadata
                progress(metadata, cached)
            for _ in completed:
                submit()
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, default=ROOT / 'Content/narration-profile.cedar.json')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'Content/lesson-narration.en-GB.jsonl')
    parser.add_argument('--output', type=Path, default=ROOT / 'recordings/cedar')
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--sample', action='store_true')
    selection.add_argument('--lesson')
    selection.add_argument('--all', action='store_true')
    parser.add_argument('--speed', type=float)
    parser.add_argument('--generate', action='store_true', help='Perform paid API calls; otherwise dry run')
    parser.add_argument('--api-key-stdin', action='store_true', help='Read the recording key from stdin, useful for SSH without storing it on the host')
    parser.add_argument('--jobs', type=int, default=1, choices=range(1, 5), help='Concurrent requests, from 1 to 4')
    args = parser.parse_args()
    if args.generate and not (args.sample or args.lesson or args.all):
        parser.error('Generation requires an explicit selection')
    profile = json.loads(args.profile.read_text())
    units = load_units(args.manifest)
    if args.sample:
        by_id = {unit['id']: unit for unit in units}
        units = [by_id[identity] for identity in profile['auditionIds']]
    elif args.lesson:
        units = [unit for unit in units if unit['lessonId'] == args.lesson]
    if not units:
        raise ValueError('No matching recording units')
    bodies = [payload(profile, unit['text'], args.speed) for unit in units]
    print(json.dumps({'mode': 'generate' if args.generate else 'dry_run', 'segments': len(units),
                      'characters': sum(len(unit['text']) for unit in units), 'model': profile['model'],
                      'voice': profile['voice'], 'speed': bodies[0]['speed']}), flush=True)
    if not args.generate:
        return
    key = sys.stdin.read().strip() if args.api_key_stdin else api_key()
    if not key:
        raise ValueError('No OpenAI API key supplied')
    def progress(metadata, cached):
        print(f"{metadata['id']}: {'cached' if cached else 'recorded'} {metadata['audio']['seconds']:.2f}s", flush=True)
    results = record_batch(units, bodies, profile, args.output,
                           lambda body: generate(body, profile, key), args.jobs, progress)
    index = args.output / f"index-{digest(''.join(m['requestSHA256'] for m in results).encode())}.json"
    atomic_write(index, (json.dumps(results, ensure_ascii=False, indent=2) + '\n').encode())
    if args.sample:
        audition_page(profile, args.output)
        print('Audition page: ' + str(args.output / 'audition.html'))
    print('Review index: ' + str(index))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, wave.Error) as error:
        raise SystemExit(str(error)) from None
