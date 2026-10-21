import XCTest
import CheckmateCore
import CheckmateTestSupport
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// Scores every legal move, so the played move's line is in the root search; `losses` gives a move's White-relative
/// win/draw/loss (the default is a sure win for the side to move). Records the budget and resources of each search.
@MainActor private final class GradingEngine:TestEngineService {
    var searches:[(budget:Int,resources:EngineResources?)]=[],wdl:[String:[Int]]=[:]
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {try lines(fen:fen,budget:budget,resources:nil)}
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String],resources:EngineResources)async throws -> EngineAnalysis {
        let position=try ChessRules(fen:startFEN);for move in moves{try position.move(uci:move)};return try lines(fen:position.fen,budget:budget,resources:resources)
    }
    private func lines(fen:String,budget:Int,resources:EngineResources?)throws -> EngineAnalysis {
        searches.append((budget,resources))
        let rules=try ChessRules(fen:fen),win=rules.turn=="w" ? [1000,0,0]:[0,0,1000]
        let moves=rules.moves().sorted{(wdl[$0.uci]==nil ? 0:1)<(wdl[$1.uci]==nil ? 0:1)}
        return EngineAnalysis(bestMove:moves.first?.uci,budgetMs:budget,lines:moves.enumerated().map{index,move in AnalysisLine(depth:20,multiPv:index+1,score:AnalysisScore(kind:"cp",value:30),pv:[move.uci],san:[move.san],wdl:wdl[move.uci] ?? win)})
    }
}
@MainActor final class ReviewGradeAndDepthTests:XCTestCase {
    private var folder:URL!
    override func setUpWithError() throws {folder=FileManager.default.temporaryDirectory.appendingPathComponent("review-grades-\(UUID().uuidString)")}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:folder)}
    private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<2000 where !condition(){try await Task.sleep(for:.milliseconds(5))};XCTAssertTrue(condition(),what)}
    private let game="1. e4 d5 2. exd5 Qxd5 3. Nc3 *"

    /// R-1: a move's grade is the review's own expectation-loss thresholds, with the standard glyphs.
    func testGradesFollowTheExpectationLossThresholds() {
        XCTAssertEqual([nil,0,0.03,0.031,0.10,0.11,0.20,0.21,1].map{MoveGrade(expectationLoss:$0)},[nil,nil,nil,.inaccuracy,.inaccuracy,.mistake,.mistake,.blunder,.blunder])
        XCTAssertEqual(MoveGrade.allCases.map(\.glyph),["?!","?","??"]);XCTAssertEqual(MoveGrade.allCases.map(\.name),["Inaccuracy","Mistake","Blunder"])
    }
    /// R-1: grades are on with no environment flag: the whole-game analysis grades each move, and a review entered
    /// again shows the same grades from storage.
    func testTheWholeGameAnalysisGradesEachMove()async throws {
        let document=try PGNImporter.parse(Data(game.utf8))[0],engine=GradingEngine(),analyzer=ReviewAnalyzer(engine:engine,cacheDirectory:folder)
        // exd5 throws the game away, Qxd5 costs a little, Nc3 costs 15% of White's expected score.
        engine.wdl=["e4d5":[0,0,1000],"d8d5":[0,100,900],"b1c3":[700,300,0]]
        analyzer.startBatch(document);try await settle("the analysis finished"){analyzer.batchStatus=="ready"}
        let grades=document.mainline.map{analyzer.grade($0)}
        XCTAssertEqual(grades,[nil,nil,.blunder,.inaccuracy,.mistake])
        analyzer.reset();XCTAssertTrue(document.mainline.allSatisfy{analyzer.grade($0)==nil},"leaving clears the grades with the analysis")
        analyzer.restore(document);try await settle("the stored analysis is shown again"){analyzer.batchStatus=="ready"}
        XCTAssertEqual(document.mainline.map{analyzer.grade($0)},grades)
    }
    /// R-1: a deeper result the quick baseline supports is labelled without CHECKMATE_REVIEW_QUALITY_LABELS.
    func testAStableDeepResultIsLabelledWithoutAnEnvironmentFlag()async throws {
        XCTAssertNil(ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_QUALITY_LABELS"])
        let document=try PGNImporter.parse(Data(game.utf8))[0],analyzer=ReviewAnalyzer(engine:GradingEngine())
        let evidence=try await analyzer.analyze(document:document,node:document.mainline[0],revision:0,budget:ReviewPolicy.deepBudget)
        XCTAssertFalse(evidence.provisional);XCTAssertEqual(evidence.quality,"near-best")
    }
    /// R-4: opening a review with "Analyze When Opened" searches what is not stored yet, and only that.
    func testOpeningAnalyzesOnlyWhatIsNotStored()async throws {
        let document=try PGNImporter.parse(Data(game.utf8))[0],engine=GradingEngine(),analyzer=ReviewAnalyzer(engine:engine,cacheDirectory:folder)
        analyzer.restore(document,analyze:false);for _ in 0..<50{await Task.yield()}
        XCTAssertEqual(analyzer.batchStatus,"idle");XCTAssertTrue(engine.searches.isEmpty,"without the setting nothing starts")
        analyzer.restore(document,analyze:true);try await settle("opening analyzed the game"){analyzer.batchStatus=="ready"}
        let searched=engine.searches.count;XCTAssertGreaterThan(searched,0)
        analyzer.reset();analyzer.restore(document,analyze:true);try await settle("the stored analysis is shown"){analyzer.batchStatus=="ready"}
        for _ in 0..<50{await Task.yield()};XCTAssertEqual(engine.searches.count,searched,"a fully stored analysis is not run again")
    }
    /// R-4: "Analyze When Opened" is on for a new install and for settings saved before it existed.
    func testAnalyzeWhenOpenedIsOnByDefault()throws {
        XCTAssertTrue(AppSettings().reviewAutoAnalyze);XCTAssertTrue(AppSettings(raw:[:]).reviewAutoAnalyze);XCTAssertTrue(AppSettings(raw:["reviewAutoAnalyze":"no"]).reviewAutoAnalyze)
        var off=AppSettings();off.reviewAutoAnalyze=false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(off)).reviewAutoAnalyze,"the choice is saved")
    }
    /// R-4: never during a network game (D8).
    func testOpeningNeverAnalyzesDuringANetworkGame()async throws {
        let document=try PGNImporter.parse(Data(game.utf8))[0],engine=GradingEngine(),fairness=FairnessPolicy(),analyzer=ReviewAnalyzer(engine:engine,cacheDirectory:folder,fairness:fairness)
        fairness.participation.begin(.spectator);defer{fairness.participation.end()}
        analyzer.restore(document,analyze:true);for _ in 0..<200{await Task.yield()}
        XCTAssertEqual(analyzer.batchStatus,"idle");XCTAssertTrue(engine.searches.isEmpty)
    }
    /// R-5: review searches ask for more threads and a larger hash than practice, and record what they used; the
    /// deeper check covers up to five key moments.
    func testReviewSearchesUseReviewResourcesAndDeepenFiveMoments()async throws {
        XCTAssertEqual(EngineResources.review(processors:12),EngineResources(threads:10,hashMB:128))
        XCTAssertEqual(EngineResources.review(processors:2).threads,1);XCTAssertEqual(EngineResources.review(processors:1).threads,1)
        XCTAssertEqual(ReviewPolicy.criticalMomentsToDeepen,5)
        // Each deeper check costs about six seconds, so longer games check fewer and a 100-ply game stays in budget.
        XCTAssertEqual([20,60,61,80,100,120,140,400].map{ReviewPolicy.momentsToDeepen(plies:$0)},[5,5,4,4,3,2,1,1])
        let document=try PGNImporter.parse(Data("1. e4 d5 2. exd5 Qxd5 3. Nc3 Qa5 4. d4 Nf6 5. Nf3 Bf5 6. Bc4 e6 7. Bd2 c6 8. Nd5 Qd8 9. Nxf6+ gxf6 10. Bb3 Qxd4 *".utf8))[0]
        let engine=GradingEngine(),analyzer=ReviewAnalyzer(engine:engine);analyzer.resources=EngineResources(threads:3,hashMB:64)
        analyzer.startBatch(document);try await settle("the analysis finished"){analyzer.batchStatus=="ready"}
        XCTAssertTrue(engine.searches.allSatisfy{$0.resources==EngineResources(threads:3,hashMB:64)},"every review search asks for the review's resources")
        XCTAssertEqual(engine.searches.filter{$0.budget==ReviewPolicy.deepBudget}.count,5,"five key moments are checked more deeply")
        let evidence=try await analyzer.analyze(document:document,node:document.mainline[0],revision:0)
        XCTAssertEqual(evidence.options["Threads"],"3");XCTAssertEqual(evidence.options["Hash"],"64");XCTAssertEqual(evidence.options["Skill Level"],"20")
    }
    /// R-5: the whole-game analysis fits its budget. In the worst case every position searches twice (best and played
    /// move) and so does every deeper moment, whose quick baseline is the batch's own; long games search each position
    /// more briefly and check fewer moments more deeply, never below the quick floor.
    func testTheWholeGameAnalysisFitsItsBudget() {
        let lengths=[40,100,180,300],plans=lengths.map{ReviewPolicy.batchPlan(plies:$0)}
        XCTAssertEqual(plans,[ReviewBatchPlan(quickBudget:500,moments:5),ReviewBatchPlan(quickBudget:227,moments:3),ReviewBatchPlan(quickBudget:125,moments:1),ReviewBatchPlan(quickBudget:53,moments:0)])
        for (plies,plan) in zip(lengths,plans){XCTAssertLessThanOrEqual(ReviewPolicy.worstCaseMs(plies:plies,plan),ReviewPolicy.batchBudgetMs,"\(plies) plies");XCTAssertGreaterThanOrEqual(plan.quickBudget,ReviewPolicy.quickFloor)}
        XCTAssertEqual(ReviewPolicy.worstCaseMs(plies:100,plans[1]),79_880)
        // Ten seconds below the 90-second acceptance limit, for the app and the engine's own start.
        XCTAssertEqual(ReviewPolicy.batchBudgetMs,80_000)
        // Every search costs its budget and a fixed overhead, so past the floor's limit no plan fits; the limit is 153 moves.
        XCTAssertEqual(ReviewPolicy.longestFittingGame,307)
        XCTAssertLessThanOrEqual(ReviewPolicy.worstCaseMs(plies:307,ReviewPolicy.batchPlan(plies:307)),ReviewPolicy.batchBudgetMs)
        XCTAssertGreaterThan(ReviewPolicy.worstCaseMs(plies:308,ReviewPolicy.batchPlan(plies:308)),ReviewPolicy.batchBudgetMs)
        XCTAssertEqual(ReviewPolicy.batchPlan(plies:1),ReviewBatchPlan(quickBudget:500,moments:5))
    }
    /// R-5: a long game's whole-game analysis searches at its plan's budget, deepens its plan's moments, and comes back
    /// from storage as ready without a search; a position chosen afterwards reads the same stored evidence.
    func testALongGameFollowsItsPlan()async throws {
        let library=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/CheckmateCore/Resources/game-library/world-championship.pgn")
        // Carlsen–Nepomniachtchi, game 6 of 2021, the longest game in the library; only it is parsed, not the whole file.
        let text=try String(contentsOf:library,encoding:.utf8),game=try XCTUnwrap(text.components(separatedBy:"\n\n[Event").first{$0.contains("[Date \"2021.12.03\"]")})
        let document=try XCTUnwrap(PGNImporter.parse(Data(("[Event"+game).utf8)).first),plan=ReviewPolicy.batchPlan(plies:document.mainline.count)
        XCTAssertEqual(document.mainline.count,271);XCTAssertEqual(plan,ReviewBatchPlan(quickBudget:56,moments:1))
        let engine=GradingEngine(),analyzer=ReviewAnalyzer(engine:engine,cacheDirectory:folder)
        analyzer.startBatch(document);try await settle("the analysis finished"){analyzer.batchStatus=="ready"}
        XCTAssertEqual(engine.searches.filter{$0.budget==plan.quickBudget}.count,document.mainline.count,"every position at the plan's quick budget")
        XCTAssertEqual(engine.searches.filter{$0.budget==ReviewPolicy.deepBudget}.count,plan.moments,"the deeper check reuses the stored baseline")
        XCTAssertEqual(engine.searches.count,document.mainline.count+plan.moments)
        let before=engine.searches.count;_=try await analyzer.analyze(document:document,node:document.mainline[10],revision:0)
        XCTAssertEqual(engine.searches.count,before,"a chosen position reads the batch's evidence")
        let restored=GradingEngine(),again=ReviewAnalyzer(engine:restored,cacheDirectory:folder);again.restore(document)
        try await settle("the stored analysis came back"){again.batchStatus=="ready"};XCTAssertTrue(restored.searches.isEmpty)
    }
    /// R-23: Look Deeper on an imagined line searches at the deep budget, with the quick baseline that judges it.
    func testLookingDeeperAtAnIdeaUsesTheDeepBudget()async throws {
        let document=try PGNImporter.parse(Data(game.utf8))[0],engine=GradingEngine(),analyzer=ReviewAnalyzer(engine:engine)
        let quick=try await analyzer.analyzeBranch(document:document,root:document.mainline[1],moves:["b1c3"],revision:0)
        XCTAssertEqual(quick.budgetMs,ReviewPolicy.quickBudget);XCTAssertTrue(quick.provisional);XCTAssertEqual(engine.searches.map(\.budget),[ReviewPolicy.quickBudget])
        let deep=try await analyzer.analyzeBranch(document:document,root:document.mainline[1],moves:["b1c3"],revision:0,budget:ReviewPolicy.deepBudget)
        XCTAssertEqual(deep.budgetMs,ReviewPolicy.deepBudget);XCTAssertFalse(deep.provisional,"a deep line the quick baseline supports is not provisional")
        XCTAssertEqual(engine.searches.dropFirst().map(\.budget),[ReviewPolicy.deepBudget,ReviewPolicy.quickBudget])
        XCTAssertEqual(deep.root.lines.first?.depth,20)
    }
}
