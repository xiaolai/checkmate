import hashlib, json, pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('CFBundlePackageType') != 'APPL':
    raise RuntimeError('Bundle must declare application package type APPL')
if not info['LSMinimumSystemVersion'] == '27.0':
    raise RuntimeError('Package verification failed')
if not info.get('CFBundleIconName') == 'Checkmate':
    raise RuntimeError('Package verification failed')
if not 'CFBundleIconFile' not in info:
    raise RuntimeError('Package verification failed')
catalog = app / 'Contents/Resources/Assets.car'
if not (catalog.is_file() and catalog.stat().st_size > 0):
    raise RuntimeError('Package verification failed')
icon_assets = json.loads(subprocess.check_output(['xcrun', 'assetutil', '--info', str(catalog)], text=True))
if not any((item.get('AssetType') == 'IconImageStack' for item in icon_assets)):
    raise RuntimeError('Icon Composer layers missing')
bundles = list((app / 'Contents/Resources').glob('*.bundle'))
if not len(bundles) == 1:
    raise RuntimeError('Expected exactly one resource bundle')
bundle = bundles[0]
resources = bundle / 'Contents/Resources/Resources'
if not resources.is_dir():
    resources = bundle / 'Resources'
course = json.loads((resources / 'course.json').read_text())
if not (len(course['lessons']) == 40 and len(course['puzzles']) == 87):
    raise RuntimeError('Package verification failed')
for lesson in course['voices']:
    for voice in lesson:
        if not (resources / voice['file']).is_file():
            raise RuntimeError(voice['file'])
if not (course['narration']['voice'] == 'cedar' and course['narration']['speed'] == 1.0):
    raise RuntimeError('Package verification failed')
narration = json.loads((resources / course['narration']['manifest']).read_text())
if not narration['assetSetSHA256'] == course['narration']['assetSetSHA256']:
    raise RuntimeError('Package verification failed')
if not len(narration['assets']) == 947:
    raise RuntimeError('Package verification failed')
assets = {row['file']: row for row in narration['assets']}
for li, lesson in enumerate(course['voices']):
    for step, voice in enumerate(lesson):
        asset = assets[voice['file']]
        beat = course['lessons'][li]['beats'][step]
        if not asset['id'] == beat['id']:
            raise RuntimeError('Package verification failed')
        if not hashlib.sha256(beat['speak'].encode()).hexdigest() == asset['textSHA256']:
            raise RuntimeError('Package verification failed')
        if not hashlib.sha256((resources / voice['file']).read_bytes()).hexdigest() == asset['audioSHA256']:
            raise RuntimeError(voice['file'])
        if not (voice['seconds'] == asset['seconds'] and voice['duration'] >= voice['seconds'] + course['timing']['postNarrationGap']):
            raise RuntimeError('Package verification failed')
if not set(assets) == {str(p.relative_to(resources)) for p in (resources / 'course').rglob('*.m4a')}:
    raise RuntimeError('Obsolete or missing bundled clips')
for file in ['stockfish', 'chess.js', 'chess-LICENSE', 'Stockfish-COPYING.txt', 'THIRD_PARTY_NOTICES.txt', 'voice-tools.json', 'coach-instructions.txt']:
    if not (resources / file).is_file():
        raise RuntimeError(file)
engine = json.loads((resources / 'stockfish-build.json').read_text())
if not hashlib.sha256((resources / 'stockfish').read_bytes()).hexdigest() == engine['binarySHA256']:
    raise RuntimeError('Package verification failed')
if not hashlib.sha256((resources / engine['networkFile']).read_bytes()).hexdigest() == engine['networkSHA256']:
    raise RuntimeError('Package verification failed')
if not (engine['algorithmChanges'] is False and engine['networkChanged'] is False):
    raise RuntimeError('Package verification failed')
libraries = subprocess.check_output(['otool', '-L', str(resources / 'stockfish')], text=True)
for dependency in libraries.splitlines()[1:]:
    path = dependency.strip().split(' (', 1)[0]
    if not path.startswith(('/usr/lib/', '/System/Library/')):
        raise RuntimeError(f'Non-system engine dependency: {path}')
executable = app / 'Contents/MacOS/CheckmateNative'
links = subprocess.check_output(['otool', '-L', str(executable)], text=True)
if not ('WebKit' not in links):
    raise RuntimeError('Package verification failed')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
if '--release' in sys.argv:
    entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
    if entitlements.get('com.apple.security.device.audio-input') is not True or entitlements.get('com.apple.security.get-task-allow'):
        raise RuntimeError('Release must allow audio input and exclude debugger access')
    signature = subprocess.run(['codesign', '-d', '--verbose=4', str(app)], capture_output=True, text=True, check=True).stderr
    if '(runtime)' not in signature or 'Timestamp=' not in signature:
        raise RuntimeError('Release must use hardened runtime and a secure timestamp')
print(json.dumps({'passed': True, 'iconFormat': 'Icon Composer', 'lessons': 40, 'audioFiles': 947, 'narrationVoice': 'cedar', 'audioHashesVerified': True, 'puzzles': 87, 'webRuntime': False, 'engineHasSystemDependenciesOnly': True}))
