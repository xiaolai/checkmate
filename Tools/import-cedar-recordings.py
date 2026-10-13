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


def reusable_asset(cache, master, encoding):
    """Reuse only the exact recording and encoding, even across asset sets."""
    if cache.get('audioEncoding') != encoding:
        return None
    candidate = next((a for a in cache.get('assets', []) if a['id'] == master['id']), None)
    if candidate and candidate['requestSHA256'] == master['requestSHA256'] and candidate['masterSHA256'] == master['audioSHA256'] and candidate['textSHA256'] == master['textSHA256']:
        return candidate
    return None


def build_course(sounds, content, assets, timing, version):
    result = {'schemaVersion': 1, 'lessons': copy.deepcopy(content['lessons']), 'voices': [],
              'exercises': content['exercises'], 'puzzles': content['puzzles'], 'stepTitles': [], 'frames': [],
              'sounds': sounds, 'retiredExerciseIDs': content['retiredExerciseIDs'], 'timing': timing}
    prep = module('prepare', 'prepare-lesson-scripts.py')
    phrases, all_cues = authored_cues()
    for li, lesson in enumerate(content['lessons']):
        voices = []
        result['frames'].append(prep.lesson_frames(lesson))
        for step, beat in enumerate(lesson['beats']):
            asset = assets[beat['id']]
            published = result['lessons'][li]['beats'][step]
            cues = all_cues.get(beat['id'])
            assert cues or 'stages' not in beat, 'A staged beat needs aligned anchor phrases: ' + beat['id']
            if cues:
                assert cues['textSHA256']==asset['textSHA256'], 'Stale action cue text: '+beat['id']
                assert cues['masterSHA256']==asset['masterSHA256'], 'Stale action cue recording: '+beat['id']
                assert cues.get('anchorsSHA256')==prep.anchor_identity(phrases[beat['id']]), 'Stale action cue anchors: '+beat['id']
                fractions=cues['fractions']
                assert all(type(x) in (float,int) and math.isfinite(x) and 0<=x<=1 for x in fractions) and fractions==sorted(fractions), 'Invalid action cue timing: '+beat['id']
                if 'stages' in beat:
                    # Stage 0 shows from the start; each later stage when its anchor is spoken.
                    assert len(fractions)==len(beat['stages'])-1 and all(0<x<1 for x in fractions) and len(set(fractions))==len(fractions), 'Invalid stage cue timing: '+beat['id']
                    published['stageCues']=fractions
                else:
                    assert len(fractions)==len(beat.get('moves',[])), 'Invalid action cue timing: '+beat['id']
                    published['moveCues']=fractions
            timed_beat=result['lessons'][li]['beats'][step]
            voices.append({'file': asset['file'], 'seconds': asset['seconds'],
                           'duration': step_duration(timed_beat, asset['seconds'], timing)})
            # Every retained segment starts from its authored illustration, even
            # when the removed question supplied the previous board setup.
            start = result['frames'][li][step]['start']
            runtime_beat = result['lessons'][li]['beats'][step]
            end = result['frames'][li][step]['end']
            runtime_beat.update(set=start.get('board'), hl=end.get('hl', []),
                                arrows=end.get('arrows', []), big=start['big'])
            # Guards are published only where there are some; a beat without them draws none.
            runtime_beat.pop('guards', None)
            if end.get('guards'):
                runtime_beat['guards'] = end['guards']
            if 'stages' in runtime_beat:
                runtime_beat['stages'] = [{kind: stage.get(kind, []) for kind in prep.OVERLAYS} for stage in runtime_beat['stages']]
            # The step label is published once, in stepTitles.
            del runtime_beat['label']
        stage_overlays(result['frames'][li], result['lessons'][li]['beats'])
        result['voices'].append(voices)
        result['stepTitles'].append([beat['label'] for beat in lesson['beats']])
    result['narration'] = version
    return result


def authored_cues():
    """The authored anchor phrases and the cues aligned from them. Every phrase list has its cue and every cue its
    phrases, so a beat never falls back to paced timing because an alignment is missing."""
    phrases = json.loads((ROOT / 'Content/lesson-action-phrases.json').read_text())['phrases']
    cues = json.loads((ROOT / 'Content/lesson-action-cues.json').read_text())['cues']
    assert set(phrases) == set(cues), 'Anchor phrases and aligned cues differ: ' + ', '.join(sorted(set(phrases) ^ set(cues)))
    return phrases, cues


