import XCTest
@testable import CheckmateDomain

final class MiniGameProofTests:XCTestCase {
    static func position(_ kind:MiniGameKind,_ board:Position,turn:String="w",pending:String?=nil,history:[MiniGameSnapshot]=[])->MiniGameState {
        var state=MiniGameState(kind:kind,computer:false);state.snapshot=MiniGameSnapshot(board:board,turn:turn,pendingFinish:pending,cornerIndex:0,lastMove:nil);state.history=history;return state
    }
    static func snapshot(_ board:Position,turn:String)->MiniGameSnapshot {MiniGameSnapshot(board:board,turn:turn,pendingFinish:nil,cornerIndex:0,lastMove:nil)}
    /// An independent statement of the result's meaning: full-width minimax over intervals with the whole history, no
    /// cache. A position not resolved with r plies left can still end anywhere from r+1 plies on, so its interval is
    /// every score at least that far away; a result is exact when its interval is one score.
    static func bruteForce(_ s:MiniGameState,_ r:Int)->MiniGameProofResult {
        let far=1000
        func score(_ s:MiniGameState,_ r:Int)->(Int,Int) {
            if let winner=s.winner{return winner==s.turn ? (far,far):(-far,-far)}
            if s.drawReason != nil{return (0,0)}
            if r==0{return (-(far-1),far-1)}
            func back(_ v:Int)->Int {v>0 ? v-1:v<0 ? v+1:0}
            var low=Int.min,high=Int.min
            for move in MiniGameRules.moves(board:s.board,kind:s.kind,side:s.turn) {
                var child=s;precondition(child.play(move))
                var (childLow,childHigh)=score(child,r-1)
                if childLow != childHigh{(childLow,childHigh)=(-(far-r),far-r)}
                low=max(low,back(-childHigh));high=max(high,back(-childLow))
            }
            return (low,high)
        }
        let (low,high)=score(s,r)
        guard low==high else{return .unknown}
        return low>0 ? .win(plies:far-low):low<0 ? .loss(plies:far+low):.draw
    }
    /// The line is legal move by move, nothing ends before its last move, and the referee then names the claimed winner.
    static func replays(_ state:MiniGameState,_ line:[MiniGameMove],winner:String)->Bool {
        var game=state
        for (index,move) in line.enumerated() {guard !game.isFinished,game.play(move) else{return false};if index<line.count-1,game.isFinished{return false}}
        return game.winner==winner
    }
    /// Small positions of every competitive kind, from a fixed seed.
    static func smallPositions(perKind:Int)->[MiniGameState] {
        var random:UInt64=0x5eed,result:[MiniGameState]=[]
        func next(_ n:Int)->Int {random=random &* 6364136223846793005 &+ 1442695040888963407;return Int((random >> 33) % UInt64(n))}
        let pieces:[MiniGameKind:[String]]=[.pawnDuel:["wp","wp","bp","bp"],.rookSweep:["wr","wp","br","bp","bp"],.rooksAndPawns:["wr","wp","br","bp"],.bishopSweep:["wb","wp","wp","bb","bp","bp"],.bishopsAndPawns:["wb","wp","bb","bp"],.queenVsPawns:["bq","wp","wp"],.knightCapture:["wn","wp","bn","bp"]]
        for kind in MiniGameKind.allCases where !kind.solo {
            var found=0
            while found<perKind {
                var board:Position=[:]
                for piece in pieces[kind]! {
                    var square:String
                    repeat {square=String(UnicodeScalar(97+UInt8(next(8))))+String(piece.hasSuffix("p") ? 2+next(6):1+next(8))} while board[square] != nil
                    board[square]=piece
                }
                let state=position(kind,board,turn:next(2)==0 ? "w":"b")
                if !state.isFinished{result.append(state);found+=1}
            }
        }
        return result
    }

