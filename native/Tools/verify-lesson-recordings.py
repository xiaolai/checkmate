#!/usr/bin/env python3
"""Verify the complete selected narration profile without API calls or playback."""
import argparse
import hashlib
import html
import importlib.util
import json
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('recorder', HERE / 'record-lessons.py')
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


def verify(profile, units, output):
    verified, missing, failures = [], [], []
    for unit in units:
        body = recorder.payload(profile, unit['text'])
        identity = recorder.request_hash(body)
        stem = f"{unit['beatIndex']:02d}-{identity}"
        audio = output / unit['lessonId'] / (stem + '.wav')
        sidecar = audio.with_suffix('.json')
        if not audio.exists() or not sidecar.exists():
            missing.append(unit['id'])
            continue
        try:
            metadata = json.loads(sidecar.read_text())
            data = audio.read_bytes()
            info = recorder.audio_info(data)
            assert metadata['id'] == unit['id'], 'Segment ID mismatch'
            assert metadata['profileId'] == profile['id'], 'Profile ID mismatch'
            assert metadata['textSHA256'] == unit['sha256'], 'Text hash mismatch'
            assert metadata['request'] == body, 'Speech settings mismatch'
            assert metadata['requestSHA256'] == identity, 'Request hash mismatch'
            assert metadata['audioSHA256'] == hashlib.sha256(data).hexdigest(), 'Audio hash mismatch'
            assert metadata['audio'] == info, 'Audio metadata mismatch'
            assert metadata['file'] == str(audio.relative_to(output)), 'Audio path mismatch'
            assert recorder.finalize_wav(data) == data, 'Unfinalized WAV container'
            verified.append(metadata)
        except (AssertionError, ValueError, KeyError, OSError, wave.Error, EOFError) as error:
            failures.append({'id': unit['id'], 'error': str(error)})
    return verified, missing, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, default=HERE.parent / 'Content/narration-profile.cedar.json')
    parser.add_argument('--manifest', type=Path, default=HERE.parent / 'Content/lesson-narration.en-GB.jsonl')
    parser.add_argument('--output', type=Path, default=HERE.parent / 'recordings/cedar')
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text())
    units = recorder.load_units(args.manifest)
    verified, missing, failures = verify(profile, units, args.output)
    runtime = json.loads((HERE.parent / 'Sources/CheckmateCore/Resources/course.json').read_text())
    narration = runtime.get('narration', {})
    published = all(narration.get(key) == profile[key] for key in ('provider', 'voice', 'model', 'speed'))
    if published:
        assets_file = HERE.parent / 'Sources/CheckmateCore/Resources' / narration['manifest']
        active_assets = {row['id']: row for row in json.loads(assets_file.read_text())['assets']}
        active_text = [(beat.get('id'), beat['say'], beat.get('speak')) for lesson in runtime['lessons'] for beat in lesson['beats']]
        published = (active_text == [(unit['id'], unit['displayText'], unit['text']) for unit in units]
                     and len(active_assets) == len(units)
                     and all(active_assets.get(row['id'], {}).get('requestSHA256') == row['requestSHA256'] for row in verified))
    report = {'complete': not missing and not failures, 'profileId': profile['id'],
              'profileSHA256': hashlib.sha256(args.profile.read_bytes()).hexdigest(),
              'inputManifestSHA256': hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
              'model': profile['model'], 'voice': profile['voice'], 'speed': profile['speed'],
              'expectedSegments': len(units), 'verifiedSegments': len(verified),
              'lessons': len(set(unit['lessonId'] for unit in units)),
              'audioSeconds': sum(row['audio']['seconds'] for row in verified),
              'audioBytes': sum(row['audio']['bytes'] for row in verified),
              'missing': missing, 'failures': failures,
              'listeningReview': 'Profile audition approved; individual full-course takes have not all been listened to.',
              'runtimePublication': 'Published in native course resources' if published else 'Not activated'}
    print(json.dumps(report, indent=2))
    if not report['complete']:
        raise SystemExit(1)
    recorder.atomic_write(args.output / 'completion-speed-1.json', (json.dumps(report, indent=2) + '\n').encode())
    recorder.atomic_write(args.output / 'lesson-recordings-speed-1.json', (json.dumps(verified, ensure_ascii=False, indent=2) + '\n').encode())
    sections = []
    for lesson in dict.fromkeys(unit['lessonId'] for unit in units):
        cards = []
        for row in verified:
            if row['id'].split(':')[0] != lesson:
                continue
            cards.append(f'<details><summary>{html.escape(row["id"])}</summary><p>{html.escape(row["request"]["input"])}</p><audio controls preload="none" src="{html.escape(row["file"], quote=True)}"></audio></details>')
        sections.append(f'<section><h2>{html.escape(lesson)}</h2>{"".join(cards)}</section>')
    publication = 'This set is published in the native course resources.' if published else "These recordings have not yet replaced the app's current lesson audio."
    page = '''<!doctype html><html lang="en-GB"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Checkmate Cedar course recordings</title><style>:root{color-scheme:light dark}body{font-family:system-ui;max-width:48rem;margin:2rem auto;padding:0 1rem;line-height:1.5}details{padding:.5rem 0}audio{width:100%}</style>
<h1>Cedar course recordings</h1><p>All lesson clips at speed 1.0. AI-generated audio; playback starts only when you press Play.</p>''' + f'<p>{html.escape(publication)}</p>'
    recorder.atomic_write(args.output / 'course-recordings.html', (page + ''.join(sections) + '</html>').encode())


if __name__ == '__main__':
    main()
