import XCTest
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules

/// The network game on the real rules: `ChessRules`' conformance, the D6 flag exceptions on real positions, replaying
/// a finished game to its final hash, and a 2,000-ply snapshot.
final class NetworkRulesTests:XCTestCase {
    private let hashing=NetworkHashing(reviewHash)
    func testTheConformanceReadsLegalityFromTheRules()throws {
        let rules=try ChessRules()
        XCTAssertEqual(try rules.networkFEN(),"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");XCTAssertEqual(try rules.networkSideToMove(),.white)
        XCTAssertEqual(try rules.networkPlay(uci:"g1f3"),NetworkPlayedMove(uci:"g1f3",san:"Nf3"));XCTAssertEqual(try rules.networkSideToMove(),.black)
        for uci in ["e7e4","e2e4","g8f6q","zz11"] {XCTAssertThrowsError(try rules.networkPlay(uci:uci),uci){XCTAssertEqual($0 as? NetworkRulesError,.illegalMove,uci)}}
        XCTAssertEqual(rules.history,["Nf3"],"an illegal move leaves the game as it was")
        let promotion=try ChessRules(fen:"8/4P1k1/8/8/8/8/8/4K3 w - - 0 1")
        XCTAssertThrowsError(try promotion.networkPlay(uci:"e7e8"),"a promotion names its piece")
        XCTAssertEqual(try promotion.networkPlay(uci:"e7e8n"),NetworkPlayedMove(uci:"e7e8n",san:"e8=N+"))
        XCTAssertFalse(try rules.networkPGN().isEmpty)
        XCTAssertThrowsError(try ChessRules().networkLoad(pgn:"1. e4 Ke7 Ke2 *"),"an impossible record does not load")
        let copy=try ChessRules();try copy.networkLoad(pgn:try rules.networkPGN());XCTAssertEqual(try copy.networkFEN(),try rules.networkFEN())
    }
    func testAutomaticEndingsAndClaimableDrawsMapExactly()throws {
        let mate=try ChessRules()
        for uci in ["f2f3","e7e5","g2g4"] {_ = try mate.networkPlay(uci:uci);XCTAssertNil(try mate.networkAutomaticEnding())}
        _ = try mate.networkPlay(uci:"d8h4");XCTAssertEqual(try mate.networkAutomaticEnding(),.checkmate(winner:.black))
        XCTAssertEqual(try ChessRules(fen:"7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").networkAutomaticEnding(),.stalemate)
        XCTAssertEqual(try ChessRules(fen:"8/8/8/8/8/8/2k5/K7 w - - 0 1").networkAutomaticEnding(),.insufficientMaterial)
        let seventyFive=try ChessRules(fen:"8/8/8/8/8/8/1k6/R3K3 w - - 149 80")
        XCTAssertEqual(try seventyFive.networkClaimableDraw(),.fiftyMoves);XCTAssertNil(try seventyFive.networkAutomaticEnding())
        _ = try seventyFive.networkPlay(uci:"e1e2");XCTAssertEqual(try seventyFive.networkAutomaticEnding(),.seventyFiveMoves)
        let repeated=try ChessRules()
        for cycle in 1...4 {
            for uci in ["g1f3","g8f6","f3g1","f6g8"] {_ = try repeated.networkPlay(uci:uci)}
            if cycle==2 {XCTAssertEqual(try repeated.networkClaimableDraw(),.repetition);XCTAssertNil(try repeated.networkAutomaticEnding(),"threefold is claimed, never automatic")}
        }
        XCTAssertEqual(try repeated.networkAutomaticEnding(),.fivefold)
        XCTAssertNil(try ChessRules().networkClaimableDraw())
    }
    func testABareKingFlagIsADrawButAPossibleMateLoses()throws {
        XCTAssertTrue(try ChessRules(fen:"4k3/8/8/8/8/8/8/4K2Q w - - 0 1").networkHasOnlyKing(.black))
        XCTAssertFalse(try ChessRules(fen:"4k3/8/8/8/8/8/8/4K2Q w - - 0 1").networkHasOnlyKing(.white))
        // White, with a queen, lets its time run out against a bare king: a draw.
        let bare=try RulesNetwork(fen:"4k3/8/8/8/8/8/8/4K2Q w - - 0 1",hostSide:.white,timeControl:.threePlusTwo,hashing:hashing)
        let guest=try bare.join(.guest(claimID:NetworkSecret.random(using:.system)),name:"Ben")
        try bare.hostPlays("h1h2");try bare.play(guest,"e8d8")
        try bare.flagFalls(after:181)
        XCTAssertEqual(bare.host.outcome,NetworkOutcome(result:.draw,termination:.time));XCTAssertEqual(bare.receivers[guest].outcome,bare.host.outcome)
        // chess.js documents mates with a lone minor piece against one (its isInsufficientMaterial comments), so a
        // material count cannot say "this side cannot mate": the flag loses.
        for fen in ["8/8/8/8/1b6/8/B1k5/K7 b - - 0 1","8/8/8/8/1n6/8/B7/K1k5 b - - 2 1"] {
            let rules=try ChessRules(fen:fen)
            XCTAssertNil(try rules.networkAutomaticEnding(),fen);XCTAssertFalse(try rules.networkHasOnlyKing(.white));XCTAssertFalse(try rules.networkHasOnlyKing(.black))
            let net=try RulesNetwork(fen:fen,hostSide:.black,timeControl:.threePlusTwo,hashing:hashing)
            _ = try net.join(.guest(claimID:NetworkSecret.random(using:.system)),name:"Ben")
            try net.hostPlays(fen.contains("1b6") ? "b4a5":"b4d5")
            try net.flagFalls(after:181)
            XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.blackWins,termination:.time),fen)
        }
    }
    func testAFinishedGameReplaysToItsFinalHashWithHeadersMatchingEnded()throws {
        let net=try RulesNetwork(fen:nil,hostSide:.white,timeControl:.fivePlusThree,hashing:hashing)
        let guest=try net.join(.guest(claimID:NetworkSecret.random(using:.system)),name:"Ben"),watcher=try net.join(.spectator,name:"Cy")
        try net.hostPlays("f2f3");try net.play(guest,"e7e5");try net.hostPlays("g2g4");try net.play(guest,"d8h4")
        let outcome=NetworkOutcome(result:.blackWins,termination:.checkmate)
        XCTAssertEqual(net.host.outcome,outcome);XCTAssertEqual(net.host.revision,5)
        for index in [guest,watcher] {
            let receiver=net.receivers[index]
            XCTAssertEqual(receiver.outcome,outcome);XCTAssertEqual(receiver.revision,5);XCTAssertEqual(receiver.fen,net.host.fen)
            let record=try XCTUnwrap(try receiver.publicGame(at:net.now))
            let replay=try ChessRules();try replay.networkLoad(pgn:record.pgn)
            XCTAssertEqual(hashing.positionHash(fen:try replay.networkFEN(),revision:record.revision),net.host.positionHash,"the record replays to the host's final hash")
            let headers=Dictionary(uniqueKeysWithValues:record.recordHeaders(date:"2026.10.16").map{($0.name,$0.value)})
            XCTAssertEqual(headers["Result"],"0-1");XCTAssertEqual(headers["Termination"],"Checkmate");XCTAssertEqual(headers["White"],"Ana");XCTAssertEqual(headers["Black"],"Ben");XCTAssertEqual(headers["TimeControl"],"300+3")
        }
        XCTAssertEqual(net.host.positionHash.count,64,"SHA-256 in hex");XCTAssertNoThrow(try NetworkCodec.encode(.snapshotBegin(snapshotID:NetworkID.random(using:.system),revision:5,hash:net.host.positionHash,totalBytes:1,parts:1)))
    }
    /// A snapshot is this game only if its record extends the receiver's own start, here the initial position, and its
    /// revision counts exactly its moves (and the end): a record that sets up another position, or a revision that
    /// would misplace assisted plies, is refused before anything is installed.
    func testASnapshotMustExtendTheStartAndCountItsMoves()throws {
        let standard=NetworkRulesFactory{try ChessRules()},gameID=NetworkGameID.random(using:.system)
        func install(_ rules:ChessRules,revision:Int,outcome:NetworkOutcome?=nil)throws {
            let pgn=try rules.networkPGN(),hash=hashing.positionHash(fen:try rules.networkFEN(),revision:revision)
            let game=NetworkPublicGame(gameID:gameID,revision:revision,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:pgn,clocks:nil,openOffer:nil,outcome:outcome)
            _ = try NetworkSnapshotInstaller.install(try JSONEncoder().encode(game),revision:revision,hash:hash,gameID:gameID,rules:standard,hashing:hashing)
        }
        func refused(_ reason:String,_ work:()throws->Void,file:StaticString=#filePath,line:UInt=#line){
            XCTAssertThrowsError(try work(),file:file,line:line){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot(reason),file:file,line:line)}
        }
        let played=try ChessRules();_ = try played.networkPlay(uci:"e2e4")
        XCTAssertNoThrow(try install(played,revision:1),"one move at revision 1")
        refused("revision"){try install(played,revision:2)}
        refused("revision"){try install(played,revision:1,outcome:NetworkOutcome(result:.whiteWins,termination:.resignation))}
        XCTAssertNoThrow(try install(played,revision:2,outcome:NetworkOutcome(result:.whiteWins,termination:.resignation)),"and the end at revision 2")
        let setUp=try ChessRules(fen:"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1");_ = try setUp.networkPlay(uci:"e2e4")
        XCTAssertTrue(try setUp.networkPGN().contains("[FEN "),"a set-up record names its start")
        refused("start"){try install(setUp,revision:1)}
    }
    func testATwoThousandPlySnapshotRoundTrips()throws {
        let pgn=try Self.longGame(plies:2_000)
        let built=try ChessRules();try built.networkLoad(pgn:pgn)
        XCTAssertEqual(built.history.count,2_000);XCTAssertNil(try built.networkAutomaticEnding(),"a game still in progress")
        let net=try RulesNetwork(pgn:pgn,hashing:hashing)
        let watcher=try net.join(.spectator,name:"Cy")
        let receiver=net.receivers[watcher]
        XCTAssertEqual(receiver.revision,0);XCTAssertEqual(receiver.fen,try built.networkFEN());XCTAssertEqual(receiver.fen,net.host.fen)
        let frames=net.sent.values.joined()
        XCTAssertTrue(frames.allSatisfy{$0.count<=NetworkLimits.maximumMessageBytes})
        XCTAssertGreaterThan(frames.filter{if case .snapshotPart?=try? NetworkCodec.decode($0) {return true};return false}.count,1,"more than one part")
    }
    /// The same long record sent to a receiver whose own game starts at the initial position: every one of its 2,000
    /// moves is replayed and installed, not preloaded.
    func testATwoThousandPlySnapshotInstallsOnAFreshReceiver()throws {
        let pgn=try Self.longGame(plies:2_000),built=try ChessRules();try built.networkLoad(pgn:pgn)
        let gameID=NetworkGameID.random(using:.system),fen=try built.networkFEN()
        let game=NetworkPublicGame(gameID:gameID,revision:2_000,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:pgn,clocks:nil,openOffer:nil,outcome:nil)
        let installed=try NetworkSnapshotInstaller.install(try JSONEncoder().encode(game),revision:2_000,hash:hashing.positionHash(fen:fen,revision:2_000),gameID:gameID,rules:NetworkRulesFactory{try ChessRules()},hashing:hashing)
        XCTAssertEqual(installed.game.revision,2_000);XCTAssertEqual(installed.fen,fen);XCTAssertEqual(try installed.rules.networkFEN(),fen)
        XCTAssertEqual(try installed.rules.networkMoves(),try built.networkMoves(),"all 2,000 moves, played afresh");XCTAssertEqual(installed.moves.count,2_000)
    }
    /// A record that sets up another start can reach the same position by the same squares while claiming other moves:
    /// here a knight "captures" a queen that the real start never had. The board installed is the one played from the
    /// receiver's own start, so the invented capture never reaches the record, Review or the coach.
    func testARecordFromAnotherStartKeepsOnlyTheMovesPlayedFromThisOne()throws {
        let forgedStart=try ChessRules(fen:"rnbqkbnr/pppppppp/8/8/8/2q5/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        _ = try forgedStart.networkPlay(uci:"b1c3");_ = try forgedStart.networkPlay(uci:"e7e5")
        let honest=try ChessRules();_ = try honest.networkPlay(uci:"b1c3");_ = try honest.networkPlay(uci:"e7e5")
        XCTAssertEqual(try forgedStart.networkFEN(),try honest.networkFEN(),"the two starts converge");XCTAssertTrue(try forgedStart.networkPGN().contains("Nxc3"))
        let gameID=NetworkGameID.random(using:.system),pgn=try forgedStart.networkPGN()
        let game=NetworkPublicGame(gameID:gameID,revision:2,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:pgn,clocks:nil,openOffer:nil,outcome:nil)
        let installed=try NetworkSnapshotInstaller.install(try JSONEncoder().encode(game),revision:2,hash:hashing.positionHash(fen:try honest.networkFEN(),revision:2),gameID:gameID,rules:NetworkRulesFactory{try ChessRules()},hashing:hashing)
        let record=try installed.rules.networkPGN()
        XCTAssertFalse(record.contains("Nxc3"),"no invented capture");XCTAssertFalse(record.contains("[FEN "),"no other start");XCTAssertTrue(record.contains("Nc3"))
    }
    /// A draw by threefold repetition is claimable when the position has stood three times. An en passant square the
    /// pawn cannot take, because it is pinned to its king, does not make the first of those positions a different one.
    func testThreefoldIgnoresAnEnPassantCaptureThePinForbids()throws {
        let rules=try ChessRules(fen:"1n2r1k1/3p4/8/4P3/8/8/8/4K1N1 b - - 0 1")
        for uci in ["d7d5","g1f3","b8c6","f3g1","c6b8","g1f3","b8c6","f3g1","c6b8"] {_ = try rules.networkPlay(uci:uci)}
        XCTAssertEqual(try rules.networkClaimableDraw(),.repetition,"the position after d5 has stood three times")
        XCTAssertTrue(rules.threefoldRepetition)
    }
    /// A legal 2,000-ply game, still in progress: a seeded walk in chess.js that tries one random move at a time, avoids
    /// mate, stalemate, insufficient material and a third repetition, and pushes a pawn or captures well inside every 75
    /// moves.
    static func longGame(plies:Int)throws -> String {
        try JavaScriptCoreChessRuntime().evaluate("""
        (()=>{const g=new exports.Chess();let seed=20261016,count=0;const next=n=>{seed=(seed*1103515245+12345)%2147483648;return seed%n};
        const key=f=>f.split(' ').slice(0,4).join(' ');let seen=new Map([[key(g.fen()),1]]);
        const pawn=s=>/^[a-h]/.test(s),fits=s=>{g.move(s);const ok=!g.isCheckmate()&&!g.isStalemate()&&!g.isInsufficientMaterial()&&(seen.get(key(g.fen()))||0)<2;g.undo();return ok};
        while(count<\(plies)){const half=Number(g.fen().split(' ')[4]),all=g.moves(),captures=all.filter(s=>s.includes('x')),pushes=all.filter(s=>!s.includes('x')&&pawn(s)),quiet=all.filter(s=>!s.includes('x')&&!pawn(s));
        let chosen=null;for(const pool of half>=90?[pushes,captures,quiet]:[quiet,pushes,captures]){const order=pool.slice();while(order.length&&chosen===null){const s=order.splice(next(order.length),1)[0];if(fits(s))chosen=s}if(chosen!==null)break}
        if(chosen===null)throw new Error('stuck');const progress=chosen.includes('x')||pawn(chosen);g.move(chosen);count++;const k=key(g.fen());if(progress)seen=new Map();seen.set(k,(seen.get(k)||0)+1)}
        return g.pgn()})()
        """)
    }
}
/// A host on real rules with real receivers, wired in memory: every send completes at once, and time moves only when
/// a test says so.
private final class RulesNetwork {
    let host:NetworkHost,gameID:NetworkGameID,hashing:NetworkHashing
    /// The game's start, for the host and every receiver alike: a snapshot extends the receiver's own new game.
    let rules:NetworkRulesFactory
    var now=NetworkInstant.origin
    var receivers:[NetworkReceiver]=[],connections:[NetworkConnectionID]=[],cursors:[Int]=[]
    var sent:[NetworkConnectionID:[Data]]=[:]
    init(fen:String?=nil,pgn:String?=nil,hostSide:NetworkSide = .white,timeControl:NetworkTimeControl = .untimed,hashing:NetworkHashing)throws {
        self.hashing=hashing;gameID=NetworkGameID.random(using:.system)
        let rules=NetworkRulesFactory{let rules=try ChessRules(fen:fen);if let pgn {try rules.networkLoad(pgn:pgn)};return rules};self.rules=rules
        host=try NetworkHost(gameID:gameID,runEpoch:NetworkID.random(using:.system),settings:NetworkHostSettings(hostName:"Ana",hostSide:hostSide,timeControl:timeControl),rules:rules,hashing:hashing,at:now)
    }
    func take(_ effects:[NetworkHostEffect])throws {
        var pending=effects
        while !pending.isEmpty {if case .transmit(let id,let data)=pending.removeFirst() {sent[id,default:[]].append(data);pending+=try host.sendCompleted(id,at:now)}}
    }
    func join(_ role:NetworkReceiverRole,name:String)throws -> Int {
        let receiver=NetworkReceiver(gameID:gameID,role:role,name:name,appVersion:"0.8.0",rules:rules,hashing:hashing)
        let accepted=try host.accept(role == .spectator ? .watch:.seat,at:now)
        receivers.append(receiver);connections.append(accepted.connection);cursors.append(0)
        try take(accepted.effects);try toHost(receivers.count-1,receiver.opening());return receivers.count-1
    }
    func toHost(_ index:Int,_ message:NetworkMessage?)throws {
        guard let message else{return XCTFail("nothing to send")}
        try take(try host.receive(try NetworkCodec.encode(message),from:connections[index],at:now));try deliver()
    }
    func deliver()throws {
        for index in receivers.indices {
            while cursors[index]<(sent[connections[index]]?.count ?? 0) {
                let data=sent[connections[index]]![cursors[index]];cursors[index]+=1
                let output=try receivers[index].receive(data,at:now)
                XCTAssertNil(output.close,"no peer is closed")
                for message in output.send {try take(try host.receive(try NetworkCodec.encode(message),from:connections[index],at:now))}
            }
        }
        if receivers.indices.contains(where:{cursors[$0]<(sent[connections[$0]]?.count ?? 0)}) {try deliver()}
    }
    func hostPlays(_ uci:String)throws {let effects=try host.perform(.move(uci:uci),at:now);XCTAssertFalse(effects.contains{if case .refused=$0 {return true};return false},uci);try take(effects);try deliver()}
    func play(_ index:Int,_ uci:String)throws {try toHost(index,try receivers[index].submitMove(uci:uci))}
    /// The flag-fall timer fires late, after `seconds` with no other event.
    func flagFalls(after seconds:Int)throws {now=now+Duration.seconds(seconds);try take(try host.timerFired(.flag,at:now));try deliver()}
}
