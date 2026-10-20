import XCTest
@testable import CheckmateApplication
@testable import CheckmateDomain
import CheckmateRules
import CheckmateSupport

/// Mini-games plan WI-024 (D7, L2, `docs/network-protocol-1.3.md`) above the domain: the host sheet's mini-game behind
/// `CHECKMATE_NETWORK_MINI_GAMES`, the network place's own board model, wording, the TXT label that decides nothing,
/// the crash file a 1.2 build never reads, the proof-search review of a finished game whatever ended it, and the frozen
/// 1.2 crash file, review record and TXT entries reproduced byte for byte by this build.
@MainActor final class NetworkMiniGameFlowTests:XCTestCase {
    private func withMiniGames<T>(_ enabled:Bool,_ body:()throws -> T)rethrows -> T {
        let previous=ProcessInfo.processInfo.environment["CHECKMATE_NETWORK_MINI_GAMES"]
        if enabled {setenv("CHECKMATE_NETWORK_MINI_GAMES","1",1)}else{unsetenv("CHECKMATE_NETWORK_MINI_GAMES")}
        defer{if let previous {setenv("CHECKMATE_NETWORK_MINI_GAMES",previous,1)}else{unsetenv("CHECKMATE_NETWORK_MINI_GAMES")}}
        return try body()
    }
    private func host(_ lan:MemoryLAN,_ kind:MiniGameKind?)throws -> Mac {
        let ana=try Mac(lan,name:"Ana");ana.game.form.miniGame=kind;ana.game.form.side = .white
        XCTAssertTrue(ana.game.host());lan.scheduler.run();return ana
    }
    private func join(_ lan:MemoryLAN,_ name:String,_ host:Mac,watching:Bool=false,records:[NetworkServiceRecord]?=nil)throws -> Mac {
        let mac=try Mac(lan,name:name,discovery:records.map{NetworkFixedDiscovery(records:$0,scheduler:lan.scheduler)});mac.game.setShown(true);lan.scheduler.run()
        let entry=try XCTUnwrap(mac.game.games.first)
        XCTAssertTrue(mac.game.join(entry,code:(watching ? host.game.watchCode:host.game.playCode)!.grouped,watching:watching));lan.scheduler.run()
        XCTAssertEqual(mac.game.link,.live);return mac
    }
    private func move(_ mac:Mac,_ uci:String,_ lan:MemoryLAN){mac.game.click(String(uci.prefix(2)));mac.game.click(String(uci.suffix(2)));lan.scheduler.run();XCTAssertNil(mac.game.pending,"\(uci) was applied")}
    private func waitFor(_ condition:@escaping ()->Bool)async throws {for _ in 0..<400 {if condition(){return};try await Task.sleep(for:.milliseconds(25))}}

