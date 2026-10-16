import argparse, hashlib, json, pathlib, plistlib, re, subprocess
parser = argparse.ArgumentParser(description='Verify a packaged Checkmate app bundle.', allow_abbrev=False)
parser.add_argument('app', type=pathlib.Path)
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--release-identity', action='store_true', help='release build before Developer ID signing: release bundle id and source-commit stamp')
mode.add_argument('--release', action='store_true', help='signed, notarized release: --release-identity plus Developer ID, hardened runtime and timestamp on every executable')
arguments = parser.parse_args()
app = arguments.app
release_identity = arguments.release or arguments.release_identity
RELEASE_BUNDLE_ID = 'ai.xiaolai.checkmate'
root = pathlib.Path(__file__).resolve().parents[1]
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('CFBundlePackageType') != 'APPL':
    raise RuntimeError('Bundle must declare application package type APPL')
settings = dict(line.split('=', 1) for line in (root / 'Version.env').read_text().splitlines() if '=' in line)
if not info['LSMinimumSystemVersion'] == settings['CHECKMATE_MINIMUM_MACOS']:
    raise RuntimeError('Package verification failed')
# build.sh writes these from Version.env; a mismatch means the bundle was built from another tree or version.
if info.get('CFBundleShortVersionString') != settings['CHECKMATE_VERSION'] or info.get('CFBundleVersion') != settings['CHECKMATE_BUILD_NUMBER']:
    raise RuntimeError(f"Bundle version {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')}) differs from Version.env {settings['CHECKMATE_VERSION']} ({settings['CHECKMATE_BUILD_NUMBER']})")
microphone = info.get('NSMicrophoneUsageDescription')
if not (isinstance(microphone, str) and microphone.strip()):
    raise RuntimeError('NSMicrophoneUsageDescription missing: macOS would terminate the app when the voice coach opens the microphone')
# Release and development identities keep separate data, MCP registration and microphone permission.
bundle_id = info.get('CFBundleIdentifier', '')
if release_identity:
    if bundle_id != RELEASE_BUNDLE_ID:
        raise RuntimeError(f'Release bundle identifier must be {RELEASE_BUNDLE_ID}, not {bundle_id!r}')
    if not re.fullmatch(r'[0-9a-f]{40}', info.get('CheckmateSourceCommit', '')):
        raise RuntimeError('Release Info.plist lacks the CheckmateSourceCommit stamp (scripts/release.sh passes it to the build)')
elif not bundle_id.startswith(RELEASE_BUNDLE_ID + '.'):
    raise RuntimeError(f'A non-release build must use its own {RELEASE_BUNDLE_ID}.* identifier, not {bundle_id!r}')
# LAN play (plan D11, D12): without the usage text macOS refuses local-network access, and each build kind
# advertises and browses only its own Bonjour service type.
local_network = info.get('NSLocalNetworkUsageDescription')
if not (isinstance(local_network, str) and local_network.strip()):
    raise RuntimeError('NSLocalNetworkUsageDescription missing: macOS would refuse Play on Network')
expected_service = '_checkmate._tcp' if bundle_id == RELEASE_BUNDLE_ID else '_checkmate-auto._tcp' if 'automation' in bundle_id else '_checkmate-dev._tcp'
if info.get('NSBonjourServices') != [expected_service]:
    raise RuntimeError(f"NSBonjourServices must be [{expected_service!r}] for {bundle_id}, found {info.get('NSBonjourServices')!r}")
if not info.get('CFBundleIconName') == 'Checkmate':
    raise RuntimeError('Package verification failed')
legacy_icon = info.get('CFBundleIconFile', '')
if not legacy_icon or not (app / 'Contents/Resources' / legacy_icon).is_file():
    raise RuntimeError('Legacy macOS icon fallback missing')
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
if bundle.name != 'Checkmate_CheckmateAssets.bundle':
    raise RuntimeError('Resource bundle belongs to a retired target')
resources = bundle / 'Contents/Resources/Resources'
if not resources.is_dir():
    resources = bundle / 'Resources'
course = json.loads((resources / 'course.json').read_text())
if not (len(course['lessons']) == 39 and len(course['puzzles']) == 82):
    raise RuntimeError(f"Bundled course has {len(course['lessons'])} lessons and {len(course['puzzles'])} puzzles, not 39 and 82")
for lesson in course['voices']:
    for voice in lesson:
        if not (resources / voice['file']).is_file():
            raise RuntimeError(voice['file'])
if not (course['narration']['voice'] == 'cedar' and course['narration']['speed'] == 1.0):
    raise RuntimeError('Package verification failed')
narration = json.loads((resources / course['narration']['manifest']).read_text())
if not narration['assetSetSHA256'] == course['narration']['assetSetSHA256']:
    raise RuntimeError('Package verification failed')
if course['exercises'] or any('quiz' in beat for lesson in course['lessons'] for beat in lesson['beats']):
    raise RuntimeError('Embedded lesson quizzes must not be bundled')
if not len(narration['assets']) == 710:
    raise RuntimeError(f"Bundled narration lists {len(narration['assets'])} clips, not 710")
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
for file in ['stockfish', 'chess.js', 'chess-LICENSE', 'Stockfish-COPYING.txt', 'Checkmate-COPYING.txt', 'THIRD_PARTY_NOTICES.txt', 'voice-tools.json', 'coach-instructions.txt']:
    if not (resources / file).is_file():
        raise RuntimeError(file)
