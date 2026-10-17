"""Every engine and voice-coach entry is classified for network-game fairness (LAN-play plan D8, R4-5).

The scan lists each call site of an EngineService method (prepare(), analyze(fen:), analyzeHistory(startFEN:)) and each
VoiceCoach request entry (`request(` in VoiceCoach.swift), as file + enclosing function + number of calls. Every site
must appear in Tests/fairness-inventory.json as one of:
  guarded    the enclosing function checks FairnessPolicy itself, before its first such call;
  delegated  a helper called only by its listed callers, each of which checks FairnessPolicy before calling it; before
             each of the helper's calls that follows an earlier `await`, it checks FairnessPolicy again (R5-2);
  exempt     a stated reason, such as the package check, which runs no session;
  assisted   the network game's own hints (assistance plan A8), allowed only in NetworkAssistant.swift: the function
             checks FairnessPolicy.requireNetworkHint() before its first call and again after its last, and gives a
             reason. The scoped check cannot classify any other site, so practice, Review and MCP stay closed.
  voice      a voice-coach turn entry (assistance plan A10), allowed only in VoiceCoach.swift: the function checks
             FairnessPolicy.voiceAllowed(network:) before its first call and gives a reason. That check is D8's for a
             practice session and the learner's agreed level for a network session, so no engine site can use it.
A new call site, in a new function or as one more call in a listed one, fails until it is classified; so does an entry
whose site is gone. The self-test copies the sources, adds unguarded calls to a listed file and requires failures.
"""
import json
import pathlib
import re
import shutil
import sys
import tempfile

if not __debug__:
    raise SystemExit("The fairness inventory needs Python assertions enabled.")

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENGINE_CALL = re.compile(r'\.analyze\(fen:|(?<!func )\banalyzeHistory\(startFEN:|\b\w*[Ee]ngine\)?\??\.prepare\(\)')
VOICE_CALL = re.compile(r'(?<![.\w])(?<!func )request\(')
CHECK = re.compile(r'fairness\.(?:engineHelpAllowed|requireEngineHelp\(\))')
ASSIST_CHECK = re.compile(r'fairness\.requireNetworkHint\(\)')
ASSIST_FILES = {'Sources/CheckmateApplication/NetworkAssistant.swift'}
VOICE_CHECK = re.compile(r'fairness\.voiceAllowed\(network:')
VOICE_FILES = {'Sources/CheckmateMacPlatform/VoiceCoach.swift'}
DECLARATION = re.compile(r'\bfunc\s+(\w+)|\b(init)\s*[(<]|\bvar\s+(\w+)\s*:[^={\n]*\{')
NO_BODY = re.compile(r'(?:func|var|let|init|case|struct|class|enum|extension)\b|\}')


def blank(text):
    """Comments and string literals become spaces of the same length (newlines kept), so offsets stay valid and nothing
    inside a string or comment counts as code; interpolations are blanked with their string."""
    out, i, n = list(text), 0, len(text)

    def clear(a, b):
        out[a:b] = [c if c == '\n' else ' ' for c in text[a:b]]

    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
        elif text[i] == '"':
            j, depth = i + 1, 0
            while j < n and text[j] != '\n':
                if text.startswith('\\(', j):
                    depth, j = depth + 1, j + 2
                    continue
                if text[j] == '\\':
                    j += 2
                    continue
                if depth and text[j] == '(':
                    depth += 1
                elif depth and text[j] == ')':
                    depth -= 1
                elif text[j] == '"' and not depth:
                    break
                j += 1
            j += 1
        else:
            i += 1
            continue
        clear(i, j)
        i = j
    return ''.join(out)


