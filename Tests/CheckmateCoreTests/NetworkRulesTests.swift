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
    /// Since 1.2 (mini-games plan D7) the record's own start must be the declared one: a record that sets up another
    /// start is refused outright, even when its moves reach the same position by the same squares.
    func testARecordFromAnotherStartIsRefused()throws {
        let forgedStart=try ChessRules(fen:"rnbqkbnr/pppppppp/8/8/8/2q5/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        _ = try forgedStart.networkPlay(uci:"b1c3");_ = try forgedStart.networkPlay(uci:"e7e5")
        let honest=try ChessRules();_ = try honest.networkPlay(uci:"b1c3");_ = try honest.networkPlay(uci:"e7e5")
        XCTAssertEqual(try forgedStart.networkFEN(),try honest.networkFEN(),"the two starts converge");XCTAssertTrue(try forgedStart.networkPGN().contains("Nxc3"))
        let gameID=NetworkGameID.random(using:.system),pgn=try forgedStart.networkPGN()
        let game=NetworkPublicGame(gameID:gameID,revision:2,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:pgn,clocks:nil,openOffer:nil,outcome:nil)
        XCTAssertThrowsError(try NetworkSnapshotInstaller.install(try JSONEncoder().encode(game),revision:2,hash:hashing.positionHash(fen:try honest.networkFEN(),revision:2),gameID:gameID,rules:NetworkRulesFactory{try ChessRules()},hashing:hashing)){
            XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("start"))
        }
        // The honest record installs, and keeps only its own moves.
        let honestGame=NetworkPublicGame(gameID:gameID,revision:2,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:try honest.networkPGN(),clocks:nil,openOffer:nil,outcome:nil)
        let record=try NetworkSnapshotInstaller.install(try JSONEncoder().encode(honestGame),revision:2,hash:hashing.positionHash(fen:try honest.networkFEN(),revision:2),gameID:gameID,rules:NetworkRulesFactory{try ChessRules()},hashing:hashing).rules.networkPGN()
        XCTAssertFalse(record.contains("Nxc3"),"no invented capture");XCTAssertFalse(record.contains("[FEN "),"no other start");XCTAssertTrue(record.contains("Nc3"))
    }
    // MARK: A declared start (mini-games plan D7, L1)
    /// The Game of the Century after 40. Kb1 (Black to move at move 40), as chess.js writes it: the record replayed and
    /// the last three plies taken back.
    static func centuryStart()throws -> String {
        let game=try ChessRules()
        try game.restore("1. Nf3 Nf6 2. c4 g6 3. Nc3 Bg7 4. d4 O-O 5. Bf4 d5 6. Qb3 dxc4 7. Qxc4 c6 8. e4 Nbd7 9. Rd1 Nb6 10. Qc5 Bg4 11. Bg5 Na4 12. Qa3 Nxc3 13. bxc3 Nxe4 14. Bxe7 Qb6 15. Bc4 Nxc3 16. Bc5 Rfe8+ 17. Kf1 Be6 18. Bxb6 Bxc4+ 19. Kg1 Ne2+ 20. Kf1 Nxd4+ 21. Kg1 Ne2+ 22. Kf1 Nc3+ 23. Kg1 axb6 24. Qb4 Ra4 25. Qxb6 Nxd1 26. h3 Rxa2 27. Kh2 Nxf2 28. Re1 Rxe1 29. Qd8+ Bf8 30. Nxe1 Bd5 31. Nf3 Ne4 32. Qb8 b5 33. h4 h5 34. Ne5 Kg7 35. Kg1 Bc5+ 36. Kf1 Ng3+ 37. Ke1 Bb4+ 38. Kd1 Bb3+ 39. Kc1 Ne2+ 40. Kb1 Nc3+ 41. Kc1 Rc2# 0-1")
        for _ in 0..<3 {try game.undo()}
        return try game.networkFEN()
    }
    /// A game from that start, played to mate over the network: every receiver installs and pins the declared start,
    /// its record declares it (SetUp/FEN) and replays from it, and the plies and the result are counted from it.
    func testAGameFromADeclaredStartIsPlayedToMateFromIt()throws {
        let start=try Self.centuryStart()
        XCTAssertEqual(NetworkStart.side(start),.black);XCTAssertEqual(NetworkStart.fullmove(start),40);XCTAssertTrue(NetworkStart.wellFormed(start))
        let net=try RulesNetwork(fen:start,hostSide:.black,hashing:hashing)
        XCTAssertEqual(net.host.settings.startFEN,start,"chess.js's own FEN is already canonical");XCTAssertEqual(net.host.fen,start);XCTAssertEqual(net.host.sideToMove,.black)
        XCTAssertTrue(try net.host.publicGame(at:net.now).pgn.contains("[FEN \"\(start)\"]"),"the host's record declares its start")
        let guest=try net.join(.guest(claimID:NetworkSecret.random(using:.system)),name:"Ben"),watcher=try net.join(.spectator,name:"Cy")
        XCTAssertEqual(net.host.phase,.running)
        try net.hostPlays("e2c3");try net.play(guest,"b1c1");try net.hostPlays("a2c2")
        let outcome=NetworkOutcome(result:.blackWins,termination:.checkmate)
        XCTAssertEqual(net.host.outcome,outcome);XCTAssertEqual(net.host.revision,4)
        for index in [guest,watcher] {
            let receiver=net.receivers[index]
            XCTAssertEqual(receiver.pinnedStart,start);XCTAssertEqual(receiver.installed?.startFEN,start);XCTAssertEqual(receiver.outcome,outcome);XCTAssertEqual(receiver.fen,net.host.fen)
            let record=try XCTUnwrap(try receiver.publicGame(at:net.now))
            XCTAssertEqual(record.startFEN,start)
            let replayed=try ChessRules();try replayed.networkLoad(pgn:record.pgn)
            XCTAssertEqual(try replayed.networkStartFEN(),start);XCTAssertEqual(try replayed.networkFEN(),net.host.fen);XCTAssertEqual(try replayed.networkMoves(),["e2c3","b1c1","a2c2"])
        }
        XCTAssertEqual(net.receivers[guest].side,.white)
    }
    /// Hosting refuses a start the rules refuse, an inconsistent one, and one already over (D7).
    func testHostingRefusesAnIllegalOrFinishedStartOnTheRealRules()throws {
        func host(_ fen:String)throws {_ = try RulesNetwork(fen:fen,hashing:hashing)}
        for (fen,why) in [("8/8/8/8/8/8/8/8 w - - 0 1","no kings"),("4k3/8/8/8/8/8/8/R3K3 x - - 0 1","no side to move"),("4k2R/8/8/8/8/8/8/4K3 w - - 0 1","the side not to move is in check"),
                          ("4k3/8/8/8/8/8/8/4K3 w K - 0 1","castling with no rook"),("P3k3/8/8/8/8/8/8/4K3 w - - 0 1","a pawn on the last rank")] {
            XCTAssertThrowsError(try host(fen),why){XCTAssertEqual($0 as? NetworkHostError,.illegalStart,why)}
        }
        for (fen,why) in [("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1","stalemate"),("R5k1/5ppp/8/8/8/8/8/6K1 b - - 0 1","checkmate"),("8/8/8/8/8/8/2k5/K7 w - - 0 1","insufficient material"),("8/8/8/8/8/8/1k6/R3K3 w - - 150 80","the 75-move rule")] {
            XCTAssertThrowsError(try host(fen),why){XCTAssertEqual($0 as? NetworkHostError,.startOver,why)}
        }
        // A refused start leaves the rules' own game as it was.
        let rules=try ChessRules();_ = try rules.networkPlay(uci:"e2e4")
        XCTAssertThrowsError(try rules.networkLoad(start:"4k2R/8/8/8/8/8/8/4K3 w - - 0 1")){XCTAssertEqual($0 as? NetworkRulesError,.illegalStart)}
        XCTAssertEqual(try rules.networkMoves(),["e2e4"])
    }
    /// The start is kept as chess.js writes it back: an en passant square no pawn can take is dropped, and the standard
    /// start, however it is written, is no declared start. A record declaring the uncanonical form is refused.
    func testTheDeclaredStartIsCanonical()throws {
        let written="rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",canonical="rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        let net=try RulesNetwork(fen:written,hashing:hashing)
        XCTAssertEqual(net.host.settings.startFEN,canonical);XCTAssertTrue(try net.host.publicGame(at:net.now).pgn.contains("[FEN \"\(canonical)\"]"))
        let standard=try RulesNetwork(fen:"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",hashing:hashing)
        XCTAssertNil(standard.host.settings.startFEN);XCTAssertFalse(try standard.host.publicGame(at:standard.now).pgn.contains("FEN"),"the 1.1 record")
        let gameID=NetworkGameID.random(using:.system),rules=try ChessRules();try rules.networkLoad(start:canonical)
        var game=NetworkPublicGame(gameID:gameID,revision:0,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:try rules.networkPGN(),clocks:nil,openOffer:nil,outcome:nil,startFEN:canonical)
        let hash=hashing.positionHash(fen:canonical,revision:0)
        XCTAssertEqual(try NetworkSnapshotInstaller.install(try JSONEncoder().encode(game),revision:0,hash:hash,gameID:gameID,rules:NetworkRulesFactory{try ChessRules()},hashing:hashing).start,canonical)
        game.startFEN=written
        XCTAssertThrowsError(try NetworkSnapshotInstaller.install(try JSONEncoder().encode(game),revision:0,hash:hash,gameID:gameID,rules:NetworkRulesFactory{try ChessRules()},hashing:hashing)){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("start"))}
    }
    /// A 1.1 Mac states no capabilities: refused from a declared start before anything is sent, let into a standard one.
    func testA11MacIsRefusedFromADeclaredStartBeforeAnythingIsSent()throws {
        let net=try RulesNetwork(fen:try Self.centuryStart(),hashing:hashing)
        for (listener,hello) in [(NetworkListenerRole.seat,NetworkMessage.hello(name:"Old",appVersion:"0.8.2",claimID:.random(using:.system),assistance:.off)),(.watch,.hello(name:"Old",appVersion:"0.8.2",claimID:nil))] {
            let accepted=try net.host.accept(listener,at:net.now)
            let effects=try net.host.receive(try NetworkCodec.encode(hello),from:accepted.connection,at:net.now)
            XCTAssertTrue(effects.contains(.close(accepted.connection,.protocolVersion)),"\(listener)");XCTAssertFalse(effects.contains{if case .transmit=$0 {return true};return false},"nothing sent to \(listener)")
        }
        XCTAssertEqual(net.host.phase,.waiting);XCTAssertEqual(net.host.spectators,[])
        let standard=try RulesNetwork(hashing:hashing),accepted=try standard.host.accept(.seat,at:standard.now)
        _ = try standard.host.receive(try NetworkCodec.encode(.hello(name:"Old",appVersion:"0.8.2",claimID:.random(using:.system),assistance:.off)),from:accepted.connection,at:standard.now)
        XCTAssertEqual(standard.host.phase,.reserved,"a 1.1 guest still joins a standard-start game")
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
    /// New games for the host and every receiver alike: a snapshot extends the receiver's own new game, from the
    /// start the record declares.
    let rules:NetworkRulesFactory
    var now=NetworkInstant.origin
    var receivers:[NetworkReceiver]=[],connections:[NetworkConnectionID]=[],cursors:[Int]=[]
    var sent:[NetworkConnectionID:[Data]]=[:]
    init(fen:String?=nil,pgn:String?=nil,hostSide:NetworkSide = .white,timeControl:NetworkTimeControl = .untimed,hashing:NetworkHashing)throws {
        self.hashing=hashing;gameID=NetworkGameID.random(using:.system)
        let rules=NetworkRulesFactory{let rules=try ChessRules();if let pgn {try rules.networkLoad(pgn:pgn)};return rules};self.rules=rules
        // A position is a declared start (mini-games plan D7): the host sets it up, every receiver replays from it.
        host=try NetworkHost(gameID:gameID,runEpoch:NetworkID.random(using:.system),settings:NetworkHostSettings(hostName:"Ana",hostSide:hostSide,timeControl:timeControl,startFEN:fen),rules:rules,hashing:hashing,at:now)
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
