import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// LAN-play plan D9 and D10: the network place, its own board and input, and which systems show it.
@MainActor final class NetworkSliceTests:XCTestCase {
    func testTheNetworkPlaceHasItsOwnMode(){XCTAssertEqual(Place.network.mode,.network);XCTAssertNil(Place.network.lessonIndex)}
    /// D10: spike (e) passed on macOS 26 and 14, so the floor is 26 and 14 is verified; 15 is not; later majors are assumed.
    func testNetworkPolicyPinsTheSupportedSystems(){
        XCTAssertEqual(NetworkPolicy.minimumMacOS,26);XCTAssertEqual(NetworkPolicy.verifiedOlderMajors,[14])
        for (major,shown) in [(13,false),(14,true),(15,false),(25,false),(26,true),(27,true),(28,true)]{XCTAssertEqual(NetworkPolicy.available(onMajor:major),shown,"macOS \(major)")}
    }
    /// D9: entering the network place stops practice work and ends its presentations; the board shows the network game.
    func testEnteringTheNetworkPlaceStopsPracticeWorkAndShowsItsOwnBoard()throws {
        let session=try GameSession(engine:nil),game=try NetworkGameController();session.network=game
        try session.beginPreview();XCTAssertNotNil(session.preview)
        session.enter(.at(.network))
        XCTAssertEqual(session.mode,.network);XCTAssertNil(session.preview,"presentations end");XCTAssertFalse(session.busy)
        XCTAssertEqual(session.displayView,"network");XCTAssertNil(session.displayFen,"the lobby shows no board");XCTAssertEqual(session.displayBoard,[:])
        try game.show(seat:.player(side:"w"),title:"Ana vs Ben",pgn:"1. e4 e5")
        XCTAssertEqual(session.displayFen,game.rules.fen);XCTAssertEqual(session.displayBoard,game.board)
        XCTAssertTrue(session.displayIdentity.hasSuffix(":network:"+game.identity))
        XCTAssertEqual(session.rules.history,[],"practice's own game is untouched")
        // Practice input does nothing on the network place.
        try session.select("e2");XCTAssertNil(session.selected)
    }
    /// D2/D10: a player's move is submitted once and shown pending; the board changes only when the game applies it.
    func testAPlayersMoveIsPendingUntilApplied()throws {
        let game=try NetworkGameController();var submitted:[String]=[];game.submit={submitted.append($0)}
        try game.show(seat:.player(side:"w"),title:"Ana vs Ben",pgn:"")
        game.click("e2");XCTAssertEqual(game.selected,"e2");XCTAssertTrue(game.destinations.contains("e4"))
        game.click("e4");XCTAssertEqual(submitted,["e2e4"]);XCTAssertEqual(game.pending,.init(from:"e2",to:"e4",uci:"e2e4"));XCTAssertEqual(game.notice,"Sending…")
        XCTAssertEqual(game.board["e2"],"wp","the board does not move before the game answers")
        game.click("d2");game.play(from:"d2",to:"d4");XCTAssertEqual(submitted,["e2e4"],"further presses are ignored while one is pending")
        try game.applied(uci:"e2e4");XCTAssertNil(game.pending);XCTAssertEqual(game.board["e4"],"wp");XCTAssertNil(game.notice)
        XCTAssertFalse(game.canMove,"Black to move");game.click("e7");XCTAssertNil(game.selected)
        try game.applied(uci:"e7e5");XCTAssertTrue(game.canMove)
        game.play(from:"d2",to:"d4");game.rejected();XCTAssertNil(game.pending);XCTAssertEqual(game.board["d2"],"wp","a refused move goes back")
    }
    /// D10: a spectator's board accepts no moves; a click says so.
    func testASpectatorsClickSaysTheyAreWatching()throws {
        let game=try NetworkGameController();var submitted:[String]=[];game.submit={submitted.append($0)}
        try game.show(seat:.spectator,title:"Ana vs Ben",pgn:"1. e4")
        game.click("e7");XCTAssertEqual(game.notice,"You're watching");XCTAssertNil(game.selected)
        game.play(from:"e7",to:"e5");XCTAssertEqual(submitted,[]);XCTAssertFalse(game.canDrag("e7"))
    }
    func testPromotionIsOfferedOnlyForAPawnReachingTheLastRank()throws {
        let game=try NetworkGameController();var submitted:[String]=[];game.submit={submitted.append($0)}
        try game.show(seat:.player(side:"w"),title:"",pgn:"1. e4 d5 2. exd5 c6 3. dxc6 Nf6 4. cxb7 Nbd7")
        XCTAssertFalse(game.needsPromotion(from:"d2",to:"d4"));XCTAssertTrue(game.needsPromotion(from:"b7",to:"a8"))
        game.play(from:"b7",to:"a8",promotion:"n");XCTAssertEqual(submitted,["b7a8n"],"the chosen piece is submitted")
    }
}
