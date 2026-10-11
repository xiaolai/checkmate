#!/usr/bin/env python3
"""Publish verified Cedar assets and matching native course text/timing on build-host.

Runs no API calls or audio playback. Builds assets first and swaps course.json
only after all compressed clips decode and pass provenance checks.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import math
import os
import shutil
import socket
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Sources/CheckmateCore/Resources'


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Tools' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def step_duration(beat, audio_seconds, timing):
    count = len(beat.get('moves', []))
    fractions=beat.get('moveCues', [(0.05 if count==1 else (i+0.15)/count) for i in range(count)])
    previous=-timing['pieceDuration']
    for fraction in fractions:
        previous=max(timing['movementStart'],fraction*audio_seconds,previous+timing['pieceDuration'])
    animation=previous+timing['pieceDuration'] if count else 0
    if beat.get('remove'):
        animation += timing['removalDelay']
    counts = max(0, len(beat.get('count', [])) - 1) * timing['minimumCountSpacing']
    seconds = max(audio_seconds, animation, counts) + beat.get('pause', 0) + timing['postNarrationGap']
    return math.ceil(seconds * timing['frameRate']) / timing['frameRate']


def short_label(text):
    text = ' '.join(text.split())
    if len(text) <= 32:
        return text
    prefix = text[:31]
    return prefix[:prefix.rfind(' ')] + '…' if ' ' in prefix else prefix + '…'


def reusable_asset(cache, master, encoding):
    """Reuse only the exact recording and encoding, even across asset sets."""
    if cache.get('audioEncoding') != encoding:
        return None
    candidate = next((a for a in cache.get('assets', []) if a['id'] == master['id']), None)
    if candidate and candidate['requestSHA256'] == master['requestSHA256'] and candidate['masterSHA256'] == master['audioSHA256'] and candidate['textSHA256'] == master['textSHA256']:
        return candidate
    return None


def build_course(baseline, content, assets, timing, version):
    result = copy.deepcopy(baseline)
    result['lessons'] = copy.deepcopy(content['lessons'])
    result['exercises'] = content['exercises']
    result['retiredExerciseIDs'] = content['retiredExerciseIDs']
    result['puzzles'] = content['puzzles']
    result['timing'] = timing
    result['voices'] = []
    result['stepTitles'] = []
    result['frames'] = []
    prep = module('prepare', 'prepare-lesson-scripts.py')
    for li, lesson in enumerate(content['lessons']):
        voices = []
        source_steps = [int(b['id'].rsplit(':', 1)[1]) for b in lesson['beats']]
        result['frames'].append([prep.reference_frame(baseline, content, li, beat) for beat in lesson['beats']])
        for step, beat in enumerate(lesson['beats']):
            asset = assets[beat['id']]
            cue_file=ROOT / 'Content/lesson-action-cues.json'
            cues=json.loads(cue_file.read_text()).get('cues',{}).get(beat['id']) if cue_file.exists() else None
            if cues:
                assert cues['textSHA256']==asset['textSHA256'], 'Stale action cue text: '+beat['id']
                assert cues['masterSHA256']==asset['masterSHA256'], 'Stale action cue recording: '+beat['id']
                assert len(cues['fractions'])==len(beat.get('moves',[])) and all(isinstance(x,(float,int)) and math.isfinite(x) and 0<=x<=1 for x in cues['fractions']) and cues['fractions']==sorted(cues['fractions']), 'Invalid action cue timing: '+beat['id']
                result['lessons'][li]['beats'][step]['moveCues']=cues['fractions']
            timed_beat=result['lessons'][li]['beats'][step]
            voices.append({'file': asset['file'], 'seconds': asset['seconds'],
                           'duration': step_duration(timed_beat, asset['seconds'], timing)})
            # Every retained segment starts from its authored illustration, even
            # when the removed question supplied the previous board setup.
            start = result['frames'][li][step]['start']
            runtime_beat = result['lessons'][li]['beats'][step]
            runtime_beat.update(set=start.get('board'), hl=start.get('hl', []),
                                arrows=start.get('arrows', []), big=start.get('big', ''))
            for endpoint in ('start', 'end'):
                if 'quiz' in result['frames'][li][step][endpoint].get('big', '').lower():
                    result['frames'][li][step][endpoint]['big'] = ''
            if 'quiz' in runtime_beat['big'].lower():
                runtime_beat['big'] = ''
        result['voices'].append(voices)
        # Preserve the four curated navigation sequences; refresh later labels.
        titles = [baseline['stepTitles'][li][i] if i<len(baseline['stepTitles'][li]) else short_label(lesson['beats'][step]['say']) for step,i in enumerate(source_steps)] if li < 4 else [short_label(lesson['title'] if step == 0 else beat.get('big') or beat['say']) for step, beat in enumerate(lesson['beats'])]
        result['stepTitles'].append(titles)
    result['narration'] = version
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recordings', type=Path, default=ROOT / 'recordings/cedar')
    args = parser.parse_args()
    if not socket.gethostname().lower().startswith('build-host') and 'build-host' not in socket.gethostname().lower():
        parser.error('Run the native recording import on build-host only')
    prep = module('prepare', 'prepare-lesson-scripts.py')
    verifier = module('verifier', 'verify-lesson-recordings.py')
    recorder = verifier.recorder
    baseline = json.loads(prep.SOURCE.read_text())
    content = json.loads(prep.CONTENT.read_text())
    prep.validate(content, baseline)
    for name, expected in prep.outputs(content).items():
        assert (ROOT / 'Content' / name).read_text() == expected, 'Stale editorial export: ' + name
    profile = json.loads((ROOT / 'Content/narration-profile.cedar.json').read_text())
    config = json.loads((ROOT / 'Content/narration-packaging.json').read_text())
    units = recorder.load_units(ROOT / 'Content/lesson-narration.en-GB.jsonl')
    masters, missing, failures = verifier.verify(profile, units, args.recordings)
    assert not missing and not failures, 'Incomplete or invalid recordings; run the verifier'
    identity = hashlib.sha256(encoded([r['requestSHA256'] for r in masters]) + encoded(config)).hexdigest()
    relative = Path('course') / ('cedar-' + identity[:12])
    destination = RESOURCES / relative
    manifest_file = RESOURCES / 'course-narration.json'
    cache = json.loads(manifest_file.read_text()) if manifest_file.exists() else {}
    ROOT.joinpath('build').mkdir(exist_ok=True)
    probe = ROOT / 'build/audio-probe'
    subprocess.run(['xcrun', 'swiftc', str(ROOT / 'Tools/audio-probe.swift'), '-o', str(probe)], check=True)
    stage = Path(tempfile.mkdtemp(prefix='cedar-import-', dir=ROOT / 'build'))
    try:
        def convert(master):
            lesson, step = master['id'].rsplit(':', 1)
            file = Path(lesson) / (f'{int(step):02d}.m4a')
            output = stage / file
            output.parent.mkdir(parents=True, exist_ok=True)
            cached = reusable_asset(cache, master, config['audio'])
            existing = RESOURCES / cached['file'] if cached else destination / file
            if cached and existing.exists() and recorder.digest(existing.read_bytes()) == cached['audioSHA256']:
                shutil.copyfile(existing, output)
            else:
                subprocess.run(['/usr/bin/afconvert', '-f', config['audio']['format'], '-d', config['audio']['codec'],
                                '-b', str(config['audio']['bitrate']), str(args.recordings / master['file']), str(output)],
                               check=True, capture_output=True)
            return master, file, output
        with ThreadPoolExecutor(max_workers=config['audio']['jobs']) as executor:
            converted = list(executor.map(convert, masters))
        paths = stage / 'probe-input.json'
        paths.write_bytes(encoded([str(output) for _, _, output in converted]))
        measurements = json.loads(subprocess.check_output([str(probe), str(paths)]))
        paths.unlink()
        assets = {}
        for (master, file, output), measured in zip(converted, measurements):
            assert measured['file'] == str(output)
            assert abs(measured['seconds'] - master['audio']['seconds']) < 0.15, 'Encoding changed duration: ' + master['id']
            assets[master['id']] = {'id': master['id'], 'file': str(relative / file),
                                  'seconds': measured['seconds'], 'textSHA256': master['textSHA256'],
                                  'requestSHA256': master['requestSHA256'], 'masterSHA256': master['audioSHA256'],
                                  'audioSHA256': recorder.digest(output.read_bytes()), 'bytes': output.stat().st_size,
                                  'decodedFrames': measured['frames'], 'sampleRate': measured['sampleRate'],
                                  'channels': measured['channels'], 'peak': measured['peak']}
        version = {'provider': profile['provider'], 'voice': profile['voice'], 'model': profile['model'],
                   'speed': profile['speed'], 'locale': content['locale'], 'assetSetSHA256': identity,
                   'aiGenerated': True, 'manifest': 'course-narration.json'}
        runtime = build_course(baseline, content, assets, config['timing'], version)
        projections = json.loads((ROOT / 'Content/projections-baseline.json').read_text())
        for li, lesson in enumerate(content['lessons']):
            projections[li] = [copy.deepcopy(projections[li][int(b['id'].rsplit(':', 1)[1])]) if int(b['id'].rsplit(':',1)[1])<len(projections[li]) else {'mode':'lesson','lessonId':lesson['id'],'title':lesson['title'],'playing':False,'narrationActive':False,'moving':False} for b in lesson['beats']]
            for step, projection in enumerate(projections[li]):
                projection['step'] = step
                projection['pieces'] = runtime['frames'][li][step]['start'].get('board')
        provenance = dict(version, schemaVersion=1, audioEncoding=config['audio'], assets=list(assets.values()))
        # Preserve the old resource set once, before replacing active references.
        backup = ROOT / 'build/course-before-cedar'
        if not backup.exists():
            backup.mkdir()
            for name in ('course.json', 'projections.json'):
                shutil.copyfile(RESOURCES / name, backup / name)
            legacy = RESOURCES / 'course/voice'
            if legacy.exists():
                shutil.copytree(legacy, backup / 'voice')
        if destination.exists():
            assert {str(p.relative_to(destination)) for p in destination.rglob('*.m4a')} == {str(file) for _, file, _ in converted}
            for _, file, output in converted:
                assert recorder.digest((destination / file).read_bytes()) == recorder.digest(output.read_bytes())
            shutil.rmtree(stage)
        else:
            os.replace(stage, destination)
        recorder.atomic_write(manifest_file, encoded(provenance))
        recorder.atomic_write(RESOURCES / 'projections.json', encoded(projections))
        recorder.atomic_write(RESOURCES / 'course.json', encoded(runtime))
        # A newly selected recording set replaces the previous bundled set.
        # Keep its assets in the ignored publication backup before removing
        # unreferenced clips from the distributable resources.
        previous_sets = {Path(*Path(a['file']).parts[:2]) for a in cache.get('assets', [])}
        for previous in previous_sets:
            if previous.parent != Path('course') or not previous.name.startswith('cedar-') or previous == relative:
                continue
            old = RESOURCES / previous
            if old.exists():
                archived = backup / previous
                if not archived.exists():
                    shutil.copytree(old, archived)
                shutil.rmtree(old)
        # Old takes are backed up and no longer referenced by the native course.
        legacy = RESOURCES / 'course/voice'
        if legacy.exists():
            assert all(not row['file'].startswith('course/voice/') for rows in runtime['voices'] for row in rows)
            shutil.rmtree(legacy)
        content['publicationState'] = 'published'
        recorder.atomic_write(prep.CONTENT, encoded(content))
        for name, text in prep.outputs(content).items():
            recorder.atomic_write(ROOT / 'Content' / name, text.encode())
        print(json.dumps({'published': True, 'lessons': len(runtime['lessons']), 'clips': len(assets),
                          'voice': profile['voice'], 'speed': profile['speed'], 'assetDirectory': str(relative),
                          'audioSeconds': sum(a['seconds'] for a in assets.values()),
                          'compressedBytes': sum(a['bytes'] for a in assets.values()),
                          'savedProgressMappingPreserved': True}, indent=2))
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == '__main__':
    main()
