import XCTest
import CheckmateCore
import CheckmateTestSupport
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// Every legal move scores +1.20 for White, the first legal move ranked best.
@MainActor private final class EvenEngine:TestEngineService {
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
        let moves=try ChessRules(fen:fen).moves()
        return EngineAnalysis(bestMove:moves.first?.uci,budgetMs:budget,lines:moves.enumerated().map{index,move in AnalysisLine(depth:20,multiPv:index+1,score:AnalysisScore(kind:"cp",value:120),pv:[move.uci],san:[move.san],wdl:[500,300,200])})
    }
}
/// R-17: the review's evaluation bar and optional best-move arrow come from the analysis already made, only in a
/// review, and never while engine help is withheld for a network game.
@MainActor final class ReviewBoardAidsTests:XCTestCase {
    private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<2000 where !condition(){try await Task.sleep(for:.milliseconds(5))};XCTAssertTrue(condition(),what)}

    func testTheBarSharesWinningChancesFromWhitesSide() {
        func share(_ kind:String,_ value:Int,_ turn:String="w")->Double {ReviewController.whiteShare(AnalysisScore(kind:kind,value:value),turn:turn)}
        XCTAssertEqual(share("cp",0),0.5,accuracy:0.0001)
        XCTAssertGreaterThan(share("cp",300),0.75);XCTAssertLessThan(share("cp",300),1)
        XCTAssertEqual(share("cp",-300),1-share("cp",300),accuracy:0.0001,"symmetric for Black")
        XCTAssertEqual(share("mate",3),1);XCTAssertEqual(share("mate",-2),0)
        XCTAssertEqual(share("mate",0,"b"),1,"Black to move and mated");XCTAssertEqual(share("mate",0,"w"),0,"White to move and mated")
    }
    func testTheBarAndArrowFollowTheAnalysisAndStopForANetworkGame()async throws {
        let document=try PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8))[0],fairness=FairnessPolicy()
        let analyzer=ReviewAnalyzer(engine:EvenEngine(),fairness:fairness),review=ReviewController();review.fairness=fairness;review.analyzer=analyzer
        review.load(document);XCTAssertNil(review.evaluationShare,"nothing is shown before the analysis");XCTAssertNil(review.bestMove)
        analyzer.startBatch(document);try await settle("the analysis finished"){analyzer.batchStatus=="ready"}
        try review.select(document.mainline[0])
        XCTAssertEqual(try XCTUnwrap(review.evaluationShare),ReviewController.whiteShare(AnalysisScore(kind:"cp",value:120),turn:"b"),accuracy:0.0001)
        let after=try ChessRules(fen:document.nodes[document.mainline[0]].afterFEN)
        XCTAssertEqual(review.bestMove,after.moves().first?.uci,"the arrow is the engine's choice in the position shown, Black's reply")
        fairness.participation.begin(.player)
        XCTAssertNil(review.evaluationShare,"no evaluation during a network game");XCTAssertNil(review.shownScore,"nor its words, which read the same score");XCTAssertNil(review.bestMove,"no best move during a network game")
        fairness.participation.end();XCTAssertNil(review.evaluationShare,"joining cleared the analysis; it shows again only once analyzed again");XCTAssertEqual(analyzer.bestMoves,[:])
    }
    func testAnImaginedLineShowsItsOwnAnalysis()async throws {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],analyzer=ReviewAnalyzer(engine:EvenEngine()),review=ReviewController();review.analyzer=analyzer
        review.load(document);try review.select(document.mainline[0])
        try review.selectSquare("g8");try review.selectSquare("f6");XCTAssertNotNil(review.branch,"a move off the record begins an imagined line")
        XCTAssertNil(review.evaluationShare)
        review.analyze(using:analyzer);try await settle("the imagined position was analyzed"){review.analysisStatus=="ready"}
        let shown=try XCTUnwrap(review.displayRules)
        XCTAssertEqual(review.bestMove,shown.moves().first?.uci);XCTAssertNotNil(review.evaluationShare)
    }
    func testTheBestMoveArrowIsOffUntilChosen()throws {
        XCTAssertFalse(AppSettings().reviewBestMoveArrow);XCTAssertFalse(AppSettings(raw:[:]).reviewBestMoveArrow)
        var on=AppSettings();on.reviewBestMoveArrow=true
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(on)).reviewBestMoveArrow,"the choice is saved")
    }
}
