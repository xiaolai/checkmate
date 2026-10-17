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

How the source is read: calls are found with whitespace allowed and through any receiver (`self.request(`,
`e.prepare()`), and inside string interpolations, which Swift runs. Each declaration of a name is checked on its own,
so one overload's guard never covers another's call. A check counts only when it is enforced: a discarded result
(`_ = …`, a bare `try?`) is no check. An `await` before a call other than the call's own is a suspension during which
participation can change, so a delegated or assisted call after one needs its check again after it. A voice entry's
check must sit in the same `case` as its call, and no engine call may be listed voice.
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
ENGINE_CALL = re.compile(r'\.analyze\s*\(\s*fen\s*:|(?<!func )\banalyzeHistory\s*\(\s*startFEN\s*:|\.prepare\s*\(\s*\)')
VOICE_CALL = re.compile(r'(?:(?<![.\w])|(?<=\bself\.))(?<!func )request\s*\(')
AWAIT = re.compile(r'\bawait\b')
# A `case` label starting a statement: a voice entry's check must sit in its call's own case (or before any).
CASE = re.compile(r'(?:^|[;{\n])[ \t]*case\b')
# What stands before a check that discards its result: `_ = …` or a bare `try?`, through any receiver chain.
DISCARDED = re.compile(r'(_\s*=\s*(?:try[?!]?\s*)?|try\?\s*)(?:\w+\.)*$')
CHECK = re.compile(r'fairness\.(?:engineHelpAllowed|requireEngineHelp\(\))')
ASSIST_CHECK = re.compile(r'fairness\.requireNetworkHint\(\)')
ASSIST_FILES = {'Sources/CheckmateApplication/NetworkAssistant.swift'}
VOICE_CHECK = re.compile(r'fairness\.voiceAllowed\(network:')
VOICE_FILES = {'Sources/CheckmateMacPlatform/VoiceCoach.swift'}
DECLARATION = re.compile(r'\bfunc\s+(\w+)|\b(init)\s*[(<]|\bvar\s+(\w+)\s*:[^={\n]*\{')
NO_BODY = re.compile(r'(?:func|var|let|init|case|struct|class|enum|extension)\b|\}')


def string_end(text, i):
    """(end, interpolations) of the one-line string literal opening at text[i]: each interpolation's code as a span."""
    j, n, spans = i + 1, len(text), []
    while j < n and text[j] != '\n':
        if text.startswith('\\(', j):
            k, depth = j + 2, 1
            while k < n and depth and text[k] != '\n':
                if text[k] == '"':
                    k = string_end(text, k)[0]
                    continue
                depth += {'(': 1, ')': -1}.get(text[k], 0)
                k += 1
            spans.append((j + 2, k - 1))
            j = k
            continue
        if text[j] == '\\':
            j += 2
            continue
        if text[j] == '"':
            return j + 1, spans
        j += 1
    return j + 1, spans


def blank(text):
    """Comments and string literals become spaces of the same length (newlines kept), so offsets stay valid and nothing
    inside a string or comment counts as code. An interpolation is code Swift runs, so it stays, itself blanked."""
    out, i, n = list(text), 0, len(text)
    kept = []

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
            j, spans = string_end(text, i)
            kept += spans
        else:
            i += 1
            continue
        clear(i, j)
        i = j
    for a, b in kept:
        out[a:b] = list(blank(text[a:b]))
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
    """({(file, function): [call offsets]}, {file: blanked code}, {(file, offset) of each engine call},
    {(file, offset): the declaration's (name, body start, body end) it sits in})."""
    sites, codes, engine, enclosing = {}, {}, set(), {}
    for path in sorted((root / 'Sources').rglob('*.swift')):
        relative = str(path.relative_to(root))
        code = codes[relative] = blank(path.read_text())
        calls = [m.start() for m in ENGINE_CALL.finditer(code)]
        engine |= {(relative, offset) for offset in calls}
        if path.name == 'VoiceCoach.swift':
            calls += [m.start() for m in VOICE_CALL.finditer(code)]
        spans = functions(code)
        for offset in calls:
            inside = [span for span in spans if span[1] < offset < span[2]]
            span = min(inside, key=lambda span: span[2] - span[1]) if inside else ('<top level>', 0, len(code))
            enclosing[(relative, offset)] = span
            sites.setdefault((relative, span[0]), []).append(offset)
    return sites, codes, engine, enclosing


def enforced(pattern, code, a, b):
    """Whether a check matching `pattern` in code[a:b] is enforced: its result is not discarded (`_ = …`), and a
    `try?` is compared with nil, so a refusal stops the work."""
    for match in pattern.finditer(code, a, b):
        before = DISCARDED.search(code, max(0, match.start() - 60), match.start())
        if before is None:
            return True
        if before.group(1).startswith('try?') and re.match(r'\s*\)\s*[!=]=\s*nil', code[match.end():]):
            return True
    return False


