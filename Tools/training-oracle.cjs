#!/usr/bin/env node
// Authoring aid only: prints what the bundled chess.js says about candidate training positions, so an author can
// compare it with the answer they intended. Publication never trusts this output; the Swift validator re-derives
// every answer. Input: JSON array of {id, fen, prelude?} on stdin. Output: one JSON object per position.
'use strict';
const fs = require('fs');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'CheckmateCore', 'Resources', 'chess.js'), 'utf8');
const sandbox = { exports: {} };
new Function('exports', source)(sandbox.exports);
const { Chess } = sandbox.exports;
const positions = JSON.parse(fs.readFileSync(0, 'utf8'));
if (!Array.isArray(positions)) throw new Error('input must be a JSON array of positions');
const UCI = /^[a-h][1-8][a-h][1-8][qrbn]?$/;
for (const item of positions) {
  const result = { id: item && typeof item === 'object' ? item.id : null };
  try {
    // An entry names its own board: chess.js would otherwise silently use the starting position.
    if (!item || typeof item !== 'object' || Array.isArray(item)) throw new Error('each position must be an object');
    if (typeof item.fen !== 'string' || !item.fen.trim()) throw new Error('fen must be a nonempty string');
    const prelude = item.prelude ?? [];
    if (!Array.isArray(prelude) || !prelude.every((uci) => typeof uci === 'string' && UCI.test(uci))) throw new Error('prelude must be an array of UCI moves');
    const game = new Chess(item.fen);
    // chess.js ignores a promotion letter on a move that does not promote, so the played move must spell the input.
    for (const uci of prelude) {
      const played = game.move({ from: uci.slice(0, 2), to: uci.slice(2, 4), promotion: uci[4] });
      if (played.lan !== uci) throw new Error(`prelude move ${uci} is played as ${played.lan}`);
    }
    const moves = game.moves({ verbose: true });
    const outcome = (m) => { const after = new Chess(m.after); return { uci: m.from + m.to + (m.promotion || ''), check: after.isCheck(), mate: after.isCheckmate() }; };
    const all = moves.map(outcome);
    const turn = game.turn();
    const king = game.board().flat().find((p) => p && p.color === turn && p.type === 'k');
    result.fen = game.fen();
    result.turn = turn;
    result.status = game.isCheckmate() ? 'checkmate' : game.isStalemate() ? 'stalemate' : game.isCheck() ? 'check' : 'neither';
    result.legal = all.length;
    result.mates = all.filter((m) => m.mate).map((m) => m.uci).sort();
    result.evasions = game.isCheck() ? all.map((m) => m.uci).sort() : [];
    result.kingSquares = [...new Set(moves.filter((m) => m.from === king.square && !m.flags.includes('k') && !m.flags.includes('q')).map((m) => m.to))].sort();
    result.checks = all.filter((m) => m.check && !m.mate).map((m) => m.uci).sort();
    result.san = Object.fromEntries(moves.map((m) => [m.from + m.to + (m.promotion || ''), m.san]));
  } catch (error) {
    result.error = String(error.message || error);
  }
  process.stdout.write(JSON.stringify(result) + '\n');
}