def build_projections(content, runtime):
    """The agent-facing projection of every lesson step: a paused lesson showing the step's starting board."""
    return [[{'mode': 'lesson', 'lessonId': lesson['id'], 'title': lesson['title'], 'step': step,
              'pieces': runtime['frames'][li][step]['start'].get('board'), 'playing': False,
              'narrationActive': False, 'moving': False} for step in range(len(lesson['beats']))]
            for li, lesson in enumerate(content['lessons'])]


def stage_overlays(frames, beats):
    """Make each start frame what shows when the beat begins.

    A beat's arrows and highlights describe the position its moves produce. Until the last move lands, only what the
    previous beat left up stays, with arrows previewing the beat's moves (`move_previews`). A guard shows from the first
    board on which it shows what it shows at the end (`guard_reveal`). A staged beat begins with its first stage.
    Course.frame applies the same rules over time, and the native course tests compare the two.
    """
    prep = module('prepare', 'prepare-lesson-scripts.py')
    previous = {}
    for frame, beat in zip(frames, beats):
        shown, start = frame['end'], frame['start']
        if beat.get('stages'):
            for kind in prep.OVERLAYS:
                start[kind] = copy.deepcopy(beat['stages'][0].get(kind, []))
        if beat.get('moves'):
            previews = prep.move_previews(start.get('board'), beat)
            start['arrows'] = [a for a in shown.get('arrows', []) if a in previous.get('arrows', []) or a in previews]
            start['hl'] = [h for h in shown.get('hl', []) if h in previous.get('hl', [])]
        if shown.get('guards') and (beat.get('moves') or beat.get('remove')):
            boards = prep.beat_boards(start.get('board'), beat)
            start['guards'] = [g for g in shown.get('guards', []) if prep.guard_reveal(boards, g) == 0]
        previous = shown


def asset_set_identity(masters, config):
    """The asset set is named by what it holds: a retake of unchanged text keeps its request but not its audio, so
    the master hashes are part of the name, or a retake would collide with the immutable set it replaces."""
    return hashlib.sha256(encoded([[r['requestSHA256'], r['audioSHA256']] for r in masters]) + encoded(config)).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recordings', type=Path, default=ROOT / 'recordings/cedar')
    args = parser.parse_args()
    if not socket.gethostname().lower().startswith('build-host') and 'build-host' not in socket.gethostname().lower():
        parser.error('Run the native recording import on build-host only')
    prep = module('prepare', 'prepare-lesson-scripts.py')
    verifier = module('verifier', 'verify-lesson-recordings.py')
    recorder = verifier.recorder
    sounds = json.loads((ROOT / 'Content/course-sounds.json').read_text())['sounds']
    content = json.loads(prep.CONTENT.read_text())
    prep.validate(content)
    for name, expected in prep.outputs(content).items():
        assert (ROOT / 'Content' / name).read_text() == expected, 'Stale editorial export: ' + name
    profile = json.loads((ROOT / 'Content/narration-profile.cedar.json').read_text())
    config = json.loads((ROOT / 'Content/narration-packaging.json').read_text())
    units = recorder.load_units(ROOT / 'Content/lesson-narration.en-GB.jsonl')
    masters, missing, failures = verifier.verify(profile, units, args.recordings)
    assert not missing and not failures, 'Incomplete or invalid recordings; run the verifier'
    # Every master must be heard saying its whole text, its ending and its squares (Tools/check-narration-coverage.py).
    coverage = module('coverage', 'check-narration-coverage.py')
    unheard = [m['id'] for m in masters if not coverage.passing(args.recordings, m)]
    assert not unheard, 'No passing coverage check for: ' + ', '.join(unheard[:20]) + '; run Tools/check-narration-coverage.py'
    identity = asset_set_identity(masters, config)
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
        runtime = build_course(sounds, content, assets, config['timing'], version)
        projections = build_projections(content, runtime)
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
                          'compressedBytes': sum(a['bytes'] for a in assets.values())}, indent=2))
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == '__main__':
    main()