def own_await(code, start, offset):
    """Where the call at `offset` begins its own `await` (`try await engine.analyzeHistory(`): the last `await` before
    it in the same statement. Every `await` before that one is an earlier suspension."""
    own = offset
    for match in AWAIT.finditer(code, start, offset):
        if not re.search(r'[;{}\n]', code[match.end():offset]):
            own = match.start()
    return own


def rechecked(pattern, code, start, offset):
    """True unless an earlier suspension in the declaration precedes the call with no enforced check since it."""
    earlier = [m.start() for m in AWAIT.finditer(code, start, own_await(code, start, offset))]
    return not earlier or enforced(pattern, code, earlier[-1], offset)


def check(root, inventory):
    sites, codes, engine, enclosing = scan(root)
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
        # Each declaration of the name is checked on its own: one overload's guard never covers another's call.
        declarations = {}
        for offset in offsets:
            declarations.setdefault(enclosing[(key[0], offset)], []).append(offset)
        if kind == 'guarded':
            for (_, start, _), calls in declarations.items():
                if not enforced(CHECK, code, start, min(calls)):
                    problems.append(f'{key[0]} {key[1]} is listed guarded but does not check FairnessPolicy before its first call')
        elif kind == 'delegated':
            callers = entry.get('callers') or []
            if not callers:
                problems.append(f'{key[0]} {key[1]} is delegated without callers')
            # How callers name the helper (BeginnerOpponent.choose), so an unrelated function of the same name never counts.
            # `self.helper(` and `Self.helper(` are calls too; any other receiver names another type's method.
            pattern = re.compile(entry.get('callPattern') or r'(?:(?<![\w.])|(?<=\bself\.)|(?<=\bSelf\.))' + re.escape(key[1]) + r'\s*\(')
            # Each listed caller is guarded in its own right: it calls the helper and checks the policy before that.
            for caller in callers:
                caller_code = codes.get(caller['file'], '')
                calls = [(s[1], m.start() + s[1]) for s in functions(caller_code) if s[0] == caller['function']
                         for m in pattern.finditer(caller_code[s[1]:s[2]])]
                if not calls:
                    problems.append(f'{key[0]} {key[1]}: listed caller {caller["file"]} {caller["function"]} does not call it')
                elif not all(enforced(CHECK, caller_code, body, call) for body, call in calls):
                    problems.append(f'{key[0]} {key[1]}: listed caller {caller["file"]} {caller["function"]} does not check FairnessPolicy before calling it')
            # Every function that calls the helper must be a listed caller.
            listed = {(c['file'], c['function']) for c in callers}
            for file, other in codes.items():
                for s in functions(other):
                    if (file, s[0]) != key and pattern.search(other[s[1]:s[2]]) and (file, s[0]) not in listed:
                        if not any(span[1] < s[1] and s[2] < span[2] and (file, span[0]) in listed for span in functions(other)):
                            problems.append(f'{key[0]} {key[1]}: {file} {s[0]} calls it but is not a listed caller')
            # The await that belongs to a call is its own; an earlier one means work already ran meanwhile.
            for (_, start, _), calls in declarations.items():
                if not all(rechecked(CHECK, code, start, offset) for offset in calls):
                    problems.append(f'{key[0]} {key[1]}: a call after an earlier await has no FairnessPolicy check before it')
        elif kind == 'assisted':
            if key[0] not in ASSIST_FILES:
                problems.append(f'{key[0]} {key[1]} is listed assisted, which only the network assistant may be')
            elif not (entry.get('reason') or '').strip():
                problems.append(f'{key[0]} {key[1]} is assisted without a reason')
            else:
                for (_, start, end), calls in declarations.items():
                    if not enforced(ASSIST_CHECK, code, start, min(calls)):
                        problems.append(f'{key[0]} {key[1]} is listed assisted but does not check requireNetworkHint before its first call')
                    if not all(rechecked(ASSIST_CHECK, code, start, offset) for offset in calls):
                        problems.append(f'{key[0]} {key[1]}: an assisted call after an earlier await has no requireNetworkHint check before it')
                    if not enforced(ASSIST_CHECK, code, max(calls), end):
                        problems.append(f'{key[0]} {key[1]} is listed assisted but does not check requireNetworkHint again after its last call')
        elif kind == 'voice':
            if key[0] not in VOICE_FILES:
                problems.append(f'{key[0]} {key[1]} is listed voice, which only the voice coach may be')
            elif not (entry.get('reason') or '').strip():
                problems.append(f'{key[0]} {key[1]} is voice without a reason')
            elif any((key[0], offset) in engine for offset in offsets):
                problems.append(f'{key[0]} {key[1]} is listed voice but makes an engine call, which the voice check cannot cover')
            else:
                for (_, start, _), calls in declarations.items():
                    for offset in calls:
                        cases = [m.end() for m in CASE.finditer(code, start, offset)]
                        if not enforced(VOICE_CHECK, code, cases[-1] if cases else start, offset):
                            problems.append(f'{key[0]} {key[1]} is listed voice but does not check voiceAllowed before a call, in its own case')
                            break
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
        # An engine call inside a voice entry cannot pass on the voice check.
        recheck_call = 'public func recheck(){guard session.fairness.voiceAllowed(network:networkSession) else{return};'
        coach.write_text(voice.replace(recheck_call, recheck_call + '_ = try? await session.engine?.analyze(fen:"",skill:20,budget:100,multiPv:1);', 1))
        widened = json.loads(json.dumps(inventory))
        for entry in widened['sites']:
            if entry['file'].endswith('VoiceCoach.swift') and entry['function'] == 'recheck':
                entry['calls'] += 1
        assert any('makes an engine call' in p for p in check(fixture, widened)), 'an engine call inside a voice entry passed'
        # A voice check in another case does not cover a call; each case checks for its own.
        committed = 'if session.fairness.voiceAllowed(network:networkSession){if ownMove{request('
        assert committed in voice, 'the fixture marker moved; update the self-test'
        coach.write_text(voice.replace(committed, 'if true{if ownMove{request(', 1))
        assert any('in its own case' in p for p in check(fixture, inventory)), 'a voice call relying on another case\'s check passed'
        coach.write_text(voice)
        # A discarded check is no check: `_ = try?` refuses nothing.
        assistant.write_text(hint.replace(after, '_ = try? self.fairness.requireNetworkHint()', 1))
        assert any('again after its last call' in p for p in check(fixture, inventory)), 'a discarded re-check passed'
        # A suspension before the search needs the check again after it, in the assistant and in a delegated helper.
        search = 'let analysis=try await engine.analyzeHistory('
        assert search in hint, 'the fixture marker moved; update the self-test'
        assistant.write_text(hint.replace(search, 'await Task.yield();' + search, 1))
        assert any('assisted call after an earlier await' in p for p in check(fixture, inventory)), 'an assisted call after a suspension passed'
        assistant.write_text(hint)
        helper = '{try await e.analyzeHistory(startFEN:'
        assert helper in original, 'the fixture marker moved; update the self-test'
        session.write_text(original.replace(helper, '{await Task.yield();try await e.analyzeHistory(startFEN:', 1))
        assert any('after an earlier await' in p for p in check(fixture, inventory)), 'a suspension just before a delegated call passed'
        session.write_text(original)
        # Calls spelled with spaces, through another receiver, or inside an interpolation are calls; so is self.helper(.
        for name, body in [('sneakySpacing', '_ = try await engine?.analyzeHistory( startFEN:"",moves:[],profile:.skill(20),budget:100,multiPv:1)'),
                           ('sneakyAlias', 'let e=engine!;try await e.prepare()'),
                           ('sneakyInterpolation', 'print("\\(try await engine!.analyze(fen:"",skill:20,budget:100,multiPv:1))")')]:
            session.write_text(original + f'\nextension GameSession {{func {name}()async throws {{{body}}}}}\n')
            assert any(name in p for p in check(fixture, inventory)), f'{name}: an unlisted call passed'
        session.write_text(original + '\nextension GameSession {func sneakyHelper()async throws {_ = try await self.analyzeGame(engine!,budget:100,multiPv:1)}}\n')
        assert any('sneakyHelper calls it but is not a listed caller' in p for p in check(fixture, inventory)), 'a self.helper( caller passed'
        session.write_text(original)
        coach.write_text(voice + '\nextension VoiceCoach {func sneakyTurn(){self.request("Say anything",user:false)}}\n')
        assert any('sneakyTurn' in p for p in check(fixture, inventory)), 'a self.request( call passed'
        coach.write_text(voice)
        # One declaration's guard never covers another's call: an unguarded overload fails even when the count matches.
        assistant.write_text(hint + '\nextension NetworkAssistant {func start(_ quiet:Int)async throws {_ = try await engine?.analyzeHistory(startFEN:"",moves:[],profile:.skill(20),budget:100,multiPv:1)}}\n')
        widened = json.loads(json.dumps(inventory))
        for entry in widened['sites']:
            if entry['file'].endswith('NetworkAssistant.swift') and entry['function'] == 'start':
                entry['calls'] += 1
        assert any('before its first call' in p for p in check(fixture, widened)), 'an unguarded overload passed on another declaration\'s guard'
        assistant.write_text(hint)


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