# The notices point to Licenses/ for every resolved Swift package; each pin needs its license text.
for pin in json.loads((root / 'Package.resolved').read_text())['pins']:
    license_text = resources / 'Licenses' / f"{pin['identity']}.txt"
    if not (license_text.is_file() and license_text.stat().st_size > 0):
        raise RuntimeError(f'License text missing for {pin["identity"]}: {license_text.name}')
engine = json.loads((resources / 'stockfish-build.json').read_text())
if not hashlib.sha256((resources / 'stockfish').read_bytes()).hexdigest() == engine['binarySHA256']:
    raise RuntimeError('Package verification failed')
if not hashlib.sha256((resources / engine['networkFile']).read_bytes()).hexdigest() == engine['networkSHA256']:
    raise RuntimeError('Package verification failed')
if not (engine['algorithmChanges'] is False and engine['networkChanged'] is False):
    raise RuntimeError('Package verification failed')
libraries = subprocess.check_output(['otool', '-L', str(resources / 'stockfish')], text=True)
for dependency in libraries.splitlines()[1:]:
    if not dependency.startswith('\t'): continue
    path = dependency.strip().split(' (', 1)[0]
    if not path.startswith(('/usr/lib/', '/System/Library/')):
        raise RuntimeError(f'Non-system engine dependency: {path}')
helper = app / 'Contents/MacOS/CheckmateMCP'
if not helper.is_file():
    raise RuntimeError('Native companion missing')
for line in subprocess.check_output(['otool', '-L', str(helper)], text=True).splitlines()[1:]:
    if not line.startswith('\t'): continue
    if not line.strip().split(' (', 1)[0].startswith(('/usr/lib/', '/System/Library/')):
        raise RuntimeError('Non-system companion runtime dependency')
executable = app / 'Contents/MacOS/CheckmateNative'
def version_key(text):
    parts = [int(part) for part in text.split('.')]
    while parts and parts[-1] == 0:
        parts.pop()  # 14.0 and 14.0.0 are the same release
    return tuple(parts)
def deployment_targets(binary, architecture):
    """Every macOS deployment version one slice records: LC_BUILD_VERSION minos, or legacy LC_VERSION_MIN_MACOSX version."""
    # Without -arch, otool prints only the host's slice of a universal binary, so the other slice would go unchecked.
    found, command = [], None
    for line in subprocess.check_output(['otool', '-arch', architecture, '-l', str(binary)], text=True).splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        if fields[0] == 'cmd':
            command = fields[1]
        elif (command, fields[0]) in {('LC_BUILD_VERSION', 'minos'), ('LC_VERSION_MIN_MACOSX', 'version')}:
            found.append(fields[1])
    return found
minimum = version_key(settings['CHECKMATE_MINIMUM_MACOS'])
for binary in (executable, helper, resources / 'stockfish'):
    architectures = set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split())
    if architectures != {'arm64', 'x86_64'}:
        raise RuntimeError(f'Universal architecture missing: {binary.name}')
    # All runtime slices must be deployable on the advertised minimum OS; a slice with no record proves nothing.
    for architecture in sorted(architectures):
        targets = deployment_targets(binary, architecture)
        if not targets:
            raise RuntimeError(f'{binary.name} ({architecture}) records no macOS deployment target')
        for target in targets:
            if version_key(target) > minimum:
                raise RuntimeError(f'{binary.name} ({architecture}) requires macOS {target}')
links = subprocess.check_output(['otool', '-L', str(executable)], text=True)
if not ('WebKit' not in links):
    raise RuntimeError('Package verification failed')
verification = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True, text=True)
if verification.returncode != 0:
    raise RuntimeError(f'codesign --verify --deep --strict failed: {verification.stderr.strip()}')
if arguments.release:
    def entitlements(code):
        raw = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(code)], stderr=subprocess.DEVNULL)
        return plistlib.loads(raw) if raw.strip() else {}
    if entitlements(app).get('com.apple.security.device.audio-input') is not True:
        raise RuntimeError('Release must allow audio input')
    # Notarization requires these for nested code as well; checking each executable keeps a regression visible here.
    for code in (app, helper, resources / 'stockfish'):
        signature = subprocess.run(['codesign', '-d', '--verbose=4', str(code)], capture_output=True, text=True, check=True).stderr
        flags = re.search(r'^CodeDirectory .*\bflags=0x([0-9a-fA-F]+)', signature, re.MULTILINE)
        if not (flags and int(flags.group(1), 16) & 0x10000 and 'Timestamp=' in signature and 'Authority=Developer ID Application: ' in signature):
            raise RuntimeError(f'{code.name} must carry a Developer ID signature with hardened runtime and a secure timestamp')
        if entitlements(code).get('com.apple.security.get-task-allow'):
            raise RuntimeError(f'{code.name} must exclude debugger access')
# Every flag is a passed check: the acceptance aggregate rejects any false value.
print(json.dumps({'passed': True, 'iconFormat': 'Icon Composer with legacy fallback', 'architectures': ['arm64', 'x86_64'], 'minimumMacOS': settings['CHECKMATE_MINIMUM_MACOS'], 'deploymentTargetsVerifiedPerSlice': True, 'bundleIdentifier': bundle_id, 'version': settings['CHECKMATE_VERSION'], 'build': settings['CHECKMATE_BUILD_NUMBER'], 'lessons': len(course['lessons']), 'audioFiles': len(narration['assets']), 'narrationVoice': 'cedar', 'audioHashesVerified': True, 'puzzles': len(course['puzzles']), 'webRuntimeAbsent': True, 'engineHasSystemDependenciesOnly': True}))