    /// The flag off: the sheet's mini-game is ignored and hosting is chess exactly as 1.2 hosts it.
    func testWithTheFlagOffHostingIsChess()throws {
        try withMiniGames(false){
            XCTAssertFalse(NetworkPolicy.miniGamesEnabled)
            let lan=MemoryLAN(),ana=try host(lan,.pawnDuel)
            XCTAssertNil(ana.game.ruleset);XCTAssertEqual(ana.game.board["e2"],"wp");XCTAssertNil(ana.game.record?.ruleset)
            XCTAssertNil(lan.records.first?.txt["variant"],"no label either")
        }
    }
    /// The flag on: Pawn Duel across three Macs to a far-rank win, in the network place's own board model; the
    /// wording, the label, the crash file and the review that follows.
    func testPawnDuelIsPlayedToAFarRankWinAndReviewed()async throws {
        let lan=MemoryLAN()
        let (ana,ben,cy)=try withMiniGames(true){()throws -> (Mac,Mac,Mac) in
            let ana=try host(lan,.pawnDuel)
            XCTAssertEqual(ana.game.ruleset,NetworkRuleset(.pawnDuel));XCTAssertEqual(ana.game.board["b2"],"wp");XCTAssertNil(ana.game.board["e1"],"the kind's own start, shown at once")
            XCTAssertEqual(lan.records.first?.txt["variant"],"mini:pawn-duel@2")
            XCTAssertEqual(ana.game.record?.assistance,.off)
            return (ana,try join(lan,"Ben",ana),try join(lan,"Cy",ana,watching:true))
        }
        for mac in [ben,cy] {XCTAssertEqual(mac.game.ruleset,NetworkRuleset(.pawnDuel));XCTAssertTrue(mac.game.rules is NetworkMiniGame)}
        XCTAssertEqual(ana.game.statusText,"Your move.");XCTAssertEqual(ben.game.learnerSide,.black)
        // Assistance is off: no insight, no claim.
        XCTAssertFalse(ana.game.inspectable);XCTAssertFalse(ana.game.canClaimDraw)
        // A pawn cannot move like a chess pawn's promotion or a piece the kind does not move: only the referee's moves.
        ana.game.click("b2");XCTAssertEqual(Set(ana.game.destinations),["b3","b4"])
        ana.game.clearSelection()
        for (index,uci) in ["b2b4","g7g5","b4b5","g5g4","b5b6","g4g3","b6c7","g3f2","c7c8"].enumerated() {move(index%2==0 ? ana:ben,uci,lan)}
        let outcome=NetworkOutcome(result:.whiteWins,termination:.farRank)
        for mac in [ana,ben,cy] {XCTAssertEqual(mac.game.outcome,outcome);XCTAssertEqual(mac.game.board["c8"],"wp")}
        XCTAssertEqual(ana.game.statusText,"You reached the far rank. You win.");XCTAssertEqual(ben.game.statusText,"Ana reached the far rank. Ana wins.")
        XCTAssertEqual(cy.heard.lines.suffix(2).first,"Ana played pawn to c8");XCTAssertEqual(ben.heard.lines.last,"Ana reached the far rank. Ana wins.")
        XCTAssertTrue(cy.heard.lines.contains("Ana played pawn to c7, capturing a pawn"))
        // Review: the proof search over the finished game, never a PGN record; the sheet opens when asked.
        for mac in [ana,ben,cy] {XCTAssertTrue(mac.game.canReview);XCTAssertNil(mac.game.reviewRecord())}
        try await waitFor{ana.game.miniReview.review != nil}
        let review=try XCTUnwrap(ana.game.miniReview.review)
        XCTAssertTrue(review.consistent);XCTAssertEqual(review.kind,.pawnDuel);XCTAssertEqual(review.plies,9);XCTAssertFalse(ana.game.miniReview.sheetOpen,"not before the learner asks")
        XCTAssertFalse(review.facts.isEmpty,"White's breakthrough is a proved forced win")
        ana.game.showMiniReview();XCTAssertTrue(ana.game.miniReview.sheetOpen)
        // Leaving ends the review with the session.
        ana.game.leave();lan.scheduler.run();XCTAssertEqual(ana.game.miniReview.status,.idle);XCTAssertNil(ana.game.ruleset,"back to the lobby's chess board")
    }
    /// A resignation ends a mini-game the referee does not call over; it is reviewed all the same (Codex objection 3).
    /// While it runs, the crash file is the mini-game file, which no 1.2 build reads (objection 1).
    func testAResignedMiniGameIsReviewedAndItsCrashFileIsItsOwn()async throws {
        let lan=MemoryLAN()
        let (ana,ben)=try withMiniGames(true){()throws -> (Mac,Mac) in let ana=try host(lan,.rookSweep);return (ana,try join(lan,"Ben",ana))}
        move(ana,"b1b2",lan)
        for mac in [ana,ben] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:mac.crashFile.url.path),"never the file a 1.2 build reads")
            XCTAssertTrue(FileManager.default.fileExists(atPath:mac.crashFile.rulesetURL.path))
            XCTAssertEqual(mac.crashFile.pending()?.game.ruleset,"mini:rook-sweep@2")
        }
        ben.game.resign();lan.scheduler.run()
        XCTAssertEqual(ana.game.outcome,NetworkOutcome(result:.whiteWins,termination:.resignation))
        XCTAssertFalse((ana.game.rules as? NetworkMiniGame)?.state.isFinished ?? true,"not over by the referee's rules")
        try await waitFor{ana.game.miniReview.review != nil}
        XCTAssertEqual(ana.game.miniReview.review?.plies,1)
        XCTAssertNil(ana.crashFile.pending(),"participation ended with the result")
    }
    /// The TXT label decides nothing: a chess game whose record says Rook Sweep is chess on the board, and a Pawn Duel
    /// whose record says nothing (or nonsense) is Pawn Duel; only the lobby's label follows the TXT.
    func testAForgedVariantIsIgnored()throws {
        try withMiniGames(true){
            for (kind,forged) in [(nil,"mini:rook-sweep@2"),(MiniGameKind.pawnDuel,nil),(MiniGameKind.pawnDuel,"mini:knight-corners@1"),(MiniGameKind.pawnDuel,"chess")] as [(MiniGameKind?,String?)] {
                let lan=MemoryLAN(),ana=try host(lan,kind)
                let records=lan.records.map{record in var txt=record.txt;txt["variant"]=forged;return NetworkServiceRecord(name:record.name,txt:txt,endpoint:record.endpoint)}
                let ben=try join(lan,"Ben",ana,records:records)
                XCTAssertEqual(ben.game.ruleset?.kind,kind,"the verified snapshot decides, whatever the TXT says")
                XCTAssertEqual(ben.game.board["b2"],"wp")
                ben.game.leave();ana.game.leave();lan.scheduler.run()
            }
            // The label itself: a known kind's title, nothing for anything else.
            let found=NetworkDiscoveredGame.pair([NetworkServiceRecord(name:"Ana's game",txt:["game":NetworkGameID.random(using:.system).text,"role":"seat","variant":"mini:queen-vs-pawns@7"],endpoint:NetworkEndpoint("x",description:"x"))])
            XCTAssertEqual(found.first?.variant,.queenVsPawns)
            // A seat record that states no label falls back to the watch record's, as the terms do.
            let id=NetworkGameID.random(using:.system).text,endpoint=NetworkEndpoint("x",description:"x")
            let paired=NetworkDiscoveredGame.pair([NetworkServiceRecord(name:"Ana's game",txt:["game":id,"role":"seat"],endpoint:endpoint),NetworkServiceRecord(name:"Ana's game"+NetworkHostingConfiguration.watchSuffix,txt:["game":id,"role":"watch","variant":"mini:rook-sweep@2"],endpoint:endpoint)])
            XCTAssertEqual(paired.count,1);XCTAssertNotNil(paired.first?.seat);XCTAssertEqual(paired.first?.variant,.rookSweep)
            XCTAssertEqual(NetworkRuleset.displayKind("rook-sweep"),nil)
        }
    }
    /// The crash file: a mini-game entry in its own file; a chess file that holds one (no build writes that) is removed.
    func testTheCrashFileKeepsAMiniGameApartFromChess()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("checkmate-mini-crash-\(UUID().uuidString)");defer{try? FileManager.default.removeItem(at:root)}
        let file=NetworkCrashFile(dataDirectory:root),ruleset=NetworkRuleset(.pawnDuel)!
        let game=NetworkPublicGame(gameID:.random(using:.system),revision:1,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:"mini:pawn-duel@2 b2b4",clocks:nil,openOffer:nil,outcome:nil,ruleset:ruleset.descriptor)
        try file.save(NetworkCrashFile.Entry(game:game,part:.white))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.url.path));XCTAssertEqual(file.pending()?.game,game)
        try FileManager.default.copyItem(at:file.rulesetURL,to:file.url);try FileManager.default.removeItem(at:file.rulesetURL)
        XCTAssertNil(file.pending(),"a mini-game in the chess file is not read");XCTAssertFalse(FileManager.default.fileExists(atPath:file.url.path))
        try file.save(NetworkCrashFile.Entry(game:game,part:.white));file.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.rulesetURL.path))
    }
    /// The words for every added ending and for a mini-game's move.
    func testTheWordsForAMiniGame(){
        let you=NetworkWording.Players(white:"Ana",black:"Ben",learner:.black),watching=NetworkWording.Players(white:"Ana",black:"Ben",learner:nil)
        XCTAssertEqual(NetworkWording.result(NetworkOutcome(result:.blackWins,termination:.farRank),players:you),"You reached the far rank. You win.")
        XCTAssertEqual(NetworkWording.result(NetworkOutcome(result:.whiteWins,termination:.allCaptured),players:watching),"Every piece there was to capture is taken. Ana wins.")
        XCTAssertEqual(NetworkWording.result(NetworkOutcome(result:.whiteWins,termination:.noMoves),players:you),"You have no move. Ana wins.")
        XCTAssertEqual(NetworkWording.result(NetworkOutcome(result:.blackWins,termination:.noMoves),players:watching),"Ana has no move. Ben wins.")
        XCTAssertEqual(NetworkWording.result(NetworkOutcome(result:.draw,termination:.miniRepetition),players:you),"Draw: the same position appeared three times.")
        XCTAssertEqual(NetworkWording.result(NetworkOutcome(result:.draw,termination:.miniNoProgress),players:you),"Draw: 40 turns without a capture or pawn move.")
        XCTAssertEqual(NetworkWording.result(NetworkOutcome(result:.draw,termination:.unreachableTargets),players:you),"Draw: no remaining target can be reached.")
        let game=NetworkMiniGame(NetworkRuleset(.rookSweep)!),capture=try! game.move(uci:"b1b6")
        XCTAssertEqual(capture.san,"Rb1xb6");XCTAssertEqual(NetworkWording.move(capture,players:watching),"Ana played rook to b6, capturing a pawn")
        XCTAssertTrue(NetworkWording.miniGame(.pawnDuel).hasPrefix("Pawn Duel: Reach the far rank"))
    }
    /// Protocol 1.3's promise for chess from a declared start: the capture that froze `Legacy12CoreFixtures`, run again
    /// on this build, writes the same crash-file entry, review record and TXT entries, and reads 1.2's entry back.
    func testAChessGameFromADeclaredStartWritesWhat12Wrote()throws {
        var state:UInt64=1012
        let random=NetworkRandom{count in (0..<count).map{_ in state&+=0x9E3779B97F4A7C15;var z=state;z=(z^(z>>30))&*0xBF58476D1CE4E5B9;z=(z^(z>>27))&*0x94D049BB133111EB;return UInt8(truncatingIfNeeded:z^(z>>31))}}
        func id()->NetworkID {.random(using:random)}
        // The capture made these, in this order, before its game: the same draws keep the game's identifiers.
        _ = NetworkGameID.random(using:random);_ = NetworkSecret.random(using:random);_ = NetworkSecret.random(using:random);_ = id();_ = id()
        let start=try NetworkRulesTests.centuryStart()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("checkmate-freeze-\(UUID().uuidString)");defer{try? FileManager.default.removeItem(at:root)}
        let hostGame=NetworkGameID.random(using:random),guestClaim=NetworkSecret.random(using:random)
        let host=try NetworkHost(gameID:hostGame,runEpoch:id(),settings:NetworkHostSettings(hostName:"Ana",hostSide:.black,timeControl:.untimed,allowSpectators:true,assistance:.off,startFEN:start),rules:NetworkRulesFactory{try ChessRules()},hashing:NetworkHashing{reviewHash($0)},random:random,at:.origin)
        let (c,_)=try host.accept(.seat,at:.origin)
        _ = try host.receive(message:.hello(name:"Ben",appVersion:"0.8.3",claimID:guestClaim,assistance:.off,capabilities:.supported),from:c,at:.origin)
        _ = try host.receive(message:.seatedAck,from:c,at:.origin)
        _ = try host.perform(.move(uci:"e2c3"),at:.origin)
        _ = try host.receive(message:.move(gameID:hostGame,commandID:id(),revision:1,uci:"b1c1"),from:c,at:.origin)
        let game=try host.publicGame(at:.origin)
        XCTAssertEqual(String(decoding:try game.encoded(),as:UTF8.self),Legacy12CoreFixtures.record,"the public record")
        XCTAssertEqual(host.fen,Legacy12CoreFixtures.fen);XCTAssertEqual(host.positionHash,Legacy12CoreFixtures.hash)
        let file=NetworkCrashFile(dataDirectory:root);try file.save(NetworkCrashFile.Entry(game:game,part:.white))
        XCTAssertEqual(String(decoding:try Data(contentsOf:file.url),as:UTF8.self),Legacy12CoreFixtures.crashEntry,"the crash-file entry, in 1.2's file")
        var utc=Calendar(identifier:.gregorian);utc.timeZone=TimeZone(identifier:"UTC")!
        let rules=try ChessRules();try rules.restore(game.pgn)
        XCTAssertEqual(NetworkGameRecord.reviewPGN(game,moves:try rules.moveHistory().map(\.san),on:DateComponents(calendar:utc,year:2026,month:10,day:18).date!,calendar:utc),Legacy12CoreFixtures.review,"the review record")
        let configuration=NetworkHostingConfiguration(gameID:hostGame,seatCode:NetworkCode.random(using:random),watchCode:NetworkCode.random(using:random),serviceName:"Ana's game",assistance:.off)
        XCTAssertEqual(["seat":configuration.txt(.seat),"watch":configuration.txt(.watch)],Legacy12CoreFixtures.txt,"the TXT entries")
        XCTAssertEqual(try JSONDecoder().decode(NetworkCrashFile.Entry.self,from:Data(Legacy12CoreFixtures.crashEntry.utf8)).game,game,"and 1.2's entry reads back as the same game")
    }
}
