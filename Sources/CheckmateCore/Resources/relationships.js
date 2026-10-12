// Piece relationships for one square: which pieces cover it, which enemy pieces can capture on it, and whether each
// capture can be answered. Evaluated by ChessRules.relationships inside the chess.js runtime, which supplies `exports`.
// The caller passes the live game; it is only read (its FEN seeds a private copy), never moved or reset.
// An authored partial diagram supplies geometry only: no legal context, so every relation reports plain coverage.

// The position to inspect: the live game's position, or the authored diagram placed on an empty board.
function relationshipPosition(input,liveGame){
    const g=new exports.Chess(liveGame.fen());
    if(input.diagram){g.clear();for(const [sq,p] of Object.entries(input.diagram)){if(!g.put({color:p[0],type:p[1]},sq))throw Error('invalid diagram')}}
    return g;
}

// The position with `enemy` to move; a changed side to move invalidates the en passant square.
function enemyToMove(g,enemy){
    const fields=g.fen().split(' ');
    if(fields[1]!==enemy){fields[1]=enemy;fields[3]='-'}
    return new exports.Chess(fields.join(' '));
}

// Every enemy capture of the piece on `square`, including an en passant capture of a pawn standing there.
function hypotheticalCaptures(g,square,enemy){
    return enemyToMove(g,enemy).moves({verbose:true}).filter(m=>m.captured && (m.to===square || (m.flags.includes('e') && m.to[0]+m.from[1]===square)));
}

// For each capture, the captured side's legal recaptures on the capturing square.
function recaptureResponses(g,captures,enemy){
    return captures.map(m=>{const after=enemyToMove(g,enemy);after.move({from:m.from,to:m.to,promotion:m.promotion||'q'});const replies=after.moves({verbose:true}).filter(r=>r.to===m.to && r.captured);return {move:m,replies}});
}

// Pieces to report: geometric attackers of the square, plus legal capturers (attacked) or legal recapturers (protected).
function relationSources(input,geometric,captures,responses){
    const sources=new Set(geometric);
    if(input.mode==='protected')for(const r of responses)for(const reply of r.replies)sources.add(reply.from);
    else for(const m of captures)sources.add(m.from);
    return sources;
}

// Whether the piece on `from` could step onto `square` (as if the piece there were taken) without leaving its own king attacked.
function coverageKeepsKingSafe(g,square,from,own,enemy,legalContext){
    const test=new exports.Chess(g.fen(),{skipValidation:!legalContext}),piece=test.get(from);
    test.remove(square);test.remove(from);test.put(piece,square);
    const k=test.board().flat().find(p=>p&&p.color===own&&p.type==='k');
    return !!k&&!test.isAttacked(k.square,enemy);
}

// An attacker's legal captures of the square: available when it has one, restricted when it only covers the square.
function attackerRelation(from,piece,captures){
    const moves=captures.filter(m=>m.from===from);
    return {
        status:moves.length?'available':'restricted',
        enPassant:moves.some(m=>m.flags.includes('e')),
        replies:moves.map(m=>({attackerSquare:from,attackerPiece:piece.type,captureSAN:m.san,destination:m.to,canRecapture:false,recaptures:[]}))
    };
}

// A defender's recaptures across every enemy capture: available when it answers all, conditional when only some,
// restricted when none. With no capture to answer, it is restricted only if covering the square would expose its king.
function defenderRelation(g,input,from,responses,own,enemy,legalContext){
    const replies=responses.map(r=>({attackerSquare:r.move.from,attackerPiece:r.move.piece,captureSAN:r.move.san,destination:r.move.to,canRecapture:r.replies.some(m=>m.from===from),recaptures:r.replies.filter(m=>m.from===from).map(m=>m.san)}));
    let status='coverage';
    if(replies.length){const count=replies.filter(r=>r.canRecapture).length;status=count===replies.length?'available':count?'conditional':'restricted'}
    else if(!coverageKeepsKingSafe(g,input.square,from,own,enemy,legalContext))status='restricted';
    return {status,enPassant:false,replies};
}

// The relationship report for `input` ({square, mode: 'protected' | 'attacked', diagram | null}).
function relationships(input,liveGame){
    const g=relationshipPosition(input,liveGame);
    const selected=g.get(input.square);if(!selected)throw Error('no piece');
    const own=selected.color,enemy=own==='w'?'b':'w',legalContext=!input.diagram,king=selected.type==='k';
    const captures=legalContext&&!king ? hypotheticalCaptures(g,input.square,enemy) : [];
    const responses=recaptureResponses(g,captures,enemy);
    const geometric=g.attackers(input.square,input.mode==='protected'?own:enemy);
    const relations=[...relationSources(input,geometric,captures,responses)].sort().map(from=>{
        const p=g.get(from),coverage=geometric.includes(from);
        let status='coverage',replies=[],enPassant=false;
        if(legalContext&&!king){
            const relation=input.mode==='attacked' ? attackerRelation(from,p,captures) : defenderRelation(g,input,from,responses,own,enemy,legalContext);
            status=relation.status;replies=relation.replies;enPassant=relation.enPassant;
        }
        return {square:from,piece:p.type,color:p.color,status,coverage,enPassant,responses:replies};
    });
    return {square:input.square,piece:selected.type,color:own,mode:input.mode,legalContext,relations};
}
