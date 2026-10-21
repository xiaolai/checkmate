import XCTest
import CheckmateCore
import CheckmateTestSupport
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// An engine that keeps the mover's chances at about three quarters with every move but the `poor` ones, which leave
/// a quarter. Good moves rank first, in the rules' order; WDL is from White's side, as Stockfish reports it.
@MainActor private final class JudgeEngine:TestEngineService {
    let poor:Set<String>;private(set) var searches=0
    init(poor:Set<String>){self.poor=poor}
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {try lines(fen:fen,only:[],multiPv:multiPv)}
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
        let position=try ChessRules(fen:startFEN);for move in moves{try position.move(uci:move)};return try lines(fen:position.fen,only:searchMoves,multiPv:multiPv)
    }
    private func lines(fen:String,only:[String],multiPv:Int)throws -> EngineAnalysis {
        searches+=1;let rules=try ChessRules(fen:fen),white=rules.turn=="w",legal=rules.moves().filter{only.isEmpty || only.contains($0.uci)}
        let ranked=(legal.filter{!poor.contains($0.uci)}+legal.filter{poor.contains($0.uci)}).prefix(max(1,multiPv))
        return EngineAnalysis(bestMove:ranked.first?.uci,budgetMs:100,lines:ranked.enumerated().map{index,move in let good=(!poor.contains(move.uci))==white
            return AnalysisLine(depth:20,multiPv:index+1,score:AnalysisScore(kind:"cp",value:good ? 150:-150),pv:[move.uci],san:[move.san],wdl:good ? [700,100,200]:[200,100,700])})
    }
}