def functions(code):
    """(name, body start, body end) for every func, init and computed var. The body is the first `{` outside the
    parameter list's parentheses; a requirement without a body (a protocol's) has none."""
    found = []
    for match in DECLARATION.finditer(code):
        name = match.group(1) or match.group(2) or match.group(3)
        if match.group(3):
            brace = match.end() - 1
        else:
            j, depth, brace = match.end(), 0, None
            while j < len(code):
                c = code[j]
                if c in '([':
                    depth += 1
                elif c in ')]':
                    depth -= 1
                elif depth == 0 and c == '{':
                    brace = j
                    break
                elif depth == 0 and c in ' \n;' and NO_BODY.match(code, j + 1):
                    break
                j += 1
            if brace is None:
                continue
        depth, j = 0, brace
        while j < len(code):
            if code[j] == '{':
                depth += 1
            elif code[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        found.append((name, brace, j))
    return found


def scan(root):
    """({(file, function): [call offsets]}, {file: blanked code})."""
    sites, codes = {}, {}
    for path in sorted((root / 'Sources').rglob('*.swift')):
        relative = str(path.relative_to(root))
        code = codes[relative] = blank(path.read_text())
        calls = [m.start() for m in ENGINE_CALL.finditer(code)]
        if path.name == 'VoiceCoach.swift':
            calls += [m.start() for m in VOICE_CALL.finditer(code)]
        spans = functions(code)
        for offset in calls:
            inside = [span for span in spans if span[1] < offset < span[2]]
            name = min(inside, key=lambda span: span[2] - span[1])[0] if inside else '<top level>'
            sites.setdefault((relative, name), []).append(offset)
    return sites, codes


def check(root, inventory):
    sites, codes = scan(root)
    entries = {(entry['file'], entry['function']): entry for entry in inventory['sites']}
    problems = []
    for key, offsets in sorted(sites.items()):
        entry = entries.get(key)
        if entry is None:
            problems.append(f'unclassified call site: {key[0]} {key[1]} ({len(offsets)} call(s))')
            continue
        if entry.get('calls') != len(offsets):
            problems.append(f'{key[0]} {key[1]}: {len(offsets)} call(s), the inventory lists {entry.get("calls")}')
        code, kind = codes[key[0]], entry.get('kind')
        spans = [span for span in functions(code) if span[0] == key[1] and any(span[1] < o < span[2] for o in offsets)]
        start = min((span[1] for span in spans), default=0)
        if kind == 'guarded':
            if not CHECK.search(code, start, min(offsets)):
                problems.append(f'{key[0]} {key[1]} is listed guarded but does not check FairnessPolicy before its first call')
        elif kind == 'delegated':
            callers = entry.get('callers') or []
            if not callers:
                problems.append(f'{key[0]} {key[1]} is delegated without callers')
            # How callers name the helper (BeginnerOpponent.choose), so an unrelated function of the same name never counts.
            pattern = re.compile(entry.get('callPattern') or r'(?<![\w.])' + re.escape(key[1]) + r'\(')
            # Each listed caller is guarded in its own right: it calls the helper and checks the policy before that.
            for caller in callers:
                caller_code = codes.get(caller['file'], '')
                calls = [(s[1], m.start() + s[1]) for s in functions(caller_code) if s[0] == caller['function']
                         for m in pattern.finditer(caller_code[s[1]:s[2]])]
                if not calls:
                    problems.append(f'{key[0]} {key[1]}: listed caller {caller["file"]} {caller["function"]} does not call it')
                elif not all(CHECK.search(caller_code, body, call) for body, call in calls):
                    problems.append(f'{key[0]} {key[1]}: listed caller {caller["file"]} {caller["function"]} does not check FairnessPolicy before calling it')
            # Every function that calls the helper must be a listed caller.
            listed = {(c['file'], c['function']) for c in callers}
            for file, other in codes.items():
                for s in functions(other):
                    if (file, s[0]) != key and pattern.search(other[s[1]:s[2]]) and (file, s[0]) not in listed:
                        if not any(span[1] < s[1] and s[2] < span[2] and (file, span[0]) in listed for span in functions(other)):
                            problems.append(f'{key[0]} {key[1]}: {file} {s[0]} calls it but is not a listed caller')
            # The await that belongs to a call sits just before it; an earlier one means work already ran meanwhile.
            for offset in offsets:
                earlier = [m.start() for m in re.finditer(r'\bawait\b', code[start:offset - 40])]
                if earlier and not CHECK.search(code, start + earlier[-1], offset):
                    problems.append(f'{key[0]} {key[1]}: a call after an earlier await has no FairnessPolicy check before it')
        elif kind == 'assisted':
            if key[0] not in ASSIST_FILES:
                problems.append(f'{key[0]} {key[1]} is listed assisted, which only the network assistant may be')
            elif not (entry.get('reason') or '').strip():
                problems.append(f'{key[0]} {key[1]} is assisted without a reason')
            else:
                end = max(span[2] for span in spans)
                if not ASSIST_CHECK.search(code, start, min(offsets)):
                    problems.append(f'{key[0]} {key[1]} is listed assisted but does not check requireNetworkHint before its first call')
                if not ASSIST_CHECK.search(code, max(offsets), end):
                    problems.append(f'{key[0]} {key[1]} is listed assisted but does not check requireNetworkHint again after its last call')
        elif kind == 'voice':
            if key[0] not in VOICE_FILES:
                problems.append(f'{key[0]} {key[1]} is listed voice, which only the voice coach may be')
            elif not (entry.get('reason') or '').strip():
                problems.append(f'{key[0]} {key[1]} is voice without a reason')
            elif not VOICE_CHECK.search(code, start, min(offsets)):
                problems.append(f'{key[0]} {key[1]} is listed voice but does not check voiceAllowed before its first call')
        elif kind == 'exempt':
            if not (entry.get('reason') or '').strip():
                problems.append(f'{key[0]} {key[1]} is exempt without a reason')
        else:
            problems.append(f'{key[0]} {key[1]}: unknown kind {kind!r}')
    problems += [f'inventory entry with no call site: {k[0]} {k[1]}' for k in sorted(set(entries) - set(sites))]
    return problems


def self_test(inventory):
    """Unguarded calls added to listed files fail the check: in a new function, and as one more call in a listed one."""
    with tempfile.TemporaryDirectory(prefix='checkmate-fairness-') as temporary:
        fixture = pathlib.Path(temporary)
        shutil.copytree(ROOT / 'Sources', fixture / 'Sources', ignore=shutil.ignore_patterns('Resources'))
        assert not check(fixture, inventory), 'the copied sources must pass before the fixture changes them'
        session = fixture / 'Sources/CheckmateApplication/GameSession.swift'
        original = session.read_text()
        session.write_text(original + '\nextension GameSession {func sneakyAnalysis()async throws {_ = try await engine?.analyze(fen:rules.fen,skill:20,budget:100,multiPv:1)}}\n')
        assert any('sneakyAnalysis' in p for p in check(fixture, inventory)), 'a new unguarded function passed'
        session.write_text(original)
        beginner = fixture / 'Sources/CheckmateApplication/BeginnerOpponent.swift'
        text, marker = beginner.read_text(), 'var rng=SeededReviewRandom(seed:seed),measured=root.lines'
        assert marker in text, 'the fixture marker moved; update the self-test'
        beginner.write_text(text.replace(marker, marker + ';_ = try await engine.analyzeHistory(startFEN:start,moves:history,profile:.skill(20),budget:budgetMs,multiPv:1)', 1))
        assert any('BeginnerOpponent' in p for p in check(fixture, inventory)), 'an extra unguarded call inside a listed function passed'
        # A helper that stops re-checking after its first await, and a guarded function that loses its guard, both fail.
        recheck = 'try Task.checkCancellation();try fairness.requireEngineHelp()'
        assert recheck in text, 'the fixture marker moved; update the self-test'
        beginner.write_text(text.replace(recheck, 'try Task.checkCancellation()', 1))
        assert any('after an earlier await' in p for p in check(fixture, inventory)), 'a delegated helper without its re-check passed'
        beginner.write_text(text)
        guard = 'public func chooseOpponentMove(engine:EngineService)async throws -> EngineAnalysis {\n        try fairness.requireEngineHelp()'
        assert guard in original, 'the fixture marker moved; update the self-test'
        session.write_text(original.replace(guard, guard.replace('try fairness.requireEngineHelp()', ''), 1))
        assert any('chooseOpponentMove' in p for p in check(fixture, inventory)), 'a guarded function without its guard passed'
        session.write_text(original)
        # The network assistant without its check after the search fails; so does a practice site listed as assisted.
        assistant = fixture / 'Sources/CheckmateApplication/NetworkAssistant.swift'
        hint, after = assistant.read_text(), 'try self.fairness.requireNetworkHint()'
        assert after in hint, 'the fixture marker moved; update the self-test'
        assistant.write_text(hint.replace(after, '', 1))
        assert any('again after its last call' in p for p in check(fixture, inventory)), 'an assistant without its re-check passed'
        assistant.write_text(hint)
        widened = json.loads(json.dumps(inventory))
        for entry in widened['sites']:
            if entry['function'] == 'chooseOpponentMove':
                entry.update(kind='assisted', reason='sneaking practice through the scoped check')
        assert any('only the network assistant' in p for p in check(fixture, widened)), 'a practice site listed assisted passed'
        # A voice turn entry without its check fails; so does an engine site listed as voice.
        coach = fixture / 'Sources/CheckmateMacPlatform/VoiceCoach.swift'
        voice, guard = coach.read_text(), 'public func recheck(){guard session.fairness.voiceAllowed(network:networkSession) else{return};'
        assert guard in voice, 'the fixture marker moved; update the self-test'
        coach.write_text(voice.replace(guard, 'public func recheck(){', 1))
        assert any('recheck' in p and 'voiceAllowed' in p for p in check(fixture, inventory)), 'a voice entry without its check passed'
        coach.write_text(voice)
        widened = json.loads(json.dumps(inventory))
        for entry in widened['sites']:
            if entry['function'] == 'chooseOpponentMove':
                entry.update(kind='voice', reason='sneaking practice through the voice check')
        assert any('only the voice coach' in p for p in check(fixture, widened)), 'an engine site listed voice passed'


if __name__ == '__main__':
    if '--list' in sys.argv:
        for (file, function), offsets in sorted(scan(ROOT)[0].items()):
            print(f'{file}\t{function}\t{len(offsets)}')
        raise SystemExit(0)
    inventory = json.loads((ROOT / 'Tests/fairness-inventory.json').read_text())
    problems = check(ROOT, inventory)
    assert not problems, 'Fairness inventory:\n  ' + '\n  '.join(problems)
    self_test(inventory)
    print(json.dumps({'passed': True, 'sites': len(inventory['sites'])}))
