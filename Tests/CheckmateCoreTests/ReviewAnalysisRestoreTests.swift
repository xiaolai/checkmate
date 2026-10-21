import XCTest
import CheckmateCore
import CheckmateTestSupport
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// Scores every legal move, so the played move's line is in the root search; `losing` is the one move that throws the
/// game away (White-relative WDL). Searches past the first `allowed` wait until allowed or cancelled.
@MainActor private final class ScoringEngine:TestEngineService {
    var searches:[(fen:String,budget:Int)]=[],allowed=Int.max,losing:String?
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
        let index=searches.count;searches.append((fen,budget))
        while index>=allowed{try await Task.sleep(nanoseconds:1_000_000)}
        let rules=try ChessRules(fen:fen),moves=rules.moves().sorted{($0.uci==losing ? 1:0)<($1.uci==losing ? 1:0)}
        let lines=moves.enumerated().map{index,move in AnalysisLine(depth:20,multiPv:index+1,score:AnalysisScore(kind:"cp",value:move.uci==losing ? -900:30),pv:[move.uci],san:[move.san],wdl:move.uci==losing ? [0,0,1000]:[1000,0,0])}
        return EngineAnalysis(bestMove:moves.first?.uci,budgetMs:budget,lines:lines)
    }
}
@MainActor final class ReviewAnalysisRestoreTests:XCTestCase {
    private var folder:URL!
    override func setUpWithError() throws {folder=FileManager.default.temporaryDirectory.appendingPathComponent("review-analysis-\(UUID().uuidString)")}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:folder)}
    private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<2000 where !condition(){try await Task.sleep(for:.milliseconds(5))};XCTAssertTrue(condition(),what)}
    private let game="1. e4 d5 2. exd5 Qxd5 3. Nc3 *"

    /// R-2: leaving a review frees the engine (PL-1); entering it again, here or after a relaunch, shows the stored
    /// evaluations and moments without a search.
    func testReenteringShowsStoredAnalysisWithoutSearching()async throws {
        let document=try PGNImporter.parse(Data(game.utf8))[0],engine=ScoringEngine(),analyzer=ReviewAnalyzer(engine:engine,cacheDirectory:folder)
        analyzer.startBatch(document);try await settle("the analysis finished"){analyzer.batchStatus=="ready"}
        let evaluations=analyzer.evaluations,moments=analyzer.moments.map(\.id),searched=engine.searches.count
        XCTAssertEqual(evaluations.count,document.mainline.count+1);XCTAssertFalse(moments.isEmpty)
        analyzer.reset();XCTAssertTrue(analyzer.evaluations.isEmpty,"leaving still clears the analysis (PL-1)")
        analyzer.restore(document);try await settle("the stored analysis is shown again"){analyzer.batchStatus=="ready"}
        XCTAssertEqual(analyzer.batchDocument,document.id);XCTAssertEqual(analyzer.evaluations,evaluations);XCTAssertEqual(analyzer.moments.map(\.id),moments)
        XCTAssertEqual(analyzer.completed,document.mainline.count);XCTAssertEqual(engine.searches.count,searched,"no search for stored positions")
        // A relaunch reads the same evidence from disk, with an engine that has never searched.
        let relaunched=ScoringEngine(),fresh=ReviewAnalyzer(engine:relaunched,cacheDirectory:folder)
        fresh.restore(document);try await settle("the stored analysis is read from disk"){fresh.batchStatus=="ready"}
        XCTAssertEqual(fresh.evaluations,evaluations);XCTAssertEqual(fresh.moments.map(\.id),moments);XCTAssertTrue(relaunched.searches.isEmpty)
        // A game never analysed has nothing to show: the analyzer stays idle.
        let other=try PGNImporter.parse(Data("1. d4 *".utf8))[0];fresh.reset();fresh.restore(other)
        for _ in 0..<50{await Task.yield()};XCTAssertEqual(fresh.batchStatus,"idle");XCTAssertNil(fresh.batchDocument);XCTAssertTrue(relaunched.searches.isEmpty)
    }
    /// R-3: a cancelled run keeps what it finished and is partial; Resume searches only the positions still missing.
    func testCancelKeepsCompletedPositionsAndResumeSearchesOnlyTheRest()async throws {
        let document=try PGNImporter.parse(Data(game.utf8))[0],engine=ScoringEngine(),analyzer=ReviewAnalyzer(engine:engine,cacheDirectory:folder)
        engine.allowed=2;analyzer.startBatch(document);try await settle("two positions finished and the third is searching"){analyzer.completed==2 && engine.searches.count==3}
        analyzer.cancelBatch()
        XCTAssertEqual(analyzer.batchStatus,"partial");XCTAssertEqual(analyzer.batchDocument,document.id);XCTAssertEqual(analyzer.completed,2);XCTAssertEqual(analyzer.total,5)
        XCTAssertEqual(Set(analyzer.evaluations.keys),[0,document.mainline[0],document.mainline[1]],"the finished positions stay on the graph")
        engine.allowed=Int.max
        // Entering the review again shows the same partial run.
        analyzer.reset();analyzer.restore(document);try await settle("the partial run is shown again"){analyzer.batchStatus=="partial"}
        XCTAssertEqual(analyzer.completed,2);XCTAssertEqual(analyzer.total,5)
        let before=engine.searches.count
        analyzer.startBatch(document);try await settle("the resumed analysis finished"){analyzer.batchStatus=="ready"}
        let quick=engine.searches.dropFirst(before).filter{$0.budget==ReviewPolicy.quickBudget}
        XCTAssertEqual(quick.count,3,"only the three positions never finished are searched")
        XCTAssertEqual(analyzer.evaluations.count,document.mainline.count+1)
        // A different record still starts clean.
        let other=try PGNImporter.parse(Data("1. d4 *".utf8))[0];analyzer.reset();XCTAssertTrue(analyzer.evaluations.isEmpty)
        let searched=engine.searches.count;engine.allowed=searched;analyzer.startBatch(other);try await settle("the other record's search started"){engine.searches.count==searched+1}
        XCTAssertTrue(analyzer.evaluations.isEmpty);analyzer.cancelBatch();XCTAssertEqual(analyzer.batchStatus,"partial");XCTAssertEqual(analyzer.completed,0)
    }
    /// R-6: a capture that throws the game away is reported for its cost, its forcing nature second.
    func testACostlyForcingMoveIsReportedForItsCost()async throws {
        let document=try PGNImporter.parse(Data(game.utf8))[0],engine=ScoringEngine();engine.losing="e4d5"
        let analyzer=ReviewAnalyzer(engine:engine);analyzer.startBatch(document);try await settle("the analysis finished"){analyzer.batchStatus=="ready"}
        let capture=document.mainline[2],moment=try XCTUnwrap(analyzer.moments.first{$0.id==capture})
        XCTAssertGreaterThan(moment.expectationLoss ?? 0,ReviewQualityPolicy.interestingExpectationLoss)
        XCTAssertEqual(moment.reason,"Engine alternatives are worth comparing (also a capture, check or promotion)")
        let recapture=try XCTUnwrap(analyzer.moments.first{$0.id==document.mainline[3]})
        XCTAssertEqual(recapture.reason,"Capture, check or promotion","a forcing move that costs little keeps its reason")
    }
}