    func testAgreesWithBruteForceOnSmallPositionsCachedAndUncached(){
        var shared:[MiniGameKind:MiniGameProof]=[:],emptied:[MiniGameKind:MiniGameProof]=[:],proved=0
        for state in Self.smallPositions(perKind:6) {
            let horizon=state.kind == .queenVsPawns || state.kind == .bishopSweep ? 3:4,expected=Self.bruteForce(state,horizon)
            var fresh=MiniGameProof(kind:state.kind),cached=shared[state.kind] ?? MiniGameProof(kind:state.kind),small=emptied[state.kind] ?? MiniGameProof(kind:state.kind)
            small.cacheLimit=40
            let alone=fresh.prove(state,historyComplete:true,horizon:horizon),warm=cached.prove(state,historyComplete:true,horizon:horizon),trimmed=small.prove(state,historyComplete:true,horizon:horizon)
            shared[state.kind]=cached;emptied[state.kind]=small
            XCTAssertFalse(alone.exhausted);XCTAssertEqual(alone.result,expected,"\(state.kind) \(state.board) \(state.turn)");XCTAssertEqual(warm.result,expected);XCTAssertEqual(trimmed.result,expected,"a cache emptied between roots")
            switch expected {
            case .win(let plies):proved+=1;XCTAssertEqual(alone.line?.count,plies);XCTAssertTrue(Self.replays(state,alone.line ?? [],winner:state.turn))
            case .loss(let plies):proved+=1;XCTAssertEqual(alone.line?.count,plies);XCTAssertTrue(Self.replays(state,alone.line ?? [],winner:state.turn=="w" ? "b":"w"))
            case .draw,.unknown:break
            }
        }
        XCTAssertGreaterThan(proved,5,"the sample proves something")
    }
    /// Black to move loses in two (White takes the last pawn, or the blocking rook), unless e5–e6 makes a third repetition.
    static let repetition=["a1":"wr","g2":"wp","h2":"wp","e5":"br","a7":"bp"]
    func testImpendingThirdRepetitionIsADraw(){
        let quiet=Self.snapshot(["a1":"wr","g2":"wp","h2":"wp","e6":"br","a7":"bp"],turn:"w")
        let fresh=Self.position(.rookSweep,Self.repetition,turn:"b"),twice=Self.position(.rookSweep,Self.repetition,turn:"b",history:[quiet,quiet])
        var proof=MiniGameProof(kind:.rookSweep)
        XCTAssertEqual(proof.prove(fresh,historyComplete:true).result,.loss(plies:2))
        XCTAssertEqual(proof.prove(twice,historyComplete:true).result,.draw)
        XCTAssertEqual(Self.bruteForce(twice,3),.draw);XCTAssertEqual(Self.bruteForce(fresh,3),.loss(plies:2))
        var game=twice;XCTAssertTrue(game.play(MiniGameMove(from:"e5",to:"e6")));XCTAssertEqual(game.drawReason,"The same position appeared three times.")
    }
    /// 79 quiet plies behind the root: any quiet move is the 80th and draws. The same root with ten quiet plies is lost;
    /// with its earlier history evicted, so the last capture or pawn move cannot be seen, it is unknown.
    func testNoProgressCountAndEvictedHistory(){
        var quiet:[MiniGameSnapshot]=[]
        outer:for white in ["b1","c1","d1","e1","f1","b3","c3","d3","e3","f3"] {for black in ["c4","d4","f4","g4","h4","c6","d6","f6","g6","h6"] {for turn in ["w","b"] {
            quiet.append(Self.snapshot(["g2":"wp","h2":"wp","a7":"bp",white:"wr",black:"br"],turn:turn));if quiet.count==79{break outer}
        }}}
        let capture=Self.snapshot(["a1":"wr","g2":"wp","h2":"wp","e5":"br","a7":"bp","b7":"bp"],turn:"w")
        let long=Self.position(.rookSweep,Self.repetition,turn:"b",history:quiet),short=Self.position(.rookSweep,Self.repetition,turn:"b",history:Array(quiet.suffix(10)))
        XCTAssertNil(long.drawReason)
        var proof=MiniGameProof(kind:.rookSweep)
        XCTAssertEqual(proof.prove(long,historyComplete:true).result,.draw)
        XCTAssertEqual(proof.prove(short,historyComplete:true).result,.loss(plies:2))
        XCTAssertEqual(proof.prove(long,historyComplete:false).result,.unknown,"no capture or pawn move in the kept history")
        XCTAssertEqual(proof.prove(short,historyComplete:false).result,.unknown)
        let seen=Self.position(.rookSweep,Self.repetition,turn:"b",history:[capture]+quiet.suffix(10))
        XCTAssertEqual(proof.prove(seen,historyComplete:false).result,.loss(plies:2),"a capture in the kept history bounds the context")
        XCTAssertEqual(MiniGameProof.drawContext(seen,historyComplete:false)?.count,10)
        var game=long;XCTAssertTrue(game.play(MiniGameMove(from:"e5",to:"e6")));XCTAssertEqual(game.drawReason,"No capture or pawn move for 40 turns.")
    }
    /// White's pawn reaches b8 and wins only if Black cannot take it on the reply.
    func testDelayedPawnFinish(){
        var proof=MiniGameProof(kind:.rooksAndPawns)
        let race=Self.position(.rooksAndPawns,["b7":"wp","h1":"wr","g6":"br","a5":"bp"])
        let answer=proof.prove(race,historyComplete:true)
        XCTAssertEqual(answer.result,.win(plies:2));XCTAssertTrue(Self.replays(race,answer.line ?? [],winner:"w"))
        var arrived=race;XCTAssertTrue(arrived.play(MiniGameMove(from:"b7",to:"b8")));XCTAssertNil(arrived.winner);XCTAssertEqual(arrived.snapshot.pendingFinish,"w")
        XCTAssertEqual(proof.prove(arrived,historyComplete:true).result,.loss(plies:1),"every Black reply leaves the pawn")
        let guarded=Self.position(.rooksAndPawns,["b7":"wp","h1":"wr","g8":"br","a5":"bp"])
        XCTAssertNotEqual(proof.prove(guarded,historyComplete:true).result,.win(plies:2),"Black takes on b8")
        for kind in [MiniGameKind.bishopsAndPawns,.queenVsPawns] {
            var other=MiniGameProof(kind:kind)
            let state=Self.position(kind,kind == .queenVsPawns ? ["b7":"wp","h2":"wp","h8":"bq"]:["b7":"wp","h1":"wb","h8":"bb","a5":"bp"])
            XCTAssertEqual(other.prove(state,historyComplete:true,horizon:3).result,Self.bruteForce(state,3),kind.rawValue)
        }
    }
    func testExhaustedBudgetIsUnknownAndCutOffsAreNeverExact(){
        let race=Self.position(.rooksAndPawns,["b7":"wp","h1":"wr","g6":"br","a5":"bp"])
        var full=MiniGameProof(kind:.rooksAndPawns);let expected=full.prove(race,historyComplete:true)
        XCTAssertEqual(expected.result,.win(plies:2))
        for limit in [0,1,2,4,8,16,32,64,128,256,512] {
            var proof=MiniGameProof(kind:.rooksAndPawns);let answer=proof.prove(race,historyComplete:true,nodeLimit:limit)
            if answer.exhausted{XCTAssertEqual(answer.result,.unknown,"limit \(limit)");XCTAssertNil(answer.line)}else{XCTAssertEqual(answer.result,expected.result,"limit \(limit)")}
            XCTAssertLessThanOrEqual(answer.nodes,limit)
        }
        var opening=MiniGameProof(kind:.rooksAndPawns);let start=opening.prove(MiniGameState(kind:.rooksAndPawns),historyComplete:true,nodeLimit:2_000)
        XCTAssertTrue(start.exhausted);XCTAssertEqual(start.result,.unknown)
        var stopped=MiniGameProof(kind:.rooksAndPawns);let cancelled=stopped.prove(MiniGameState(kind:.rooksAndPawns),historyComplete:true,stop:{true})
        XCTAssertTrue(cancelled.exhausted);XCTAssertEqual(cancelled.result,.unknown);XCTAssertLessThanOrEqual(cancelled.nodes,MiniGameProofBudget.stopInterval)
    }
    /// Codex's fixture: the same board is already won in Rook Sweep (no Black pawn is left) and still being played in
    /// Rooks and Pawns. Each kind has its own cache, so neither order of queries, cold or warm, lets one answer the other.
    func testSameBoardDiffersByKindInEitherOrderColdAndWarm(){
        let board:Position=["a1":"wr","h8":"br","b2":"wp"],horizon=5
        let sweep=Self.position(.rookSweep,board),rooks=Self.position(.rooksAndPawns,board)
        XCTAssertEqual(sweep.winner,"w");XCTAssertFalse(rooks.isFinished)
        var coldSweep=MiniGameProof(kind:.rookSweep),coldRooks=MiniGameProof(kind:.rooksAndPawns)
        let sweepAnswer=coldSweep.prove(sweep,historyComplete:true,horizon:horizon),rooksAnswer=coldRooks.prove(rooks,historyComplete:true,horizon:horizon)
        XCTAssertEqual(sweepAnswer.result,.win(plies:0));XCTAssertNotEqual(rooksAnswer.result,.win(plies:0));XCTAssertFalse(rooksAnswer.exhausted,"the answer is the search's, not its budget's")
        XCTAssertEqual(coldSweep.rulesVersion,MiniGameRules.version);XCTAssertEqual(coldRooks.kind,.rooksAndPawns)
        for sweepFirst in [true,false] {
            var a=MiniGameProof(kind:.rookSweep),b=MiniGameProof(kind:.rooksAndPawns),results:[MiniGameProofAnswer]=[]
            for _ in 0..<2 {  // cold, then warm
                if sweepFirst{results.append(a.prove(sweep,historyComplete:true,horizon:horizon));results.append(b.prove(rooks,historyComplete:true,horizon:horizon))}
                else{let r=b.prove(rooks,historyComplete:true,horizon:horizon);results.append(a.prove(sweep,historyComplete:true,horizon:horizon));results.append(r)}
            }
            XCTAssertEqual(results.map(\.result),[sweepAnswer,rooksAnswer,sweepAnswer,rooksAnswer].map(\.result),"sweep first: \(sweepFirst)")
            XCTAssertEqual(results.map(\.clearPlies),[sweepAnswer,rooksAnswer,sweepAnswer,rooksAnswer].map(\.clearPlies))
        }
    }
    /// A forced win queried too short and long enough, in both orders and from cold and warm caches, answers alike.
    func testHorizonOrderAndCacheNeverChangeAnAnswer(){
        // White's rook takes a7 next move unless Black blocks, and Black's rook cannot reach g2 or h2 in time.
        let state=Self.position(.rookSweep,["a1":"wr","g2":"wp","h2":"wp","e5":"br","a7":"bp","c8":"bp"],turn:"w")
        var reference=MiniGameProof(kind:.rookSweep);let full=reference.prove(state,historyComplete:true)
        guard case .win(let plies)=full.result else{return XCTFail("expected a forced win, got \(full.result)")}
        XCTAssertGreaterThanOrEqual(plies,3);XCTAssertTrue(Self.replays(state,full.line ?? [],winner:"w"))
        let short=plies-1
        var cold=MiniGameProof(kind:.rookSweep);let shortCold=cold.prove(state,historyComplete:true,horizon:short)
        XCTAssertEqual(shortCold.result,.unknown);XCTAssertFalse(shortCold.exhausted);XCTAssertEqual(shortCold.clearPlies,short)
        for shortFirst in [true,false] {
            var proof=MiniGameProof(kind:.rookSweep)
            let order=shortFirst ? [short,plies,short,plies]:[plies,short,plies,short]
            for horizon in order {
                let answer=proof.prove(state,historyComplete:true,horizon:horizon)
                XCTAssertEqual(answer.result,horizon==short ? .unknown:.win(plies:plies),"short first: \(shortFirst), horizon \(horizon)")
                XCTAssertEqual(answer.clearPlies,horizon==short ? short:plies-1)
            }
        }
        if short<=4{XCTAssertEqual(Self.bruteForce(state,short),.unknown)}
    }
    func testReviewFactsAreProvedAndReplay()throws {
        // White to move wins at once by taking the last pawn; instead it plays elsewhere and lets Black win.
        var game=MiniGameState(kind:.rookSweep,computer:true)
        game.snapshot=Self.snapshot(["a1":"wr","h2":"wp","e5":"br","a7":"bp"],turn:"w")
        for move in [("a1","b1"),("e5","h5"),("b1","b2"),("h5","h2")] {XCTAssertTrue(game.play(MiniGameMove(from:move.0,to:move.1)))}
        XCTAssertEqual(game.winner,"b")
        let review=MiniGameReview.run(game,cpuSeconds:{0},stop:{false})
        XCTAssertTrue(review.consistent);XCTAssertTrue(review.complete);XCTAssertEqual(review.answers.count,5)
        XCTAssertEqual(review.facts.map(\.text),["Move 1: you could have won here in 1 move.","Move 1, a1–b1: after this move, the computer could win in 2 moves, whatever you did."])
        let positions=try XCTUnwrap(MiniGameReview.positions(of:game))
        for fact in review.facts {XCTAssertTrue(Self.replays(positions[fact.ply],fact.line,winner:fact.kind == .forcedWin ? fact.side:(fact.side=="w" ? "b":"w")),fact.text)}
        var broken=game;broken.history[2].board["c3"]="wp"
        XCTAssertFalse(MiniGameReview.run(broken,cpuSeconds:{0},stop:{false}).consistent,"a history the referee does not replay proves nothing")
        let stopped=MiniGameReview.run(game,cpuSeconds:{0},stop:{true});XCTAssertFalse(stopped.complete);XCTAssertTrue(stopped.facts.isEmpty)
        // WI-018 (D5): a clock that advances a second on every reading spends the review's CPU budget part-way, and the
        // review stops there, says it is incomplete, and states facts only from the positions it answered.
        var reads=0.0
        let budgeted=MiniGameReview.run(game,cpuSeconds:{reads+=1;return reads},stop:{false})
        XCTAssertFalse(budgeted.complete);XCTAssertTrue(budgeted.consistent);XCTAssertLessThan(budgeted.answers.count,5)
        XCTAssertTrue(budgeted.facts.allSatisfy{budgeted.answers[$0.ply] != nil})
    }
}
