import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// Mini-games plan WI-022: the network place reads its game only through `NetworkBoardModel`, and chess conforms with
/// exactly the reads it had before (a pure refactor).
@MainActor final class NetworkBoardModelTests:XCTestCase {
    private let start="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    func testTheControllerMakesAChessModelAtTheStandardStart()throws {
        let model=try NetworkGameController.newBoard()
        XCTAssertTrue(model is ChessRules,"chess is the only model so far")
        _ = try model.move(uci:"e2e4");try model.loadStart()
        XCTAssertEqual(model.fen,start);XCTAssertEqual(model.history,[]);XCTAssertEqual(model.turn,"w")
        let game=try NetworkGameController();XCTAssertTrue(game.rules is ChessRules);XCTAssertEqual(game.rules.fen,start)
        try game.show(seat:.player(side:"w"),title:"Ana vs Ben",pgn:"1. e4 e5");game.clear()
        XCTAssertEqual(game.rules.fen,start,"the lobby is the start again");XCTAssertNil(game.fen,"and shows no board")
    }
    func testChessReadsThroughTheModelAreTheRulesOwn()throws {
        let rules=try ChessRules(),model:any NetworkBoardModel=rules
        for uci in ["e2e4","e7e5","g1f3"] {XCTAssertEqual(try model.move(uci:uci).uci,uci)}
        XCTAssertEqual(model.board,rules.board);XCTAssertEqual(model.turn,"b");XCTAssertEqual(model.fen,try rules.currentFEN())
        XCTAssertEqual(model.history,["e4","e5","Nf3"]);XCTAssertEqual(model.records.last?.uci,"g1f3");XCTAssertEqual(try model.moveHistory(),rules.records)
        XCTAssertEqual(model.moves().map(\.uci),rules.moves().map(\.uci));XCTAssertEqual(Set(model.moves("b8").map(\.to)),["a6","c6"])
        XCTAssertEqual(try model.legalMoves(from:nil),rules.moves());XCTAssertEqual(model.piece("f3"),rules.piece("f3"))
        XCTAssertEqual(try model.relationships("e5",mode:.protected,diagram:nil),try rules.relationships("e5",mode:.protected))
        XCTAssertThrowsError(try model.move(uci:"e1e3"),"an illegal move throws");XCTAssertEqual(model.history.count,3,"and changes nothing")
        XCTAssertThrowsError(try model.restore("1. e4 Ke7 Ke2 *"));XCTAssertEqual(model.history,["e4","e5","Nf3"],"a record that does not load leaves the game")
    }
    func testPromotionIsAskedOnlyForAPromotingMove()throws {
        let model:any NetworkBoardModel=try ChessRules(fen:"8/4P1k1/8/8/8/8/3P4/4K3 w - - 0 1")
        XCTAssertTrue(model.needsPromotion(from:"e7",to:"e8"));XCTAssertFalse(model.needsPromotion(from:"d2",to:"d4"));XCTAssertFalse(model.needsPromotion(from:"e7",to:"e6"))
    }
    /// `over`, `endedByRules` and `drawClaimable` are the old reads: a claimable draw never ends the game. (At 150
    /// plies the fifty-move claim also holds; the game is over regardless.)
    func testEndingsAndClaimsAreTheRulesOwn()throws {
        let ended=["7k/5Q2/6K1/8/8/8/8/8 b - - 0 1","8/8/8/8/8/8/2k5/K7 w - - 0 1","rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3","8/8/8/8/8/8/1k6/R3K3 b - - 150 80"]
        for fen in ended {let rules=try ChessRules(fen:fen);XCTAssertTrue(rules.over,fen);XCTAssertTrue(try rules.endedByRules(),fen)}
        let fifty=try ChessRules(fen:"8/8/8/8/8/8/1k6/R3K3 w - - 100 80")
        XCTAssertTrue(fifty.drawClaimable);XCTAssertFalse(try fifty.endedByRules());XCTAssertFalse(fifty.over)
        let repeated=try ChessRules()
        for _ in 1...2 {for uci in ["g1f3","g8f6","f3g1","f6g8"] {_ = try repeated.move(uci:uci)}}
        XCTAssertTrue(repeated.drawClaimable,"threefold");XCTAssertFalse(try repeated.endedByRules())
        XCTAssertFalse(try ChessRules().drawClaimable)
    }
    func testAFailingModelThrowsRatherThanReadingAsPlayOn()throws {
        let runtime=try FailingChessRuntime(),model:any NetworkBoardModel=try ChessRules(runtimeFactory:{runtime})
        XCTAssertFalse(try model.endedByRules());runtime.failing=true
        XCTAssertThrowsError(try model.endedByRules());XCTAssertThrowsError(try model.moveHistory());XCTAssertThrowsError(try model.loadStart())
        XCTAssertFalse(model.drawClaimable);XCTAssertFalse(model.needsPromotion(from:"e2",to:"e4"))
    }
}
