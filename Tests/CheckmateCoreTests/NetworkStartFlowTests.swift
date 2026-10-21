import XCTest
@testable import CheckmateApplication
@testable import CheckmateDomain
import CheckmateRules
import CheckmateSupport

/// Mini-games plan WI-023 (D7, L1) above the domain: the host's game-library positions, the review record from a
/// Black-to-move start and its re-import, the controller behind `CHECKMATE_NETWORK_POSITIONS`, and the frozen 1.1
/// crash file, review record and TXT entries reproduced byte for byte by this build.
@MainActor final class NetworkStartFlowTests:XCTestCase {
    private var utc:Calendar {var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"UTC")!;return calendar}
    private var day:Date {DateComponents(calendar:utc,year:2026,month:10,day:18).date!}
    /// The Game of the Century, the library's only checkmate won by Black.
    private func century()throws -> (library:GameLibrary,game:LibraryGame) {
        let library=try GameLibrary.load()
        return (library,try XCTUnwrap(library.games.first{$0.id=="byrne-fischer"}))
    }

    // MARK: Game-library positions (Q2)
    func testALibraryGameOffersThePositionAfterEachMove()throws {
        let (library,game)=try century()
        let positions=try NetworkLibraryStart.positions(of:game,in:library)
        XCTAssertEqual(positions.count,game.plies);XCTAssertEqual(positions.map(\.ply),Array(1...game.plies))
        XCTAssertEqual(positions[0].move,"After 1. Nf3");XCTAssertEqual(positions[1].move,"After 1… Nf6")
        let kb1=positions[78]
        XCTAssertEqual(kb1.move,"After 40. Kb1");XCTAssertEqual(kb1.gameID,"byrne-fischer");XCTAssertEqual(kb1.title,game.title)
        XCTAssertEqual(kb1.fen,try NetworkRulesTests.centuryStart(),"the position the record replays to")
        // Every position but the mate can host a game; the mate is over.
        let factory=NetworkRulesFactory{try ChessRules()}
        func host(_ fen:String)throws -> NetworkHost {try NetworkHost(gameID:.random(using:.system),runEpoch:.random(using:.system),settings:NetworkHostSettings(hostName:"Ana",hostSide:.black,startFEN:fen),rules:factory,hashing:NetworkHashing(reviewHash),at:.origin)}
        XCTAssertEqual(try host(kb1.fen).settings.startFEN,kb1.fen)
        XCTAssertThrowsError(try host(positions.last!.fen)){XCTAssertEqual($0 as? NetworkHostError,.startOver)}
    }

    // MARK: The review record (D7)
    /// Black to move at move 40: numbered from the start, SetUp/FEN written, assisted plies marked from the start, and
    /// the record re-imports to the same start and moves.
    func testTheReviewRecordFromABlackToMoveStartReimportsToTheSameStartAndMoves()throws {
        let start=try NetworkRulesTests.centuryStart()
        let rules=try ChessRules();try rules.networkLoad(start:start)
        for uci in ["e2c3","b1c1","a2c2"] {_ = try rules.networkPlay(uci:uci)}
        let game=NetworkPublicGame(gameID:.random(using:.system),revision:4,hostSide:.black,whiteName:"Ben",blackName:"Ana",timeControl:.untimed,pgn:try rules.networkPGN(),clocks:nil,openOffer:nil,outcome:NetworkOutcome(result:.blackWins,termination:.checkmate),assistance:NetworkAssistance(both:.hints),assistedPlies:[1,3],startFEN:start)
        XCTAssertEqual(game.assistedMoves(by:.black),2);XCTAssertEqual(game.assistedMoves(by:.white),0)
        let review=NetworkGameRecord.reviewPGN(game,moves:try rules.moveHistory().map(\.san),on:day,calendar:utc)
        XCTAssertTrue(review.contains("[Result \"0-1\"]\n[SetUp \"1\"]\n[FEN \"\(start)\"]\n[TimeControl \"-\"]"),review)
        XCTAssertTrue(review.hasSuffix("\n\n40... Nc3+ {Hint shown} 41. Kc1 Rc2# {Hint shown} 0-1"),review)
        let documents=try PGNImporter.parse(Data(review.utf8)),document=try XCTUnwrap(documents.first)
        XCTAssertEqual(documents.count,1);XCTAssertEqual(document.startingFEN,start)
        XCTAssertEqual(document.mainline.compactMap{document.nodes[$0].san},["Nc3+","Kc1","Rc2#"]);XCTAssertEqual(document.mainline.compactMap{document.nodes[$0].uci},["e2c3","b1c1","a2c2"])
        XCTAssertEqual(document.result,"0-1");XCTAssertEqual(document.nodes[document.mainline[0]].fullmove,40);XCTAssertEqual(document.nodes[document.mainline[0]].side,"b")
        // White first at a later move: "12. e4 e5 13. ...".
        XCTAssertEqual(NetworkGameRecord.movetext(["Ke2","Kd7","Kd3"],result:"*",start:"4k3/8/8/8/8/8/8/4K3 w - - 0 12"),"12. Ke2 Kd7 13. Kd3 *")
        XCTAssertEqual(NetworkGameRecord.movetext(["Kd7"],result:"*",start:"4k3/8/8/8/8/8/8/4K3 b - - 0 12"),"12... Kd7 *")
    }

    // MARK: The compatibility promise (D7), against what 1.1 wrote
    /// The capture that froze `Legacy11CoreFixtures`, run again on this build: the same seeded identifiers, the same
    /// hosted standard-start games on the real rules, and the same crash-file entries, review records and TXT entries.
    func testAStandardStartGameWritesWhat11Wrote()throws {
        var state:UInt64=1011
        let random=NetworkRandom{count in (0..<count).map{_ in state&+=0x9E3779B97F4A7C15;var z=state;z=(z^(z>>30))&*0xBF58476D1CE4E5B9;z=(z^(z>>27))&*0x94D049BB133111EB;return UInt8(truncatingIfNeeded:z^(z>>31))}}
        func id()->NetworkID {.random(using:random)}
        // The capture made these, in this order, before its games: the same draws keep the games' identifiers.
        _ = NetworkGameID.random(using:random);_ = NetworkSecret.random(using:random);_ = NetworkSecret.random(using:random)
        for _ in 0..<16 {_ = id()}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("checkmate-start-\(UUID().uuidString)");defer{try? FileManager.default.removeItem(at:root)}
        for (terms,crash,review,txt) in [(NetworkAssistance(white:.hints,black:.off),Legacy11CoreFixtures.assistedCrashEntry,Legacy11CoreFixtures.assistedReview,Legacy11CoreFixtures.assistedTXT),(NetworkAssistance.off,Legacy11CoreFixtures.crashEntry,Legacy11CoreFixtures.review,Legacy11CoreFixtures.txt)] {
            let gameID=NetworkGameID.random(using:random),guestClaim=NetworkSecret.random(using:random)
            let host=try NetworkHost(gameID:gameID,runEpoch:id(),settings:NetworkHostSettings(hostName:"Ana",hostSide:.white,timeControl:.untimed,allowSpectators:true,assistance:terms),rules:NetworkRulesFactory{try ChessRules()},hashing:NetworkHashing{reviewHash($0)},random:random,at:.origin)
            let (c,_)=try host.accept(.seat,at:.origin)
            _ = try host.receive(message:.hello(name:"Ben",appVersion:"0.8.2",claimID:guestClaim,assistance:terms),from:c,at:.origin)
            _ = try host.receive(message:.seatedAck,from:c,at:.origin)
            _ = try host.perform(.move(uci:"e2e4",assisted:terms != .off),at:.origin)
            _ = try host.receive(message:.move(gameID:gameID,commandID:id(),revision:1,uci:"e7e5"),from:c,at:.origin)
            _ = try host.perform(.move(uci:"g1f3"),at:.origin)
            XCTAssertEqual(host.revision,3)
            let game=try host.publicGame(at:.origin)
            let file=NetworkCrashFile(dataDirectory:root.appendingPathComponent(terms.txt));try file.save(NetworkCrashFile.Entry(game:game,part:.black))
            XCTAssertEqual(String(decoding:try Data(contentsOf:file.url),as:UTF8.self),crash,"the crash-file entry")
            let rules=try ChessRules();try rules.restore(game.pgn)
            XCTAssertEqual(NetworkGameRecord.reviewPGN(game,moves:try rules.moveHistory().map(\.san),on:day,calendar:utc),review,"the review record")
            let configuration=NetworkHostingConfiguration(gameID:gameID,seatCode:NetworkCode.random(using:random),watchCode:NetworkCode.random(using:random),serviceName:"Ana's game",assistance:terms)
            XCTAssertEqual(["seat":configuration.txt(.seat),"watch":configuration.txt(.watch)],txt,"the TXT entries")
            // And this build reads 1.1's entry back as the same game.
            XCTAssertEqual(try JSONDecoder().decode(NetworkCrashFile.Entry.self,from:Data(crash.utf8)).game,game)
        }
    }

    // MARK: The controller and its flag
    private func withPositions<T>(_ enabled:Bool,_ body:()throws -> T)rethrows -> T {
        let previous=ProcessInfo.processInfo.environment["CHECKMATE_NETWORK_POSITIONS"]
        if enabled {setenv("CHECKMATE_NETWORK_POSITIONS","1",1)}else{unsetenv("CHECKMATE_NETWORK_POSITIONS")}
        defer{if let previous {setenv("CHECKMATE_NETWORK_POSITIONS",previous,1)}else{unsetenv("CHECKMATE_NETWORK_POSITIONS")}}
        return try body()
    }
    private func libraryStart(ply:Int)throws -> NetworkLibraryStart {let (library,game)=try century();return try NetworkLibraryStart.positions(of:game,in:library)[ply-1]}
    /// Off by default: a chosen start is ignored, and hosting is exactly 1.1's standard start.
    func testWithTheFlagOffHostingUsesTheStandardStart()throws {
        try withPositions(false){
            XCTAssertFalse(NetworkPolicy.positionsEnabled)
            let lan=MemoryLAN(),ana=try Mac(lan,name:"Ana")
            ana.game.form.start=try libraryStart(ply:79)
            XCTAssertTrue(ana.game.host());lan.scheduler.run()
            XCTAssertEqual(ana.game.board["e2"],"wp","the standard start");XCTAssertFalse(ana.game.declaredStart);XCTAssertNil(ana.game.record?.startFEN)
        }
    }
    /// On: the host shows the declared start at once, the guest and a spectator install it, they play to mate, and
    /// Review gets the record from that start. A finished position is refused with a message.
    func testWithTheFlagOnAGameIsPlayedFromALibraryPosition()throws {
        try withPositions(true){
            let lan=MemoryLAN(),ana=try Mac(lan,name:"Ana")
            ana.game.form.start=try libraryStart(ply:82)
            XCTAssertFalse(ana.game.host());XCTAssertEqual(ana.game.lobbyMessage,NetworkGameController.startOver);XCTAssertNil(ana.game.part)
            let start=try libraryStart(ply:79)
            ana.game.form.start=start;ana.game.form.side = .black
            XCTAssertTrue(ana.game.host());XCTAssertEqual(ana.game.rules.fen,start.fen,"the host's board shows the start before anyone joins");lan.scheduler.run()
            XCTAssertTrue(ana.game.declaredStart)
            let ben=try Mac(lan,name:"Ben");ben.game.setShown(true);lan.scheduler.run()
            let entry=try XCTUnwrap(ben.game.games.first)
            XCTAssertTrue(ben.game.join(entry,code:ana.game.playCode!.grouped));lan.scheduler.run()
            let cy=try Mac(lan,name:"Cy");cy.game.setShown(true);lan.scheduler.run()
            XCTAssertTrue(cy.game.join(try XCTUnwrap(cy.game.games.first),code:ana.game.watchCode!.grouped,watching:true));lan.scheduler.run()
            for mac in [ben,cy] {XCTAssertTrue(mac.game.declaredStart);XCTAssertEqual(mac.game.rules.fen,start.fen);XCTAssertEqual(mac.game.statusText,"Ana's move.")}
            XCTAssertEqual(ben.game.learnerSide,.white)
            for (mac,from,to) in [(ana,"e2","c3"),(ben,"b1","c1"),(ana,"a2","c2")] {mac.game.click(from);mac.game.click(to);lan.scheduler.run();XCTAssertNil(mac.game.pending,"\(from)\(to) was applied")}
            for mac in [ana,ben,cy] {
                XCTAssertEqual(mac.game.outcome,NetworkOutcome(result:.blackWins,termination:.checkmate))
                let review=try XCTUnwrap(mac.game.reviewRecord())
                XCTAssertTrue(review.contains("[FEN \"\(start.fen)\"]"),review);XCTAssertTrue(review.contains("40... Nc3+ 41. Kc1 Rc2# 0-1"),review)
                XCTAssertEqual(try XCTUnwrap(try PGNImporter.parse(Data(review.utf8)).first).startingFEN,start.fen)
            }
        }
    }
}
