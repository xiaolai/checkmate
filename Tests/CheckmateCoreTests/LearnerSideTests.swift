import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// The learner can play Black: New Game, scoring, check wording, move numbers, Take Back and the companion
/// opponent all follow the learner's side instead of assuming White.
@MainActor final class LearnerSideTests:XCTestCase {
    /// Scores are White's: the best root line keeps Black slightly better (-50); every other reply leaves White +300.
    final class PerspectiveEngine:TestEngineService {
        let root:String;init(root:String){self.root=root}
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
            let rules=try ChessRules(fen:fen),move=try XCTUnwrap(fen==root ? "d7d5":rules.moves().first?.uci)
            return EngineAnalysis(bestMove:move,lines:[AnalysisLine(depth:1,multiPv:1,score:AnalysisScore(kind:"cp",value:fen==root ? -50:300),pv:[move],san:[])])
        }
    }
    private func blackLearner(engine:EngineService?=nil)throws -> GameSession {
        let s=try GameSession(engine:engine),fork=try ChessRules();try fork.move(uci:"e2e4");try s.installPracticeFork(fork,side:"b");return s
    }
    func testABlackLearnersBlunderCostsThemNotZero()async throws {
        let afterE4=try ChessRules();try afterE4.move(uci:"e2e4")
        let s=try blackLearner(engine:PerspectiveEngine(root:afterE4.fen))
        let evaluation=try await s.evaluateCandidate(from:"a7",to:"a6")
        XCTAssertEqual(evaluation.lossCp,350,"From Black's side, going from -50 to +300 loses 350 centipawns")
    }
    func testNewGameKeepsOrChoosesTheLearnersSide()throws {
        let s=try blackLearner();s.newGame();XCTAssertEqual(s.humanSide,"b","New Game keeps the side being played")
        s.newGame(side:"w");XCTAssertEqual(s.humanSide,"w");s.newGame(side:"x");XCTAssertEqual(s.humanSide,"w")
    }
    func testCheckWordingNamesWhoseKingIsInCheck()throws {
        let s=try GameSession(engine:nil);for uci in ["e2e4","f7f6","d1h5"]{try s.rules.move(uci:uci)}
        XCTAssertTrue(s.turnSummary().hasSuffix("The opponent's king is in check."),s.turnSummary())
        let black=try blackLearner();for uci in ["f7f6","d1h5"]{try black.rules.move(uci:uci)}
        XCTAssertTrue(black.turnSummary().hasSuffix("Your king is in check."),black.turnSummary())
    }
    func testMoveNumbersFollowTheStartingPosition()throws {
        let s=try GameSession(engine:nil);try s.rules.restore("[SetUp \"1\"]\n[FEN \"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 12\"]\n\n*")
        for uci in ["g8f6","b1c3","e7e5"]{try s.rules.move(uci:uci)}
        XCTAssertEqual(s.moveListText,"12... Nf6  13. Nc3  e5")
        let normal=try GameSession(engine:nil);for uci in ["e2e4","e7e5","g1f3"]{try normal.rules.move(uci:uci)}
        XCTAssertEqual(normal.moveListText,"1. e4  e5  2. Nf3")
    }
    func testTakeBackNeedsALearnerMove()throws {
        let s=try GameSession(engine:nil),fork=try ChessRules();try s.installPracticeFork(fork,side:"b");try s.rules.move(uci:"e2e4")
        XCTAssertFalse(s.canTakeBack,"Stockfish's opening move alone is not the learner's to take back")
        s.undo();XCTAssertEqual(s.rules.history,["e4"])
        try s.rules.move(uci:"e7e5");XCTAssertTrue(s.canTakeBack)
    }
    func testPublishedStateNamesTheLearnersSide()throws {
        XCTAssertEqual(try blackLearner().publicState()["learnerSide"] as? String,"b")
    }
}

/// The end of a game says who won and why; a resignation or claimed draw ends it for good and is exported.
@MainActor final class GameEndingTests:XCTestCase {
    func testFoolsMateByTheLearnerIsAWin()throws {
        let s=try GameSession(engine:nil),fork=try ChessRules();for uci in ["f2f3","e7e5","g2g4"]{try fork.move(uci:uci)};try s.installPracticeFork(fork,side:"b")
        try s.playWhite(from:"d8",to:"h4");XCTAssertTrue(s.finished);XCTAssertEqual(s.message,"Checkmate. You win!");XCTAssertEqual(s.rules.ending?.result,"0-1")
    }
    func testResignationEndsAndIsRecorded()throws {
        let s=try GameSession(engine:nil);try s.playWhite(from:"e2",to:"e4");s.resign()
        XCTAssertTrue(s.finished);XCTAssertFalse(s.canTakeBack);XCTAssertEqual(s.state.practice.ending?.result,"0-1")
        XCTAssertThrowsError(try s.playWhite(from:"d2",to:"d4"));XCTAssertTrue(try s.rules.recordPGN(result:s.state.practice.ending?.result).contains("[Result \"0-1\"]"))
        let saved=try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(s.state));XCTAssertEqual(saved.practice.ending,s.state.practice.ending)
        s.newGame();XCTAssertFalse(s.finished);XCTAssertNil(s.state.practice.ending)
    }
    func testThreefoldRepetitionCanBeClaimed()throws {
        let s=try GameSession(engine:nil);XCTAssertNil(s.claimableDraw)
        for _ in 0..<2{for uci in ["g1f3","g8f6","f3g1","f6g8"]{try s.rules.move(uci:uci)}}
        XCTAssertEqual(s.claimableDraw,"threefold repetition");s.claimDraw()
        XCTAssertTrue(s.finished);XCTAssertEqual(s.state.practice.ending?.result,"1/2-1/2");XCTAssertEqual(s.gameOverMessage,"Draw claimed by threefold repetition.")
    }
}

/// Take Back after "Practise here" stops at the practised position instead of rewinding into the reviewed game.
@MainActor final class ForkTakeBackTests:XCTestCase {
    func testTakeBackStopsAtTheForkedPosition()throws {
        let s=try GameSession(engine:nil),fork=try ChessRules();for uci in ["e2e4","e7e5"]{try fork.move(uci:uci)};try s.installPracticeFork(fork,side:"w")
        XCTAssertFalse(s.canTakeBack,"The reviewed moves are not the learner's to take back")
        try s.playWhite(from:"g1",to:"f3");try s.rules.move(uci:"b8c6");XCTAssertTrue(s.canTakeBack)
        s.undo();XCTAssertEqual(s.rules.history,["e4","e5"]);XCTAssertFalse(s.canTakeBack)
        s.undo();XCTAssertEqual(s.rules.history,["e4","e5"])
    }
}
