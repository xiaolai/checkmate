// Exact bounded search for Increment B training objectives, run inside the bundled chess.js runtime (plan: Increment B
// objective contracts). One call evaluates one scenario, so a node is one chess.js make-move with no bridge crossing.
//
// Value: material is learner-relative (queen 9, rook 5, bishop 3, knight 3, pawn 1); delta is the resolved leaf minus
// the root. A position satisfies the goal when the learner has mated (always), has not been mated, is not in an
// automatic draw (unless the goal allows draws) and delta >= threshold, with the tracked target still present for survival goals.
// Material scoring (exchange classification, danger) instead judges every leaf by delta alone, a mate or stalemate included.
// The search is AND over the opponent's legal replies and OR over the learner's moves for `plies`, then captures-only
// quiescence in which the side to move may stand pat unless in check (then every legal evasion is searched). Exceeding
// the node cap throws, and nothing partial is ever certified.
var TrainingSearch = (function () {
  var VALUES = { p: 1, n: 3, b: 3, r: 5, q: 9, k: 0 }, EP = 8, KSIDE = 32, QSIDE = 64;
  // chess.js 1.4 internals (the file is pinned by hash; any change revalidates all content): the public move list
  // builds SAN for every move, which plays each move again, so the hot path uses the legal generator directly.
  function generate(chess) { return chess._moves({ legal: true }); }
  function turn(chess) { return chess._turn; }
  function checked(chess) { return chess._isKingAttacked(chess._turn); }
  function square(index) { return 'abcdefgh'[index & 15] + (8 - (index >> 4)); }
  function uci(m) { return square(m.from) + square(m.to) + (m.promotion || ''); }
  function Exhausted() { this.exhausted = true; }
  function balance(chess, learner) {
    var total = 0, board = chess._board;
    for (var i = 0; i < 128; i++) { if (i & 0x88) continue; var p = board[i]; if (p) total += (p.color === learner ? 1 : -1) * VALUES[p.type]; }
    return total;
  }
  function ordered(moves) {
    // Stable order: captures (most valuable victim first), then promotions, then the rest by coordinates.
    return moves.map(function (m) { return { m: m, key: uci(m), weight: m.captured ? VALUES[m.captured] + 10 : (m.promotion ? 5 : 0) }; })
      .sort(function (a, b) { return a.weight !== b.weight ? b.weight - a.weight : (a.key < b.key ? -1 : a.key > b.key ? 1 : 0); })
      .map(function (x) { return x.m; });
  }
  // `material`: scored by material alone, so mate and stalemate are leaves valued by material and no draw is terminal.
  // A cap of zero is an exhausted budget; only a missing cap takes the default.
  function Context(spec) {
    this.learner = spec.learner; this.cap = spec.cap == null ? 32000 : spec.cap; this.nodes = 0;
    this.threshold = spec.goal.threshold; this.survive = spec.goal.kind === 'survive'; this.drawOK = !!spec.goal.drawOK; this.material = !!spec.material;
  }
  Context.prototype.make = function (chess, m) { if (++this.nodes > this.cap) throw new Exhausted(); chess._makeMove(m); };
  function track(target, m, mover, learner) {
    if (target === null) return null;
    var from = square(m.from), to = square(m.to);
    if (mover === learner && from === target) return to;
    // Castling also moves the rook: a tracked rook follows it to the square beside the king.
    if (mover === learner && (m.flags & (KSIDE | QSIDE))) {
      var rookFrom = ((m.flags & KSIDE) ? 'h' : 'a') + from[1];
      return target === rookFrom ? ((m.flags & KSIDE) ? 'f' : 'd') + from[1] : target;
    }
    if (mover !== learner && to === target) return null;
    // En passant removes a pawn that is not on the destination square.
    if (mover !== learner && (m.flags & EP) && target === to[0] + from[1]) return null;
    return target;
  }
  // A position as the app's repetition rule keys it (board, side, castling, en passant as the FEN prints it): the hash,
  // without an en-passant square the FEN omits because no capture there is legal.
  function position(chess) { var h = chess._hash; return chess._epKey() !== 0n && chess.fen().split(' ')[3] === '-' ? h ^ chess._epKey() : h; }
  // How often the current position has occurred since the last irreversible move, counting the scenario's start.
  // The internal make-move keeps no repetition counts, so the reversible tail is walked back and replayed.
  function occurrences(chess) {
    var key = position(chess), count = 1, undone = [], n = Math.min(chess._halfMoves, chess._history.length);
    for (var i = 0; i < n; i++) { undone.push(chess._undoMove()); if (position(chess) === key) count++; }
    while (undone.length) chess._makeMove(undone.pop());
    return count;
  }
  // Terminal positions, null when not terminal. Goal scoring: mate decides by itself, whatever the material (gaining
  // material while being mated fails, delivering mate succeeds); an automatic draw (stalemate, insufficient material,
  // the 75-move rule and fivefold repetition; a claimable draw is not one) satisfies only goals that allow it. Material
  // scoring: a position with no legal move, mate or stalemate alike, is a leaf scored by its resolved material, so the
  // reported delta is the material one; the other draws are not terminal and captures keep resolving.
  // A fifth occurrence needs at least sixteen reversible plies.
  function drawn(chess) { return chess.isInsufficientMaterial() || chess._halfMoves >= 150 || (chess._halfMoves >= 16 && occurrences(chess) >= 5); }
  function terminal(chess, ctx, moves, root, target) {
    if (ctx.material) return moves.length === 0 ? settled(chess, ctx, root, target) : null;
    if (moves.length === 0) return checked(chess) ? turn(chess) !== ctx.learner : ctx.drawOK;
    if (drawn(chess)) return ctx.drawOK;
    return null;
  }
  function settled(chess, ctx, root, target) {
    if (ctx.survive && target === null) return false;
    return balance(chess, ctx.learner) - root >= ctx.threshold;
  }
  function quiet(chess, ctx, root, target) {
    var moves = generate(chess), end = terminal(chess, ctx, moves, root, target); if (end !== null) return end;
    var mine = turn(chess) === ctx.learner;
    if (!checked(chess)) {
      var stand = settled(chess, ctx, root, target);
      if (mine && stand) return true;
      if (!mine && !stand) return false;
      moves = moves.filter(function (m) { return !!m.captured; });
    }
    moves = ordered(moves);
    for (var i = 0; i < moves.length; i++) {
      var m = moves[i], next = track(target, m, turn(chess), ctx.learner);
      ctx.make(chess, m); var ok = quiet(chess, ctx, root, next); chess._undoMove();
      if (mine && ok) return true;
      if (!mine && !ok) return false;
    }
    return !mine;
  }
  function search(chess, ctx, plies, root, target) {
    // At the horizon quiescence generates and judges the same position itself.
    if (plies <= 0) return quiet(chess, ctx, root, target);
    var moves = generate(chess), end = terminal(chess, ctx, moves, root, target); if (end !== null) return end;
    var mine = turn(chess) === ctx.learner;
    moves = ordered(moves);
    for (var i = 0; i < moves.length; i++) {
      var m = moves[i], next = track(target, m, turn(chess), ctx.learner);
      ctx.make(chess, m); var ok = search(chess, ctx, plies - 1, root, next); chess._undoMove();
      if (mine && ok) return true;
      if (!mine && !ok) return false;
    }
    return !mine;
  }
  function find(chess, u) {
    var moves = generate(chess);
    for (var i = 0; i < moves.length; i++) if (uci(moves[i]) === u) return moves[i];
    throw new Error('illegal move ' + u);
  }
  // The scenario position (FEN, then context moves), the root balance there, then `line`: moves already played in
  // this attempt, through which the target is tracked. Every later teaching node is judged against the same root.
  function load(spec) {
    var chess = new exports.Chess(spec.fen);
    (spec.prelude || []).forEach(function (u) { chess._makeMove(find(chess, u)); });
    var state = { chess: chess, root: balance(chess, spec.learner), target: spec.goal && spec.goal.target || null };
    (spec.line || []).forEach(function (u) { var m = find(chess, u); state.target = track(state.target, m, turn(chess), spec.learner); chess._makeMove(m); });
    return state;
  }
  // The opponent to move after a learner move, `depth` plies before quiescence: whether every reply keeps the goal,
  // with the first refuting reply, or (when it holds) the most forcing reply in stable order (null: none to show).
  function reply(chess, ctx, depth, root, target) {
    var answers = generate(chess), end = terminal(chess, ctx, answers, root, target);
    if (end !== null) return { ok: end, reply: null };
    if (depth <= 0 && !checked(chess)) {
      if (!settled(chess, ctx, root, target)) return { ok: false, reply: null };
      answers = answers.filter(function (m) { return !!m.captured; });
    }
    answers = ordered(answers);
    for (var j = 0; j < answers.length; j++) {
      var a = answers[j], after = track(target, a, turn(chess), ctx.learner);
      ctx.make(chess, a); var good = depth <= 0 ? quiet(chess, ctx, root, after) : search(chess, ctx, depth - 1, root, after); chess._undoMove();
      if (!good) return { ok: false, reply: uci(a) };
    }
    return { ok: true, reply: answers.length ? uci(answers[0]) : null };
  }
  // The complete classification of the learner's moves at one teaching node (`plies` from here, learner to move):
  // every legal move is accepted or rejected, each with the reply to demonstrate.
  function evaluate(spec) {
    var state = load(spec), chess = state.chess, ctx = new Context(spec), plies = spec.plies || 3;
    if (turn(chess) !== spec.learner) throw new Error('the learner must be to move');
    var accepted = [], rejected = [], replies = {};
    try {
      var moves = ordered(generate(chess));
      for (var i = 0; i < moves.length; i++) {
        var m = moves[i], target = track(state.target, m, spec.learner, spec.learner);
        ctx.make(chess, m); var result = reply(chess, ctx, plies - 1, state.root, target); chess._undoMove();
        (result.ok ? accepted : rejected).push(uci(m));
        if (result.reply) replies[uci(m)] = result.reply;
      }
    } catch (e) {
      if (e instanceof Exhausted) return { exhausted: true, nodes: ctx.nodes };
      throw e;
    }
    return { exhausted: false, nodes: ctx.nodes, accepted: accepted.sort(), rejected: rejected.sort(), replies: replies };
  }
  // Whether the goal holds after `line` with `plies` left, whichever side is to move: a published reply is checked
  // with this (a refutation must make it false, a testing reply must keep it true).
  function holds(spec) {
    var state = load(spec), ctx = new Context(spec);
    try { return { exhausted: false, holds: search(state.chess, ctx, spec.plies, state.root, state.target), nodes: ctx.nodes }; }
    catch (e) { if (e instanceof Exhausted) return { exhausted: true, nodes: ctx.nodes }; throw e; }
  }
  // The same recurrence with no cut-offs, for reference checks on tiny boards.
  function brute(spec) {
    var state = load(spec), chess = state.chess, ctx = new Context(spec), root = state.root, plies = spec.plies || 3;
    function full(depth, target) {
      var moves = generate(chess), end = terminal(chess, ctx, moves, root, target); if (end !== null) return end;
      if (depth === 0) return quietFull(target);
      var mine = turn(chess) === ctx.learner, results = [];
      moves.forEach(function (m) { var next = track(target, m, turn(chess), ctx.learner); ctx.make(chess, m); results.push(full(depth - 1, next)); chess._undoMove(); });
      return mine ? results.some(Boolean) : results.every(Boolean);
    }
    function quietFull(target) {
      var moves = generate(chess), end = terminal(chess, ctx, moves, root, target); if (end !== null) return end;
      var mine = turn(chess) === ctx.learner, check = checked(chess), results = [];
      if (!check) { results.push(settled(chess, ctx, root, target)); moves = moves.filter(function (m) { return !!m.captured; }); }
      moves.forEach(function (m) { var next = track(target, m, turn(chess), ctx.learner); ctx.make(chess, m); results.push(quietFull(next)); chess._undoMove(); });
      if (!check) { var stand = results.shift(); var rest = results; return mine ? (stand || rest.some(Boolean)) : (stand && rest.every(Boolean)); }
      return mine ? results.some(Boolean) : results.every(Boolean);
    }
    var accepted = [];
    generate(chess).forEach(function (m) {
      var target = track(state.target, m, spec.learner, spec.learner);
      ctx.make(chess, m); if (full(plies - 1, target)) accepted.push(uci(m)); chess._undoMove();
    });
    return { accepted: accepted.sort(), nodes: ctx.nodes };
  }
  // The sign of a stated line's resolved material change: play the line, then resolve captures by the same rules,
  // scored by material alone (a line ending in mate or stalemate is ahead, even or behind by its material).
  function exchange(spec) {
    var state = load(spec), chess = state.chess, root = state.root, ctx, used;
    spec.stated.forEach(function (u) { chess._makeMove(find(chess, u)); });
    try {
      ctx = new Context({ learner: spec.learner, cap: spec.cap, material: true, goal: { kind: 'gain', threshold: 1 } });
      if (quiet(chess, ctx, root, null)) return { exhausted: false, sign: 1, nodes: ctx.nodes };
      used = ctx.nodes;
      ctx = new Context({ learner: spec.learner, cap: ctx.cap - used, material: true, goal: { kind: 'gain', threshold: 0 } });
      return { exhausted: false, sign: quiet(chess, ctx, root, null) ? 0 : -1, nodes: used + ctx.nodes };
    } catch (e) { if (e instanceof Exhausted) return { exhausted: true }; throw e; }
  }
  function mated(chess) { return checked(chess) && generate(chess).length === 0; }
  function mates(chess, ctx) {
    var out = [];
    generate(chess).forEach(function (m) { ctx.make(chess, m); if (mated(chess)) out.push(uci(m)); chess._undoMove(); });
    return out.sort();
  }
  // The side to move with its turn passed (no en passant then); null when it is in check and cannot pass.
  function passed(chess) {
    if (checked(chess)) return null;
    var parts = chess.fen().split(' ');
    parts[1] = parts[1] === 'w' ? 'b' : 'w'; parts[3] = '-';
    try { return new exports.Chess(parts.join(' ')); } catch (e) { return null; }
  }
  // The side not to move "threatens mate" when, if the side to move could pass, it would have a mate in one.
  function threatened(chess, ctx) { var other = passed(chess); return !!other && mates(other, ctx).length > 0; }
  // Create: learner moves that mate at once or leave a mate-in-one threat (never a stalemate, which ends the game).
  // Prevent: the opponent threatens mate now; learner moves after which the opponent has no mate in one (or the game
  // is an automatic draw), each rejected move with its mating reply. Every make-move counts against the node cap.
  function threat(spec) {
    var chess = load(spec).chess, ctx = new Context(spec), accepted = [], rejected = [], replies = {}, opponentThreat;
    try {
      opponentThreat = threatened(chess, ctx);
      generate(chess).forEach(function (m) {
        ctx.make(chess, m);
        var ok, answer = null;
        if (mated(chess)) ok = true;
        else if (spec.kind === 'create') ok = !checked(chess) && generate(chess).length > 0 && threatened(chess, ctx);
        // A move into an automatic draw ends the game there, so no mate can follow.
        else if (drawn(chess)) ok = true;
        else { var found = mates(chess, ctx); ok = found.length === 0; answer = found[0] || null; }
        chess._undoMove();
        (ok ? accepted : rejected).push(uci(m));
        if (answer) replies[uci(m)] = answer;
      });
    } catch (e) { if (e instanceof Exhausted) return { exhausted: true, nodes: ctx.nodes }; throw e; }
    return { exhausted: false, nodes: ctx.nodes, accepted: accepted.sort(), rejected: rejected.sort(), replies: replies, opponentThreat: opponentThreat };
  }
  // Whether one of the learner's pieces is in danger: with the learner's turn passed, the opponent wins material
  // (at least a pawn) by captures alone, resolved by the same quiescence and scored by material alone, so a capture
  // that leaves too little material to mate still wins the piece. Null when the learner is in check.
  function danger(spec) {
    var state = load(spec), other = passed(state.chess);
    if (!other) return { exhausted: false, danger: null };
    var opponent = spec.learner === 'w' ? 'b' : 'w', ctx = new Context({ learner: opponent, cap: spec.cap, material: true, goal: { kind: 'gain', threshold: 1 } });
    try { return { exhausted: false, danger: quiet(other, ctx, balance(other, opponent), null), nodes: ctx.nodes }; }
    catch (e) { if (e instanceof Exhausted) return { exhausted: true }; throw e; }
  }
  return { evaluate: evaluate, holds: holds, brute: brute, exchange: exchange, threat: threat, danger: danger };
})();
