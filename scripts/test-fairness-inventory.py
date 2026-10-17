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

How the source is read, failing closed wherever a shape is not understood:
  - Swift is lexed, not grepped: comments (nested ones too) and string literals (multiline and raw ones too) are blanked,
    and the code in their interpolations, which Swift runs, is kept.
  - Every mention of an engine method counts as a call site, through any receiver and as a value; so does every
    `request` in VoiceCoach.swift. A delegated helper's every mention outside it must sit in a listed caller, and there
    it must be a checked call (`referencePattern`, by default the helper's name; `callPattern` for the call itself).
  - A check counts only in three forms: a statement `try …requireX()`; a condition of a `guard`, or of an `if` whose
    body holds the call, that is the check itself (or `(try? …requireX()) != nil`) joined to the others only by `,` or
    `&&`. A guard or statement covers the rest of its own block and switch arm; an if covers its body. A discarded,
    unused, negated, `||`-joined or ternary check, or one in a branch, `do` or closure that ended before the call,
    covers nothing.
  - A call's own `await` sits directly before it (`try await engine?.analyzeHistory(`, a line break allowed); any other
    `await` before it that can run on the way to it (not one in another switch arm, or an earlier branch of the same
    if-else chain) is a suspension, after which the call needs a check again. An `await` inside the call's own
    arguments suspends after every check and fails. An assisted search needs an enforced requireNetworkHint after the
    search ends, on its path, and after every later `await` in the declaration.
Each declaration of a name is checked on its own, so one overload's guard never covers another's call, and no engine
call may be listed voice.
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
# Every mention counts, called or not: an EngineService method passed as a value is a call site too. Argument labels are
# part of a Swift call, so `analyze(fen:` names the engine's method; whitespace is allowed anywhere Swift allows it.
# A declaration's own name is not a mention: those offsets are removed using the declaration parser (DECLARATION), so
# `func  analyzeHistory(` with any spacing or a line break is still a declaration.
ENGINE_CALL = re.compile(r'\.analyze\s*\(\s*fen\s*:|(?<![\w.])analyze\s*\(\s*fen\s*:|\banalyzeHistory\b|\.prepare\s*\(\s*\)|\.prepare\b(?!\s*\()|\.analyze\b(?!\s*\()')
# Any mention of `request` in VoiceCoach.swift, through any receiver (`self.request(`, `coach.request(`) or as a value.
VOICE_CALL = re.compile(r'\brequest\b')
AWAIT = re.compile(r'\bawait\b')
# A `case` or `default` label starting a statement: a check in one arm of a switch never covers another arm.
LABEL = re.compile(r'(?:^|(?<=[;{}\n]))[ \t]*(?:case\b|default\s*:)')
# A check runs through a plain or force-unwrapped receiver chain only: `owner?.fairness.requireX()` runs nothing when
# `owner` is nil, so an optional chain is no check.
RECEIVER = r'(?:\w+!?\s*\.\s*)*'
CHECK = re.compile(RECEIVER + r'fairness\s*\.\s*(?:engineHelpAllowed\b|requireEngineHelp\s*\(\s*\))')
ASSIST_CHECK = re.compile(RECEIVER + r'fairness\s*\.\s*requireNetworkHint\s*\(\s*\)')
ASSIST_FILES = {'Sources/CheckmateApplication/NetworkAssistant.swift'}
VOICE_CHECK = re.compile(RECEIVER + r'fairness\s*\.\s*voiceAllowed\s*\(\s*network\s*:[^()]*\)')
VOICE_FILES = {'Sources/CheckmateMacPlatform/VoiceCoach.swift'}
DECLARATION = re.compile(r'\bfunc\s+(\w+)|\b(init)\s*[(<]|\bvar\s+(\w+)\s*:[^={\n]*\{')
NO_BODY = re.compile(r'(?:func|var|let|init|case|struct|class|enum|extension)\b|\}')
OPENERS, CLOSERS = '([{', ')]}'
CONDITIONAL, ELSE = re.compile(r'\b(guard|if)\b'), re.compile(r'\belse\b')
# What separates two branches of one if-else chain: `else`, or `else if …` and any branches between with flat bodies.
# Anything else between two blocks (statements, nested braces) reads as sequence, which only asks for more checks.
IF_ELSE = re.compile(r'(?:\s*else\s*if\b[^{};]*\{[^{}]*\})*\s*else\s*(?:if\b[^{};]*)?')


class Unlexable(Exception):
    """Source this lexer cannot read with certainty (an unterminated literal or comment, as a regex literal holding a
    quote would leave it): the file fails the inventory instead of having code silently blanked."""


def comment_end(text, i):
    """The end of the block comment opening at text[i]; Swift block comments nest."""
    depth, k, n = 0, i, len(text)
    while k < n:
        if text.startswith('/*', k):
            depth, k = depth + 1, k + 2
        elif text.startswith('*/', k):
            depth, k = depth - 1, k + 2
            if depth == 0:
                return k
        else:
            k += 1
    raise Unlexable(f'an unterminated block comment at offset {i}')


LITERAL = re.compile(r'(#*)("""|")')


def literal(text, i):
    """(end, interpolations) of the string literal opening at text[i]: one-line or multiline, raw (`#"…"#`, whose
    interpolation is a backslash, the hashes and `(`) or not. Each interpolation is the span of code Swift runs inside it."""
    m = LITERAL.match(text, i)
    hashes, quote = m.group(1), m.group(2)
    close, interpolation, escape = quote + hashes, '\\' + hashes + '(', '\\' + hashes
    k, n, spans = m.end(), len(text), []
    while k < n:
        if quote == '"' and text[k] == '\n':
            # Compiling Swift has no unterminated literal: a quote inside a regex literal (`#/"/#`) reads as one.
            raise Unlexable(f'an unterminated string literal at offset {i}')
        if text.startswith(close, k):
            return k + len(close), spans
        if text.startswith(interpolation, k):
            begin = k + len(interpolation)
            k = code_end(text, begin)
            spans.append((begin, k))
            k += 1
            continue
        if text.startswith(escape, k):
            k += len(escape) + 1
            continue
        k += 1
    raise Unlexable(f'an unterminated string literal at offset {i}')


def code_end(text, k):
    """The offset of the `)` closing an interpolation whose code starts at text[k], skipping nested literals."""
    depth, n = 1, len(text)
    while k < n:
        if text.startswith('//', k):
            k = text.find('\n', k)
            k = n if k < 0 else k
            continue
        if text.startswith('/*', k):
            k = comment_end(text, k)
            continue
        if LITERAL.match(text, k):
            k = literal(text, k)[0]
            continue
        if text[k] == '(':
            depth += 1
        elif text[k] == ')':
            depth -= 1
            if depth == 0:
                return k
        k += 1
    raise Unlexable(f'an unterminated interpolation at offset {k}')


def blank(text):
    """Comments and string literals become spaces of the same length (newlines kept), so offsets stay valid and nothing
    inside a string or comment counts as code. An interpolation is code Swift runs, so it stays, itself blanked."""
    out, i, n, kept = list(text), 0, len(text), []
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
        elif text.startswith('/*', i):
            j = comment_end(text, i)
        elif text[i] in '#"' and LITERAL.match(text, i) and (text[i] == '"' or i == 0 or not (text[i - 1].isalnum() or text[i - 1] == '_')):
            j, spans = literal(text, i)
            kept += spans
        else:
            i += 1
            continue
        out[i:j] = [c if c == '\n' else ' ' for c in text[i:j]]
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
        found.append((name, brace, matching(code, brace)))
    return found


def matching(code, i):
    """The offset of the bracket closing the one at code[i] (any of ( [ {), or len(code)."""
    depth = 0
    for j in range(i, len(code)):
        if code[j] in OPENERS:
            depth += 1
        elif code[j] in CLOSERS:
            depth -= 1
            if depth == 0:
                return j
    return len(code)


# What a block's header (the code between the previous `;`, `{` or `}` and its `{`) starts with when the block is
# control flow or a declaration's body, after attributes and modifiers. Any other block is a closure, which may run
# later (a Task) or more than once: a check outside it never covers a call inside it.
MODIFIERS = re.compile(r'(?:@\w+(?:\([^()]*\))?\s*|(?:public|private|fileprivate|internal|open|static|class|final|override|mutating|nonmutating|nonisolated|convenience|required|lazy|weak|unowned|indirect|dynamic|optional)\b\s*)*')
CONTROL = re.compile(r'(?:\w+\s*:\s*)?(?:if|guard|else|for|while|repeat|switch|do|catch|defer|func|init|deinit|subscript|get|set|willSet|didSet|struct|enum|extension|protocol|actor|class)\b')
LOOP = re.compile(r'(?:\w+\s*:\s*)?(?:for|while|repeat)\b')
CONTINUES = re.compile(r'(?:[.,)\]?:+*/%<>=!&|-]|else\b|where\b|throws\b|rethrows\b|async\b)')
CONTINUED = re.compile(r'(?:[,(\[=+*/%<>!&|?:-]|\bin|\bwhere)$')


class Structure:
    """The braces of one file's blanked code: the innermost block around an offset, the switch arms in a block, and
    which blocks are closures or loop bodies."""

    def __init__(self, code):
        self.code, self.blocks, stack = code, [], []
        for j, c in enumerate(code):
            if c == '{':
                stack.append(j)
            elif c == '}' and stack:
                self.blocks.append((stack.pop(), j))
        self.blocks.sort()
        self.closures, self.loops = set(), set()
        for block in self.blocks:
            header = self.header(block[0])
            if LOOP.match(header):
                self.loops.add(block)
            elif not CONTROL.match(header) and not re.match(r'(?:var|let)\b[^=]*$', header):
                self.closures.add(block)

    def header(self, opening):
        """The code before the `{` at `opening` back to the previous `;`, `{` or `}` at its own depth, modifiers removed."""
        depth, k = 0, opening - 1
        while k >= 0:
            c = self.code[k]
            if c in ')]':
                depth += 1
            elif c in '([':
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and c in ';{}':
                break
            k -= 1
        # Newlines also end statements: the header is the last line, joined with the lines it continues (one starting or
        # ending with an operator, `,`, `.`, `else` or a bracket), so `guard a,\n b else {` reads as the guard it is.
        lines = [line.strip() for line in self.code[k + 1:opening].split('\n')]
        lines = [line for line in lines if line] or ['']
        start = len(lines) - 1
        while start > 0 and (CONTINUES.match(lines[start]) or CONTINUED.search(lines[start - 1])):
            start -= 1
        text = ' '.join(lines[start:])
        return text[MODIFIERS.match(text).end():]

    def deferred(self, check, offset):
        """Whether a closure holds the call at `offset` but not the check at `check`: the check runs, the closure later."""
        return any(b[0] < offset < b[1] and not b[0] < check < b[1] for b in self.closures)

    def loop(self, offset):
        """The innermost loop body around `offset`, or None."""
        inside = [b for b in self.loops if b[0] < offset < b[1]]
        return min(inside, key=lambda b: b[1] - b[0]) if inside else None

    def block(self, offset):
        inside = [b for b in self.blocks if b[0] < offset < b[1]]
        return min(inside, key=lambda b: b[1] - b[0]) if inside else (-1, len(self.code))

    def chain(self, offset):
        """The blocks around `offset`, outermost first."""
        return sorted((b for b in self.blocks if b[0] < offset < b[1]), key=lambda b: b[0])

    def reaches(self, earlier, offset):
        """Whether code at `earlier` can run before the call at `offset` on the way to it. Only exclusive branches are
        ruled out: another arm of the same switch, and an earlier branch of the `if … else` chain the call's branch
        ends. Everything else, an earlier block or a closure written before the call included, counts."""
        a, c = self.chain(earlier), self.chain(offset)
        common = 0
        while common < min(len(a), len(c)) and a[common] == c[common]:
            common += 1
        parent = a[common - 1] if common else (-1, len(self.code))
        # Where each side enters the innermost block they share: its own position, or the child block holding it.
        enter_a = a[common][0] if common < len(a) else earlier
        enter_c = c[common][0] if common < len(c) else offset
        # Switch arms are exclusive unless one falls through into the next.
        if self.arm(enter_a) != self.arm(enter_c) and not re.search(r'\bfallthrough\b', self.code[parent[0]:parent[1]]):
            return False
        if common < len(a) and common < len(c) and IF_ELSE.fullmatch(self.code[a[common][1] + 1:c[common][0]]):
            return False
        return True

    def arm(self, offset):
        """(start, end) of the switch arm holding `offset` in its innermost block, or the whole block."""
        block = self.block(offset)
        labels = [m.end() for m in LABEL.finditer(self.code, block[0] + 1, block[1]) if self.block(m.end()) == block]
        before, after = [l for l in labels if l <= offset], [l for l in labels if l > offset]
        return (before[-1] if before else block[0], after[0] if after else block[1])


def top_level_split(text):
    """The comma- and &&-separated conditions of a condition list, and whether any top-level `||` joins them."""
    parts, depth, last, k, joined = [], 0, 0, 0, False
    while k < len(text):
        c = text[k]
        if c in OPENERS:
            depth += 1
        elif c in CLOSERS:
            depth -= 1
        elif depth == 0 and (c == ',' or text.startswith('&&', k) or text.startswith('||', k)):
            joined |= text.startswith('||', k)
            parts.append(text[last:k])
            k += 1 if c == ',' else 2
            last = k
            continue
        k += 1
    return parts + [text[last:]], joined


def coverage(structure, match):
    """Where an enforced check covers, or None for a check that refuses nothing. Three forms count:
      a statement `try …requireX()` (never `try?`, `_ =` or a value): from its end to the end of its block's arm;
      a `guard` condition that is the check itself, or `(try? …requireX()) != nil`, as one of its conditions joined only
        by `,` or `&&`: from the end of its `else` block to the end of the guard's block's arm;
      an `if` condition of the same shape: inside the if's own body.
    Anything else (an unused `let`, a negation, `||`, a ternary, a check inside a branch, a `do` or a closure that ended
    before the call) covers nothing, so a call it might have guarded fails the inventory."""
    code, s, e = structure.code, match.start(), match.end()
    head = code[max(0, s - 200):s]
    statement = re.search(r'(?:^|[;{}\n]|\bin)\s*try\s+$', head)
    # A statement stands at its block's top level: inside ( ) or [ ] (`_ = try? (\ntry …\n)`) it is part of an expression.
    if statement and 'require' in match.group(0) and re.match(r'\s*(?:[;}\n]|$)', code[e:]) and not open_brackets(code[structure.block(s)[0] + 1:s]):
        arm = structure.arm(s)
        return (e, arm[1])
    block = structure.block(s)
    keyword = None
    for m in CONDITIONAL.finditer(code, block[0] + 1, s):
        between = code[m.end():s]
        if not re.search(r'[;{}]', blank_parens(between)) and not re.search(r'\belse\b', between):
            keyword = m
    if keyword is None:
        return None
    if keyword.group(1) == 'guard':
        found = top_level(code, keyword.end(), ELSE)
        if found is None:
            return None
        conditions, tail = code[keyword.end():found], found + 4
        opening = code.find('{', tail)
        if opening < 0 or code[tail:opening].strip():
            return None
        region = (matching(code, opening), structure.arm(s)[1])
    else:
        opening = top_level(code, keyword.end(), OPEN_BRACE)
        if opening is None:
            return None
        conditions, region = code[keyword.end():opening], (opening, matching(code, opening))
    parts, joined = top_level_split(conditions)
    if joined:
        return None
    atom = re.sub(r'\s+', '', match.group(0))
    accepted = {atom, f'(try?{atom})!=nil'} if 'require' in atom else {atom}
    return region if any(re.sub(r'\s+', '', part) in accepted for part in parts) else None


OPEN_BRACE = re.compile(r'\{')


def top_level(code, start, pattern):
    """The first match of `pattern` from `start` outside any ( ) or [ ] opened after `start`, or None at the end of
    the enclosing bracket."""
    depth, k = 0, start
    while k < len(code):
        c = code[k]
        if depth == 0 and pattern.match(code, k):
            return k
        if c in '([':
            depth += 1
        elif c in ')]':
            depth -= 1
            if depth < 0:
                return None
        k += 1
    return None


def open_brackets(text):
    """Whether `text` leaves a ( or [ open."""
    depth = 0
    for c in text:
        if c in '([':
            depth += 1
        elif c in ')]':
            depth = max(0, depth - 1)
    return depth > 0


def blank_parens(text):
    """`text` with everything inside ( ) and [ ] blanked, so only its top level reads."""
    out, depth = list(text), 0
    for j, c in enumerate(text):
        if c in '([':
            depth += 1
        if depth:
            out[j] = ' '
        if c in ')]':
            depth = max(0, depth - 1)
    return ''.join(out)


def covered(pattern, structure, low, offset):
    """Whether an enforced check matching `pattern`, starting at or after `low`, covers the call at `offset`."""
    for match in pattern.finditer(structure.code, max(0, low), offset):
        region = coverage(structure, match)
        if region and region[0] <= offset < region[1] and not structure.deferred(match.start(), offset):
            return True
    return False


def call_end(code, offset):
    """The end of the call whose name is at `offset`: its closing `)`, or the name itself for a reference."""
    opening = re.compile(r'[\w.]*\s*\(').match(code, offset)
    return matching(code, opening.end() - 1) + 1 if opening else offset


def own_await(code, start, offset):
    """The `await` that belongs to the call at `offset`: the last one before it with nothing but the receiver between
    (`try await engine?.analyzeHistory(`, a line break allowed). Every other `await` before it is an earlier
    suspension, including one inside the same expression (`await (Task.yield(), e.analyzeHistory(…))`)."""
    own = offset
    for match in AWAIT.finditer(code, start, offset):
        if re.fullmatch(r'[\w\s.?!]*', code[match.end():offset]):
            own = match.start()
    return own


def rechecked(pattern, structure, start, offset):
    """True unless an earlier suspension in the declaration, on a path to the call, precedes the call with no enforced
    check covering the call since it."""
    earlier = [m.start() for m in AWAIT.finditer(structure.code, start, own_await(structure.code, start, offset)) if structure.reaches(m.start(), offset)]
    if earlier and not covered(pattern, structure, earlier[-1], offset):
        return False
    # In a loop whose body suspends (the call's own await included), the next iteration's call follows a suspension:
    # it needs a check inside the loop body, before it.
    body = structure.loop(offset)
    if body and AWAIT.search(structure.code, body[0], body[1]) and not covered(pattern, structure, body[0], offset):
        return False
    return True


def argument_await(code, offset):
    """Whether the call at `offset` suspends while its arguments are evaluated, after any check before it."""
    return bool(AWAIT.search(code, offset, call_end(code, offset)))


def declaration_names(code):
    """The offsets of every declared function or computed var's own name, which are declarations, not mentions."""
    return {m.start(g) for m in DECLARATION.finditer(code) for g in (1, 3) if m.group(g)}


def name_at(code, offset):
    """The offset of the name a match at `offset` starts with (after a leading `.`)."""
    return offset + 1 if code.startswith('.', offset) else offset


def scan(root):
    """({(file, function): [call offsets]}, {file: blanked code}, {(file, offset) of each engine call},
    {(file, offset): the declaration's (name, body start, body end) it sits in}, [files that could not be lexed])."""
    sites, codes, engine, enclosing, unlexable = {}, {}, set(), {}, []
    for path in sorted((root / 'Sources').rglob('*.swift')):
        relative = str(path.relative_to(root))
        try:
            code = codes[relative] = blank(path.read_text())
        except Unlexable as error:
            unlexable.append(f'{relative} cannot be read with certainty ({error}); the inventory fails closed')
            continue
        declared = declaration_names(code)
        calls = [m.start() for m in ENGINE_CALL.finditer(code) if name_at(code, m.start()) not in declared]
        engine |= {(relative, offset) for offset in calls}
        if path.name == 'VoiceCoach.swift':
            calls += [m.start() for m in VOICE_CALL.finditer(code) if m.start() not in declared]
        spans = functions(code)
        for offset in calls:
            inside = [span for span in spans if span[1] < offset < span[2]]
            span = min(inside, key=lambda span: span[2] - span[1]) if inside else ('<top level>', 0, len(code))
            enclosing[(relative, offset)] = span
            sites.setdefault((relative, span[0]), []).append(offset)
    return sites, codes, engine, enclosing, unlexable


def reference(code, offset):
    """Whether the engine mention at `offset` names the method without calling it (`let search = engine.analyzeHistory`):
    its later uses, after any suspension, cannot be followed, so only an exempt site may do it."""
    name = re.compile(r'\w+').match(code, name_at(code, offset))
    return not re.match(r'\s*\(', code[name.end():]) if name else False


def check(root, inventory):
    sites, codes, engine, enclosing, problems = scan(root)
    structures = {file: Structure(code) for file, code in codes.items()}
    entries = {(entry['file'], entry['function']): entry for entry in inventory['sites']}
    for key, offsets in sorted(sites.items()):
        entry = entries.get(key)
        if entry is None:
            problems.append(f'unclassified call site: {key[0]} {key[1]} ({len(offsets)} call(s))')
            continue
        if entry.get('calls') != len(offsets):
            problems.append(f'{key[0]} {key[1]}: {len(offsets)} call(s), the inventory lists {entry.get("calls")}')
        code, structure, kind = codes[key[0]], structures[key[0]], entry.get('kind')
        # Each declaration of the name is checked on its own: one overload's guard never covers another's call.
        declarations = {}
        for offset in offsets:
            declarations.setdefault(enclosing[(key[0], offset)], []).append(offset)
        if kind in ('guarded', 'delegated', 'assisted') and any(argument_await(code, offset) for offset in offsets if (key[0], offset) in engine):
            problems.append(f'{key[0]} {key[1]}: an engine call suspends while its arguments are evaluated, after its check')
        if kind != 'exempt' and any(reference(code, offset) for offset in offsets if (key[0], offset) in engine):
            problems.append(f'{key[0]} {key[1]}: an engine method is passed as a value, so its later calls cannot be checked')
        if kind == 'guarded':
            for (_, start, _), calls in declarations.items():
                if not all(covered(CHECK, structure, start, offset) for offset in calls):
                    problems.append(f'{key[0]} {key[1]} is listed guarded but does not check FairnessPolicy before its first call')
                elif not all(rechecked(CHECK, structure, start, offset) for offset in calls):
                    problems.append(f'{key[0]} {key[1]}: a guarded call after an earlier await has no FairnessPolicy check before it')
        elif kind == 'delegated':
            problems += delegated(key, entry, codes, structures, declarations)
        elif kind == 'assisted':
            if key[0] not in ASSIST_FILES:
                problems.append(f'{key[0]} {key[1]} is listed assisted, which only the network assistant may be')
            elif not (entry.get('reason') or '').strip():
                problems.append(f'{key[0]} {key[1]} is assisted without a reason')
            else:
                for (_, start, end), calls in declarations.items():
                    if not all(covered(ASSIST_CHECK, structure, start, offset) for offset in calls):
                        problems.append(f'{key[0]} {key[1]} is listed assisted but does not check requireNetworkHint before its first call')
                    if not all(rechecked(ASSIST_CHECK, structure, start, offset) for offset in calls):
                        problems.append(f'{key[0]} {key[1]}: an assisted call after an earlier await has no requireNetworkHint check before it')
                    if not delivered(structure, max(calls), end):
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
                    if not all(covered(VOICE_CHECK, structure, start, offset) for offset in calls):
                        problems.append(f'{key[0]} {key[1]} is listed voice but does not check voiceAllowed before a call, in its own case')
        elif kind == 'exempt':
            if not (entry.get('reason') or '').strip():
                problems.append(f'{key[0]} {key[1]} is exempt without a reason')
        else:
            problems.append(f'{key[0]} {key[1]}: unknown kind {kind!r}')
    problems += [f'inventory entry with no call site: {k[0]} {k[1]}' for k in sorted(set(entries) - set(sites))]
    return problems


def only_exits(code, a, b):
    """Whether code[a:b] holds nothing but `guard … else {return …}` / `{throw …}` statements that do not suspend: code
    that can only stop, never deliver a result, before the check that must come first."""
    k = a
    while True:
        while k < b and code[k] in ' \t\n;':
            k += 1
        if k >= b:
            return True
        if not re.match(r'guard\b', code[k:b]):
            return False
        found = top_level(code, k + 5, ELSE)
        opening = code.find('{', found + 4) if found is not None else -1
        if found is None or opening < 0 or opening >= b or code[found + 4:opening].strip() or AWAIT.search(code, k, opening):
            return False
        close = matching(code, opening)
        if close >= b or not re.match(r'\s*(?:return|throw)\b', code[opening + 1:close]):
            return False
        k = close + 1


def next_check(structure, after, end, search):
    """Whether, after offset `after`, the first requireNetworkHint is an enforced statement or guard that covers the rest
    of its arm, in a block holding the search, with nothing but exits before it: nothing can deliver a result first."""
    code = structure.code
    for m in ASSIST_CHECK.finditer(code, after, end):
        region = coverage(structure, m)
        if not region:
            return False
        # A statement check covers from its own end; a guard's from the end of its else block (an if covers only its body).
        begin = code.rfind('try', after, m.start()) if region[0] == m.end() else code.rfind('guard', after, m.start())
        block = structure.block(m.start())
        return begin >= after and region[1] == structure.arm(m.start())[1] and block[0] < search < block[1] and only_exits(code, after, begin)
    return False


def statement_end(code, k):
    """The end of the statement holding offset k: the next `;` or line break outside brackets, or its block's `}`."""
    depth = 0
    while k < len(code):
        c = code[k]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0:
                return k
            depth -= 1
        elif depth == 0 and c in ';\n':
            return k
        k += 1
    return k


def delivered(structure, last, end):
    """Right after the last assisted search ends, before anything but exits, an enforced requireNetworkHint whose block
    holds the search; and after each of the declaration's later `await`s, before anything but exits, another: a result
    is delivered only under the terms that allowed it, never after a suspension that could have changed them."""
    code = structure.code
    if not next_check(structure, statement_end(code, call_end(code, last)), end, last):
        return False
    return all(next_check(structure, statement_end(code, suspension.start()), end, last) for suspension in AWAIT.finditer(code, call_end(code, last), end))


def delegated(key, entry, codes, structures, declarations):
    """A helper's callers: every mention of the helper (`referencePattern`, by default its name) outside the helper is
    in a listed caller, and there it is a call (`callPattern`) checked before it and after any earlier suspension; the
    helper re-checks after its own earlier suspensions."""
    problems, callers = [], entry.get('callers') or []
    if not callers:
        problems.append(f'{key[0]} {key[1]} is delegated without callers')
    # How callers name the helper (BeginnerOpponent.choose), so an unrelated function of the same name never counts.
    call = re.compile(entry.get('callPattern') or r'(?:(?<![\w.])|(?<=\bself\.)|(?<=\bSelf\.))' + re.escape(key[1]) + r'\s*\(')
    reference = re.compile(entry.get('referencePattern') or r'\b' + re.escape(key[1]) + r'\b')
    listed = {(c['file'], c['function']) for c in callers}
    for caller in callers:
        caller_code, structure = codes.get(caller['file'], ''), structures.get(caller['file'])
        calls = [(s[1], m.start() + s[1]) for s in functions(caller_code) if s[0] == caller['function'] for m in call.finditer(caller_code[s[1]:s[2]])]
        if not calls:
            problems.append(f'{key[0]} {key[1]}: listed caller {caller["file"]} {caller["function"]} does not call it')
        elif not all(covered(CHECK, structure, body, at) and rechecked(CHECK, structure, body, at) for body, at in calls):
            problems.append(f'{key[0]} {key[1]}: listed caller {caller["file"]} {caller["function"]} does not check FairnessPolicy before calling it')
        elif any(argument_await(caller_code, at) for _, at in calls):
            # The helper's first engine call relies on the caller's check, which a suspension in the arguments outlives.
            problems.append(f'{key[0]} {key[1]}: listed caller {caller["file"]} {caller["function"]} suspends in its arguments, after its check')
    helper = [span for span in functions(codes[key[0]]) if span[0] == key[1]]
    for file, other in codes.items():
        spans, declared = functions(other), declaration_names(other)
        for m in reference.finditer(other):
            if m.start() in declared or (file == key[0] and any(s[1] <= m.start() <= s[2] for s in helper)):
                continue
            inside = [s for s in spans if s[1] < m.start() < s[2]]
            owner = max(inside, key=lambda s: s[1]) if inside else None
            outer = [s for s in inside if (file, s[0]) in listed]
            if not outer:
                problems.append(f'{key[0]} {key[1]}: {file} {owner[0] if owner else "<top level>"} calls it but is not a listed caller')
            elif not any(c.start() <= m.start() < c.end() for c in call.finditer(other, max(0, m.start() - 40), m.end() + 40)):
                problems.append(f'{key[0]} {key[1]}: {file} {outer[0][0]} names it other than as a checked call')
    structure = structures[key[0]]
    for (_, start, _), offsets in declarations.items():
        if not all(rechecked(CHECK, structure, start, offset) for offset in offsets):
            problems.append(f'{key[0]} {key[1]}: a call after an earlier await has no FairnessPolicy check before it')
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
        fail_closed(fixture, inventory, original, hint, voice)


def widen(inventory, file, function, **changes):
    """A copy of the inventory with one entry changed, or added when it is not listed."""
    widened = json.loads(json.dumps(inventory))
    entry = next((e for e in widened['sites'] if e['file'].endswith(file) and e['function'] == function), None)
    if entry is None:
        entry = {'file': f'Sources/{file}', 'function': function}
        widened['sites'].append(entry)
    entry.update(changes)
    return widened


def fail_closed(fixture, inventory, session_text, hint, voice):
    """Shapes the scanner must refuse (audit rounds 1 and 2), and the exclusive branches it must still accept."""
    session = fixture / 'Sources/CheckmateApplication/GameSession.swift'
    assistant = fixture / 'Sources/CheckmateApplication/NetworkAssistant.swift'
    coach = fixture / 'Sources/CheckmateMacPlatform/VoiceCoach.swift'
    review = fixture / 'Sources/CheckmateApplication/ReviewAnalyzer.swift'

    def changed(path, text, listed):
        """The problems with `path` holding `text`; the file is put back whatever happens."""
        before = path.read_text()
        try:
            path.write_text(text)
            return check(fixture, listed or inventory)
        finally:
            path.write_text(before)

    def fails(path, text, expected, message, listed=None):
        problems = changed(path, text, listed)
        assert any(all(part in p for part in expected) for p in problems), f'{message}: {problems}'

    def passes(path, text, message, listed=None):
        problems = changed(path, text, listed)
        assert not problems, f'{message}: {problems}'

    def marked(text, marker):
        assert marker in text, f'the fixture marker {marker!r} moved; update the self-test'
        return marker

    # A check whose result nothing uses, one in a branch that never runs, and one swallowed by `do … catch` refuse nothing.
    recheck = marked(voice, 'public func recheck(){guard session.fairness.voiceAllowed(network:networkSession) else{return};')
    fails(coach, voice.replace(recheck, 'public func recheck(){let allowed=session.fairness.voiceAllowed(network:networkSession);', 1), ('recheck', 'voiceAllowed'), 'an unused voice check passed')
    guard = marked(session_text, 'public func chooseOpponentMove(engine:EngineService)async throws -> EngineAnalysis {\n        try fairness.requireEngineHelp()')
    for dead in ('if false{try fairness.requireEngineHelp()}', 'do{try fairness.requireEngineHelp()}catch{}', '_ = (try? fairness.requireEngineHelp()) != nil'):
        fails(session, session_text.replace(guard, guard.replace('try fairness.requireEngineHelp()', dead), 1), ('chooseOpponentMove',), f'{dead}: a check that refuses nothing passed')
    session.write_text(session_text)
    # A discarded `(try? …) != nil` after the search is no re-check; neither is one inside the search's own arguments,
    # nor one followed by another suspension before the result is delivered.
    after = marked(hint, 'try self.fairness.requireNetworkHint()')
    fails(assistant, hint.replace(after, '_ = (try? self.fairness.requireNetworkHint()) != nil', 1), ('again after its last call',), 'a discarded comparison passed as the re-check')
    nodes = marked(hint, 'limit:.nodes(NetworkAssistance.hintNodes)')
    fails(assistant, hint.replace(after, '', 1).replace(nodes, 'limit:.nodes({try! self.fairness.requireNetworkHint();return NetworkAssistance.hintNodes}())', 1), ('again after its last call',), 'a check inside the search\'s arguments passed as the re-check')
    fails(assistant, hint.replace(after, after + ';await Task.yield()', 1), ('again after its last call',), 'a suspension between the re-check and delivery passed')
    assistant.write_text(hint)
    # A guarded function re-checks after each suspension too: ReviewAnalyzer.compute without its later checks fails.
    later = review.read_text()
    between = marked(later, 'try Task.checkCancellation();try fairness.requireEngineHelp()\n        let played:EngineAnalysis?')
    fails(review, later.replace(between, 'try Task.checkCancellation()\n        let played:EngineAnalysis?', 1), ('compute', 'after an earlier await'), 'a guarded call after a suspension passed')
    review.write_text(later)
    # A helper named through another receiver, or as a value, outside or inside a listed caller.
    for name, body in [('sneakyTarget', 'let target=self;_ = try await target.analyzeGame(engine!,budget:100,multiPv:1)'),
                       ('sneakyValue', 'let f=analyzeGame;_ = f')]:
        fails(session, session_text + f'\nextension GameSession {{func {name}()async throws {{{body}}}}}\n', (name, 'not a listed caller'), f'{name}: a helper reached around its callers passed')
    listed = marked(session_text, 'let epoch=position;let a=try await analyzeGame(e,budget:budget,multiPv:multiPv)')
    fails(session, session_text.replace(listed, 'let g=analyzeGame;' + listed, 1), ('other than as a checked call',), 'a listed caller passing the helper on passed')
    # The delegated helper: a line break inside its own `await` is still its own; a suspension inside the same
    # expression is an earlier one; and an `await` in its arguments suspends after every check.
    own = marked(session_text, '{try await e.analyzeHistory(startFEN:')
    passes(session, session_text.replace(own, '{try await\n            e.analyzeHistory(startFEN:', 1), 'a line break after the call\'s own await failed')
    fails(session, session_text.replace(own, '{try await (Task.yield(), e.analyzeHistory(startFEN:', 1), ('after an earlier await',), 'a suspension inside the same expression passed')
    fails(session, session_text.replace(own, '{try await e.analyzeHistory(startFEN:await self.loadFEN(),', 1), ('suspends while its arguments',), 'an await in the arguments passed')
    # Exclusive branches are not suspensions on the way: if-else and switch arms pass; one if after another does not.
    branches = '\nextension GameSession {func sneakyBranches(_ x:Bool)async throws {try fairness.requireEngineHelp();%s}}\n'
    call = '_ = try await engine!.analyze(fen:"",skill:20,budget:100,multiPv:1)'
    two = widen(inventory, 'CheckmateApplication/GameSession.swift', 'sneakyBranches', kind='guarded', calls=2)
    passes(session, session_text + branches % f'if x {{{call}}} else {{{call}}}', 'an if-else pair failed', two)
    passes(session, session_text + branches % f'switch x {{case true:{call}\ndefault:{call}}}', 'two switch arms failed', two)
    fails(session, session_text + branches % f'if x {{{call}}};if !x {{{call}}}', ('sneakyBranches', 'after an earlier await'), 'a call after an earlier branch\'s suspension passed', two)
    session.write_text(session_text)
    # A switch arm never borrows another arm's check, `default:` included.
    arms = voice + '\nextension VoiceCoach {func sneakySwitch(_ x:Int){switch x {case 1:guard session.fairness.voiceAllowed(network:networkSession) else{return};request("a",user:false)\ndefault:request("b",user:false)}}}\n'
    fails(coach, arms, ('sneakySwitch', 'in its own case'), 'a default arm borrowing a case\'s check passed', widen(inventory, 'CheckmateMacPlatform/VoiceCoach.swift', 'sneakySwitch', kind='voice', calls=2, reason='fixture'))
    # A voice request through another receiver is a call.
    fails(coach, voice + '\nextension VoiceCoach {func sneakyCoach(){let coach=self;coach.request("x",user:false)}}\n', ('sneakyCoach',), 'coach.request( passed')
    coach.write_text(voice)
    # Calls in multiline and raw string interpolations are code; a nested comment does not end at its first `*/`.
    for name, body in [('sneakyMultiline', 'print("""\n\\(try await engine!.analyze(fen:"",skill:20,budget:100,multiPv:1))\n""")'),
                       ('sneakyRaw', 'print(#"\\#(try await engine!.analyze(fen:"",skill:20,budget:100,multiPv:1))"#)')]:
        fails(session, session_text + f'\nextension GameSession {{func {name}()async throws {{{body}}}}}\n', (name,), f'{name}: a call in an interpolation was missed')
    fails(session, session_text + '\n/* outer /* inner */ " */\nextension GameSession {func sneakyNested()async throws {_ = try await engine?.analyze(fen:"",skill:20,budget:100,multiPv:1)}}\n', ('sneakyNested',), 'code after a nested comment was missed')
    session.write_text(session_text)
    # Audit round 3. The re-check after the search must come before anything that could deliver: an empty `if`, a
    # result published first, or a publication between a later suspension and the check, are refused.
    fails(assistant, hint.replace(after, 'if (try? self.fairness.requireNetworkHint()) != nil {}', 1), ('again after its last call',), 'an empty if passed as the re-check')
    fails(assistant, hint.replace(after, 'self.thinking=false;' + after, 1), ('again after its last call',), 'a result published before the re-check passed')
    fails(assistant, hint.replace(after, after + ';await Task.yield();self.thinking=false;' + after, 1), ('again after its last call',), 'a publication between a suspension and its re-check passed')
    # A check outside a closure never covers a call inside it (a Task runs later); one inside it does.
    later_call = '_ = try? await self.engine?.analyze(fen:"",skill:20,budget:100,multiPv:1)'
    one = widen(inventory, 'CheckmateApplication/GameSession.swift', 'sneakyLater', kind='guarded', calls=1)
    fails(session, session_text + '\nextension GameSession {func sneakyLater(){try? fairness.requireEngineHelp();guard fairness.engineHelpAllowed else{return};Task{%s}}}\n' % later_call, ('sneakyLater', 'before its first call'), 'a check outside a Task covered the call inside it', one)
    passes(session, session_text + '\nextension GameSession {func sneakyLater(){Task{[fairness] in guard fairness.engineHelpAllowed else{return};%s}}}\n' % later_call, 'a check inside the Task failed', one)
    # A loop whose body suspends needs its check inside the loop, before the call.
    loop = widen(inventory, 'CheckmateApplication/GameSession.swift', 'sneakyLoop', kind='guarded', calls=1)
    fails(session, session_text + '\nextension GameSession {func sneakyLoop()async throws {try fairness.requireEngineHelp();for _ in 0..<2 {try await engine!.prepare()}}}\n', ('sneakyLoop', 'after an earlier await'), 'a second iteration after a suspension passed', loop)
    passes(session, session_text + '\nextension GameSession {func sneakyLoop()async throws {for _ in 0..<2 {try fairness.requireEngineHelp();try await engine!.prepare()}}}\n', 'a check inside the loop failed', loop)
    # A listed caller that suspends in the helper's arguments outlives its check.
    fails(session, session_text.replace(listed, listed.replace('analyzeGame(e,', 'analyzeGame(e,then:await self.loadMoves(),'), 1), ('suspends in its arguments',), 'a caller suspending in its arguments passed')
    # An engine method taken as a value, through any name, is refused unless exempt; prepare included.
    fails(session, session_text + '\nextension GameSession {func sneakyRef()async throws {try fairness.requireEngineHelp();let search=engine!.analyzeHistory;_ = search}}\n', ('sneakyRef', 'passed as a value'), 'an engine method passed as a value passed', widen(inventory, 'CheckmateApplication/GameSession.swift', 'sneakyRef', kind='guarded', calls=1))
    fails(session, session_text + '\nextension GameSession {func sneakyWarm()async throws {let warm=engine!.prepare;try await warm()}}\n', ('sneakyWarm',), 'a prepare reference went uncounted')
    # A check through an optional chain runs nothing when the chain is nil.
    fails(session, session_text + '\nextension GameSession {func sneakyOptional(_ owner:GameSession?)async throws {try owner?.fairness.requireEngineHelp();_ = try await engine?.analyze(fen:"",skill:20,budget:100,multiPv:1)}}\n', ('sneakyOptional', 'before its first call'), 'an optional-chain check passed', widen(inventory, 'CheckmateApplication/GameSession.swift', 'sneakyOptional', kind='guarded', calls=1))
    # An arm that falls through is not exclusive: its suspension reaches the next arm's call.
    fails(session, session_text + branches.replace('sneakyBranches', 'sneakyFall') % f'switch x {{case true:await Task.yield();fallthrough\ndefault:{call}}}', ('sneakyFall', 'after an earlier await'), 'a suspension falling through to a call passed', widen(inventory, 'CheckmateApplication/GameSession.swift', 'sneakyFall', kind='guarded', calls=1))
    # A regex literal holding a quote cannot be lexed with certainty: the file fails rather than hiding the code after it.
    fails(session, session_text + '\nextension GameSession {func sneakyRegex()async throws {let pattern=#/"/#;_ = pattern;_ = try await engine?.analyze(fen:"",skill:20,budget:100,multiPv:1)}}\n', ('cannot be read with certainty',), 'a regex literal hid the call after it')
    # A declaration with any spacing is a declaration, not a call site.
    passes(session, session_text + '\nextension GameSession {func  analyzeHistory(_ unused:Int){}\nfunc\n    request(_ unused:Int){}}\n', 'a declaration spelled with extra spaces counted as a call')
    # A check wrapped in an expression is no statement, whatever its line breaks.
    fails(session, session_text.replace(guard, guard.replace('try fairness.requireEngineHelp()', '_ = try? (\ntry fairness.requireEngineHelp()\n)'), 1), ('chooseOpponentMove',), 'a parenthesised check passed as a statement')
    # A `} default:` on the arm's own line is a label: the case's guard never covers it.
    fails(coach, voice + '\nextension VoiceCoach {func sneakyLabel(_ x:Int){switch x {case 1:guard session.fairness.voiceAllowed(network:networkSession) else{return};request("a",user:false);if x>0{} default:request("b",user:false)}}}\n', ('sneakyLabel', 'in its own case'), 'a same-line default borrowed the case\'s check', widen(inventory, 'CheckmateMacPlatform/VoiceCoach.swift', 'sneakyLabel', kind='voice', calls=2, reason='fixture'))
    session.write_text(session_text)


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
