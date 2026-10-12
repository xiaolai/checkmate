"""Enforce Checkmate's dependency direction and native-platform boundaries."""
import json
import pathlib
import re
import sys
import tempfile
import shutil

if not __debug__:
    raise SystemExit("Module checks require Python assertions enabled.")

MODULES = {
    'CheckmateAssets': set(),
    'CheckmateDomain': {'CheckmateAssets'},
    'CheckmateSupport': {'CheckmateDomain', 'CheckmateAssets'},
    'CheckmateRules': {'CheckmateDomain', 'CheckmateAssets', 'CheckmateSupport'},
    'CheckmateEngine': {'CheckmateDomain', 'CheckmateRules', 'CheckmateSupport', 'CheckmateAssets'},
    'CheckmateContent': {'CheckmateDomain', 'CheckmateSupport', 'CheckmateAssets'},
    'CheckmateApplication': {'CheckmateDomain', 'CheckmateRules', 'CheckmateContent', 'CheckmateSupport', 'CheckmateAssets'},
    'CheckmateMacPlatform': {'CheckmateDomain', 'CheckmateRules', 'CheckmateEngine', 'CheckmateContent', 'CheckmateApplication', 'CheckmateSupport', 'CheckmateAssets'},
    'CheckmateCore': {'CheckmateDomain', 'CheckmateRules', 'CheckmateEngine', 'CheckmateContent', 'CheckmateApplication', 'CheckmateMacPlatform', 'CheckmateSupport', 'CheckmateAssets'},
}


def check(root):
    manifest = (root / 'Package.swift').read_text()
    for module, allowed in MODULES.items():
        target = re.search(r'\.target\(name:\s*"' + module + r'"([^\n]*)', manifest)
        assert target, f'Missing module: {module}'
        dependencies = re.search(r'dependencies:\s*\[([^\]]*)\]', target[1])
        assert dependencies, f'{module}: dependencies must be listed on the target line'
        # Every entry counts, not only Checkmate targets: a package product such as MCP is a dependency too.
        products = re.findall(r'\.product\(\s*name:\s*"([^"]+)"', dependencies[1])
        targets = re.findall(r'"([^"]+)"', re.sub(r'\.product\([^)]*\)', '', dependencies[1]))
        actual = set(targets) | {f'product:{name}' for name in products}
        assert actual == allowed, f'{module}: invalid dependency graph {actual ^ allowed}'
        folder = root / 'Sources' / ({'CheckmateAssets': 'CheckmateCore', 'CheckmateCore': 'CheckmateComposition'}.get(module, module))
        files = list(folder.rglob('*.swift') if module != 'CheckmateAssets' else folder.glob('*.swift'))
        assert files, f'Empty module: {module}'
        for source in files:
            text = source.read_text()
            # Attributes, access levels and scoped imports (import class AppKit.NSView) all name the module last.
            imports = set(re.findall(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?'
                                     r'import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)', text, re.M))
            assert not {name for name in imports if name.startswith('Checkmate')} - allowed, f'{source}: forbidden module dependency'
            if module == 'CheckmateDomain':
                assert imports <= {'Foundation', 'CoreFoundation', 'CheckmateAssets'}, f'{source}: platform dependency in domain'
            if module not in {'CheckmateMacPlatform', 'CheckmateCore'}:
                assert not imports & {'AppKit', 'SwiftUI', 'AVFoundation', 'CoreAudio', 'Network', 'Security'}, f'{source}: native service outside adapter'
            if module == 'CheckmateApplication':
                assert not re.search(r'\bNativeEngine\b|\bCompanionBroker\b|\bVoiceAudio\b', text), f'{source}: concrete adapter dependency'
            if module == 'CheckmateCore':
                assert all(not line.strip() or line.startswith('//') or line.startswith('@_exported import ') for line in text.splitlines()), 'Core facade contains implementation'
    assert '"CheckmateNative"' not in re.search(r'\.testTarget\(name:\s*"CheckmateCoreTests"([^\n]*)', manifest)[1], 'Core tests depend on native UI'


def test_rejections(root):
    # Lightweight source-only fixtures: no resources, builds, services or repository mutations.
    with tempfile.TemporaryDirectory(prefix='checkmate-boundaries-') as temporary:
        fixture = pathlib.Path(temporary)
        shutil.copyfile(root / 'Package.swift', fixture / 'Package.swift')
        for module in MODULES:
            folder = {'CheckmateAssets': 'CheckmateCore', 'CheckmateCore': 'CheckmateComposition'}.get(module, module)
            shutil.copytree(root / 'Sources' / folder, fixture / 'Sources' / folder,
                            ignore=shutil.ignore_patterns('Resources'))
        check(fixture)
        def rejects(change):
            path, bad = change
            original = path.read_text()
            path.write_text(bad(original))
            try:
                check(fixture)
            except AssertionError:
                pass
            else:
                raise AssertionError('Boundary check accepted a forbidden dependency')
            finally:
                path.write_text(original)
        rejects((fixture / 'Sources/CheckmateDomain/Errors.swift', lambda text: text + '\n  @preconcurrency import AppKit\n'))
        rejects((fixture / 'Sources/CheckmateApplication/WorkspaceTransitionCoordinator.swift', lambda text: text + '\nimport CheckmateMacPlatform\n'))
        rejects((fixture / 'Package.swift', lambda text: text.replace('name: "CheckmateDomain", dependencies: ["CheckmateAssets"]', 'name: "CheckmateDomain", dependencies: ["CheckmateAssets", "CheckmateApplication"]')))
        rejects((fixture / 'Sources/CheckmateContent/Usage.swift', lambda text: text + '\nimport class AppKit.NSView\n'))
        rejects((fixture / 'Sources/CheckmateApplication/GameSession.swift', lambda text: text + '\n@preconcurrency public import SwiftUI\n'))
        rejects((fixture / 'Package.swift', lambda text: text.replace('name: "CheckmateDomain", dependencies: ["CheckmateAssets"]', 'name: "CheckmateDomain", dependencies: ["CheckmateAssets", .product(name: "MCP", package: "swift-sdk")]')))
        rejects((fixture / 'Sources/CheckmateComposition/Exports.swift', lambda text: text + '\npublic enum HiddenImplementation {}\n'))
        # Training values stay portable: no JavaScriptCore, Combine or native UI in the domain, no engine in workflows.
        rejects((fixture / 'Sources/CheckmateDomain/TrainingGeometry.swift', lambda text: text + '\nimport JavaScriptCore\n'))
        rejects((fixture / 'Sources/CheckmateDomain/TrainingDefinition.swift', lambda text: text + '\nimport Combine\n'))
        rejects((fixture / 'Sources/CheckmateApplication/TrainingProjection.swift', lambda text: text + '\nimport CheckmateEngine\n'))


if __name__ == '__main__':
    root = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
    check(root)
    test_rejections(root)
    print(json.dumps({'passed': True, 'modules': len(MODULES), 'dependencyDirection': True, 'platformIsolation': True}))