/// R-18: retry mode steps through the learner's costly moves, judges each try with the engine, shows the answer after
/// two tries, and is closed during a network game.
@MainActor final class ReviewRetryTests:XCTestCase {
    private let pgn="1. f3 e5 2. g4 Qh4# 0-1"
    private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<2000 where !condition(){try await Task.sleep(for:.milliseconds(5))};XCTAssertTrue(condition(),what)}
    private func analyzed(fairness given:FairnessPolicy?=nil)async throws -> (ReviewController,ReviewAnalyzer,ReviewRetry,GameDocument,JudgeEngine) {
        let fairness=given ?? FairnessPolicy(),document=try PGNImporter.parse(Data(pgn.utf8))[0],engine=JudgeEngine(poor:["f2f3","g2g4"]),analyzer=ReviewAnalyzer(engine:engine,fairness:fairness),review=ReviewController()
        review.fairness=fairness;review.analyzer=analyzer;review.load(document);analyzer.startBatch(document);try await settle("the analysis finished"){analyzer.batchStatus=="ready"}
        return (review,analyzer,ReviewRetry(review:review,analyzer:analyzer),document,engine)
    }

    func testTheTargetsAreOneSidesMistakesAndBlundersInGameOrder()throws {
        let document=try PGNImporter.parse(Data(pgn.utf8))[0],main=document.mainline
        let losses=[main[0]:0.5,main[1]:0.3,main[2]:0.06,main[3]:0.5]
        XCTAssertEqual(ReviewRetry.targets(document,losses:losses,side:"w"),[main[0]],"an inaccuracy is not retried")
        XCTAssertEqual(ReviewRetry.targets(document,losses:losses,side:"b"),[main[1],main[3]])
        XCTAssertEqual(ReviewRetry.targets(document,losses:losses,side:nil),[main[0],main[1],main[3]],"a game the learner did not play retries both sides")
    }
    func testTriesAreJudgedAndTheAnswerShowsAfterTwo()async throws {
        let (review,analyzer,retry,document,engine)=try await analyzed(),main=document.mainline
        XCTAssertTrue(retry.available(side:"w"));XCTAssertFalse(retry.available(side:"b"),"Black made no costly move")
        try retry.start(side:"w");XCTAssertEqual(retry.targets,[main[0],main[2]]);XCTAssertEqual(review.nodeID,0,"the position before 1. f3")
        XCTAssertEqual(retry.phase,.trying(tries:0,last:nil));XCTAssertTrue(retry.hidesAnswer)
        XCTAssertEqual(retry.message,"You played 1. f3 here. Find a better move.")
        let searches=engine.searches;try await retry.attempt("f2f3")
        XCTAssertEqual(retry.phase,.trying(tries:1,last:.played("f3")),"the game's own move is wrong at once");XCTAssertEqual(engine.searches,searches,"and needs no search")
        try await retry.attempt("g2g4");XCTAssertGreaterThan(engine.searches,searches,"another move is judged by the engine")
        let start=try ChessRules(),best=try XCTUnwrap(start.moves().first{!["f2f3","g2g4"].contains($0.uci)})
        XCTAssertEqual(retry.phase,.revealed(best.san),"two tries show the answer");XCTAssertFalse(retry.hidesAnswer)
        XCTAssertEqual(review.branch?.moves,[best.uci],"the board shows it");XCTAssertTrue(review.branchesForSaving.isEmpty,"as a preview, never a kept idea")
        XCTAssertEqual(analyzer.bestMoves[0],best.uci)
        try retry.next();XCTAssertEqual(review.nodeID,main[1],"the position before 2. g4");XCTAssertNil(review.branch);XCTAssertEqual(retry.phase,.trying(tries:0,last:nil))
        try await retry.attempt("e2e4");XCTAssertEqual(retry.phase,.solved("e4"));XCTAssertEqual(retry.solved,1);XCTAssertEqual(review.branch?.moves,["e2e4"])
        try retry.next();XCTAssertEqual(retry.phase,.finished);XCTAssertEqual(retry.message,"You found a better move in 1 of 2 positions.")
        retry.end();XCTAssertFalse(retry.active)
    }
    func testTheBoardTriesAMoveWithoutPlayingIt()async throws {
        let (review,_,retry,_,_)=try await analyzed()
        try retry.start(side:"w");try await retry.choose("g2");XCTAssertEqual(review.selected,"g2","the first square chooses the piece")
        try await retry.choose("g4");XCTAssertNil(review.selected);XCTAssertEqual(retry.phase,.trying(tries:1,last:.worse("g4")))
        XCTAssertNil(review.branch,"a wrong try leaves the position as it was");XCTAssertTrue(review.branchesForSaving.isEmpty)
        XCTAssertEqual(retry.message,"g4 is not better. Try once more.")
    }
    func testANetworkGameEndsAndRefusesRetrying()async throws {
        let fairness=FairnessPolicy(),(review,analyzer,retry,document,_)=try await analyzed(fairness:fairness)
        try retry.start(side:"w");fairness.participation.begin(.player);defer{fairness.participation.end()}
        XCTAssertFalse(retry.active,"joining a network game ends it");XCTAssertFalse(retry.available(side:"w"))
        XCTAssertThrowsError(try retry.start(side:"w"))
        do{_=try await analyzer.judgeAttempt(document:document,node:document.mainline[0],uci:"e2e4");XCTFail("judged during a network game")}catch{XCTAssertEqual(error.localizedDescription,CheckmateError.invalid(FairnessPolicy.refusal).localizedDescription)}
        XCTAssertNil(review.branch)
    }
    func testOpeningAnotherRecordEndsIt()async throws {
        let (review,_,retry,_,_)=try await analyzed()
        try retry.start(side:"w");review.load(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]);XCTAssertFalse(retry.active)
    }
    func testTheLearnersSideComesFromTheirOwnGame() {
        XCTAssertEqual(ReviewRetry.learnerSide(.currentGame,current:"b",previous:"w"),"b")
        XCTAssertEqual(ReviewRetry.learnerSide(.previousGame,current:"b",previous:"w"),"w")
        for other in [ReviewProvenance.imported,.libraryGame,.collectionGame,.trainingGame] {XCTAssertNil(ReviewRetry.learnerSide(other,current:"b",previous:"w"),"\(other) retries both sides")}
    }
    func testEveryMessageIsPlain() {
        let texts=[ReviewRetry.message(.trying(tries:0,last:nil),played:"12… Nf5",mover:"b",own:false),ReviewRetry.message(.trying(tries:0,last:nil),played:"3. Bc4",mover:"w",own:false),ReviewRetry.message(.trying(tries:0,last:nil),played:"3. Bc4",mover:"w",own:true),ReviewRetry.message(.trying(tries:1,last:.played("Nf5")),played:"",mover:"",own:true),ReviewRetry.message(.judging(tries:1),played:"",mover:"",own:true),ReviewRetry.message(.solved("Qh5"),played:"",mover:"",own:true),ReviewRetry.message(.revealed(nil),played:"",mover:"",own:true),ReviewRetry.message(.revealed("Qh5"),played:"",mover:"",own:true)]
        XCTAssertEqual(texts,["Black played 12… Nf5 here. Find a better move.","White played 3. Bc4 here. Find a better move.","You played 3. Bc4 here. Find a better move.","Nf5 is the move played in the game. Try another.","Checking your move…","Qh5 is a good move here.","The engine has no move to show here.","The engine's choice here is Qh5."])
        XCTAssertEqual(ReviewRetry.summary(solved:1,total:1),"You found a better move in 1 of 1 position.")
        XCTAssertEqual(ReviewRetry.summary(solved:2,total:3),"You found a better move in 2 of 3 positions.")
    }
}
