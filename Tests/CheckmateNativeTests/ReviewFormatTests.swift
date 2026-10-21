import XCTest
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication

/// The review pane's pure rules: move-table rows, header text, scores, takeaways and the evaluation series.
@MainActor final class ReviewFormatTests:XCTestCase {
    private func game(_ pgn:String)throws -> GameDocument {try PGNImporter.parse(Data(pgn.utf8))[0]}
    private func sans(_ d:GameDocument,_ rows:[ReviewFormat.MoveRow])->[String] {rows.map{"\($0.number):\($0.white.flatMap{d.nodes[$0].san} ?? "-")/\($0.black.flatMap{d.nodes[$0].san} ?? "-")"}}

    func testRowsPairMovesByTheirOwnMoveNumbers() throws {
        let white=try game("1. e4 e5 2. Nf3 *")
        XCTAssertEqual(sans(white,ReviewFormat.rows(white,line:white.mainline)),["1:e4/e5","2:Nf3/-"],"An odd-length game ends with a White-only row")
        // A record starting with Black to move on move 17 shows 17. … then the Black move, never 1.
        let black=try game("[FEN \"4k3/4p3/8/8/8/8/4P3/4K3 b - - 0 17\"]\n[SetUp \"1\"]\n\n17... Kd7 18. Kd2 Kc6 19. Kc2 *")
        XCTAssertEqual(sans(black,ReviewFormat.rows(black,line:black.mainline)),["17:-/Kd7","18:Kd2/Kc6","19:Kc2/-"])
        XCTAssertEqual(ReviewFormat.moveLabel(black.nodes[black.mainline[0]]),"17, Black, Kd7")
        XCTAssertEqual(ReviewFormat.moveText(black.nodes[black.mainline[0]]),"17… Kd7")
        XCTAssertEqual(ReviewFormat.rows(white,line:[]),[])
    }
    func testHeaderLeavesOutUnknownParts() throws {
        let full=try game("[Event \"London\"]\n[Site \"London ENG\"]\n[Date \"1912.??.??\"]\n[White \"Edward Lasker\"]\n[Black \"George Alan Thomas\"]\n[Result \"1-0\"]\n\n1. d4 e6 1-0")
        XCTAssertEqual(ReviewFormat.players(full),"Edward Lasker – George Alan Thomas")
        XCTAssertEqual(ReviewFormat.details(full),"London · 1912","A site that repeats the event and the unknown month and day are left out")
        let unknown=try game("[Event \"?\"]\n[Site \"\"]\n[Date \"????.??.??\"]\n[White \"?\"]\n[Black \"?\"]\n\n1. e4 *")
        XCTAssertNil(ReviewFormat.details(unknown));XCTAssertEqual(ReviewFormat.players(unknown),"Imported game")
        let one=try game("[White \"*Bold* _x_\"]\n[Date \"1851.06.21\"]\n\n1. e4 *")
        XCTAssertEqual(ReviewFormat.players(one),"*Bold* _x_ – Black");XCTAssertEqual(ReviewFormat.details(one),"1851.06.21")
        XCTAssertEqual(ReviewFormat.players(try PGNImporter.parse(Data("1. e4 *".utf8),provenance:"Current game")[0]),"Current game")
        XCTAssertEqual(ReviewFormat.players(try game("8/8/8/4k3/8/8/8/4K3 w - - 0 1")),"Imported position")
        XCTAssertEqual(["1-0","0-1","1/2-1/2","*"].map(ReviewFormat.result),["1–0","0–1","½–½","Unfinished"])
        // Assistance plan A11: a network game's agreed assistance is a line of its own; a record without the tag has none.
        let assisted=try game("[Event \"Checkmate network game\"]\n[Assistance \"White: Hints on request; Black: Off\"]\n\n1. e4 {Hint shown} *")
        XCTAssertEqual(ReviewFormat.assistance(assisted),"Assistance: White: Hints on request; Black: Off");XCTAssertNil(ReviewFormat.assistance(full))
    }
    func testScoresReadFromWhitesSide() {
        func cp(_ v:Int,_ bound:String?=nil)->String {ReviewFormat.score(AnalysisScore(kind:"cp",value:v,bound:bound))}
        XCTAssertEqual([cp(80),cp(-140),cp(0),cp(-4),cp(1234)],["+0.8","−1.4","0.0","0.0","+12.3"])
        XCTAssertEqual(cp(35,"lower"),"≥+0.3");XCTAssertEqual(cp(-35,"upper"),"≤−0.3")
        XCTAssertEqual([3,-2,0].map{ReviewFormat.score(AnalysisScore(kind:"mate",value:$0))},["M3","−M2","#"])
    }
    func testTakeawaysDropTheOneRepeatingTheSummary() {
        let e=ReviewExplanation(title:"Start",summary:"White won by checkmate.",facts:[],takeaways:["White won by checkmate. ","by checkmate.","Develop pieces first."],historyNote:nil)
        XCTAssertEqual(ReviewFormat.takeaways(e),["Develop pieces first."]);XCTAssertEqual(ReviewFormat.takeaways(nil),[])
    }
    func testKeyMomentsAreAtMostFiveInGameOrder() throws {
        let d=try game("1. e4 d5 2. exd5 Qxd5 3. Nc3 Qa5 4. d4 Nf6 5. Nf3 Bf5 6. Bc4 e6 7. Bd2 c6 8. Nd5 Qd8 9. Nxf6+ gxf6 10. Bb3 Qxd4 *")
        let heuristic=ReviewFormat.heuristicMoments(d)
        XCTAssertEqual(heuristic.map{d.nodes[$0].san!},["exd5","Qxd5","Nxf6+","gxf6","Qxd4"])
        XCTAssertEqual(ReviewFormat.keyMoments(heuristic,in:d,engine:false),heuristic,"Five or fewer keep game order")
        // When fewer fit, the heuristic keeps the final move; engine moments keep the most important, shown in game order.
        XCTAssertEqual(ReviewFormat.keyMoments(heuristic,in:d,limit:3,engine:false).map{d.nodes[$0].san!},["exd5","Qxd5","Qxd4"])
        XCTAssertEqual(ReviewFormat.keyMoments(heuristic.reversed(),in:d,limit:2,engine:true).map{d.nodes[$0].san!},["gxf6","Qxd4"])
    }
    func testSeriesClampsMarksGapsAndUsesTheResultAtMate() throws {
        let d=try game("1. f3 e5 2. g4 Qh4# 0-1"),line=d.mainline
        let scores:[Int:AnalysisScore]=[0:AnalysisScore(kind:"cp",value:20),line[0]:AnalysisScore(kind:"cp",value:-2500),line[2]:AnalysisScore(kind:"mate",value:-1),line[3]:AnalysisScore(kind:"cp",value:300)]
        // The engine's last value is overruled by the checkmate on the board: Black mates, so the limit for Black.
        XCTAssertEqual(ReviewFormat.series(d,evaluations:scores,outcome:ReviewFormat.finalOutcome(d)),[0.2,-5,nil,-5,-5])
        let open=try game("1. e4 *");XCTAssertEqual(ReviewFormat.series(open,evaluations:[:],outcome:ReviewFormat.finalOutcome(open)),[nil,nil],"No score is a gap, not 0")
        XCTAssertEqual(ReviewFormat.mainlineIndex(d,node:line[1]),2);XCTAssertNil(ReviewFormat.mainlineIndex(d,node:nil));XCTAssertEqual(ReviewFormat.node(d,index:0),0);XCTAssertEqual(ReviewFormat.node(d,index:99),line.last)
    }
    /// The analyzer's series is the played move's score after each move, never the parent's best line; a deeper pass
    /// replaces a quick one.
    func testSeriesFromAFixtureAnalyzer() async throws {
        final class Fixture:EngineService {
            var binaryIdentity:String {"review-format-fixture"}
            var capabilities:EngineCapabilities {EngineCapabilities()}
            func prepare()async throws {}
            func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {EngineAnalysis()}
            func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
                // The best line from a parent after k moves scores 50+k; the played move after it scores 10 per ply, 5 more when deep.
                let score=searchMoves.isEmpty ? 50+moves.count:10*(moves.count+1)+(budget>=ReviewPolicy.deepBudget ? 5:0)
                return EngineAnalysis(bestMove:searchMoves.first ?? "a1a1",budgetMs:budget,lines:[AnalysisLine(depth:20,multiPv:1,score:AnalysisScore(kind:"cp",value:score),pv:[searchMoves.first ?? "a1a1"],san:[])])
            }
        }
        let analyzer=ReviewAnalyzer(engine:Fixture()),d=try game("1. e4 e5 2. Nf3 *")
        analyzer.startBatch(d);let start=Date()
        while ["pending","deepening"].contains(analyzer.batchStatus),Date().timeIntervalSince(start)<20{try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(analyzer.batchStatus,"ready")
        // Nf3, the final move, is the one moment deepened.
        let series=ReviewFormat.series(d,evaluations:analyzer.evaluations,outcome:ReviewFormat.finalOutcome(d)).map{$0.map{($0*100).rounded()/100}}
        XCTAssertEqual(series,[0.5,0.1,0.2,0.35])
        analyzer.cancelBatch();XCTAssertEqual(analyzer.batchStatus,"ready","Cancelling a finished analysis changes nothing");XCTAssertFalse(analyzer.evaluations.isEmpty)
        analyzer.reset();XCTAssertTrue(analyzer.evaluations.isEmpty,"Leaving clears the published scores")
    }
    /// A recorded draw ends the graph level even when the board is not finished; a resignation leaves the engine's value;
    /// a checkmate on the board decides over a contradicting Result tag.
    func testFinalOutcomeFollowsTheRecordedEnding() throws {
        XCTAssertEqual(ReviewFormat.finalOutcome(try game("1. e4 e5 1/2-1/2")),0)
        XCTAssertNil(ReviewFormat.finalOutcome(try game("1. e4 e5 1-0")))
        XCTAssertEqual(ReviewFormat.finalOutcome(try game("1. f3 e5 2. g4 Qh4# 0-1")),-5)
        let d=try game("1. e4 e5 1/2-1/2")
        XCTAssertEqual(ReviewFormat.series(d,evaluations:[d.mainline[1]:AnalysisScore(kind:"cp",value:90)],outcome:ReviewFormat.finalOutcome(d)),[nil,nil,0])
        XCTAssertNil(ReviewFormat.finalOutcome(try game("[SetUp \"1\"]\n[FEN \"4k3/8/8/8/8/8/8/4K3 w - - 0 1\"]\n\n*")),"No moves, no outcome")
    }
    /// R-19: an idea is named by the move it branches after and its first moves, as the move list writes them.
    func testIdeaLabelNamesItsRootMoveAndFirstMoves() throws {
        let d=try game("1. e4 e5 2. Nf3 Nc6 *")
        func idea(_ root:Int,_ moves:[String])->ReviewBranch {var branch=ReviewBranch(root:root);branch.moves=moves;return branch}
        XCTAssertEqual(ReviewFormat.ideaLabel(d,idea(d.mainline[1],["f1c4","g8f6","d2d3","f8c5"])),"After 1…e5: 2.Bc4 Nf6 3.d3 …")
        XCTAssertEqual(ReviewFormat.ideaLabel(d,idea(d.mainline[0],["c7c5","g1f3"])),"After 1.e4: 1…c5 2.Nf3","A line starting with Black's move numbers it")
        XCTAssertEqual(ReviewFormat.ideaLabel(d,idea(0,["d2d4"])),"From the start: 1.d4")
        XCTAssertEqual(ReviewFormat.ideaLabel(d,idea(d.mainline[3],[])),"After 2…Nc6")
        XCTAssertEqual(ReviewFormat.ideaLabel(d,idea(d.mainline[3],["f1b5","a1a8"])),"After 2…Nc6: 3.Bb5 …","A move that cannot be played ends the list")
    }
    /// R-3: a cancelled analysis says how far it got.
    func testPartialAnalysisSaysHowFarItGot() {
        XCTAssertEqual(ReviewFormat.partialAnalysis(completed:12,total:40),"Analyzed 12 of 40 moves")
        XCTAssertEqual(ReviewFormat.partialAnalysis(completed:40,total:40),"Analyzed all 40 moves; the deeper check is unfinished")
    }
    /// R-16: the graph is clamped to ±5 pawns, so an ordinary advantage is visible beside a decisive one.
    func testTheGraphLimitIsFivePawns() {XCTAssertEqual(ReviewFormat.evaluationLimit,5)}
    /// R-7: the importer's annotation glyphs are shown after the move, move glyphs first; an unknown one is left out.
    func testAnnotationGlyphsAndTheirMeanings() throws {
        let d=try game("1. e4! e5?! 2. Nf3 $14 Nc6 $200 3. Bb5 $3 $16 *"),line=d.mainline
        XCTAssertEqual(line.map{ReviewFormat.glyphs(d.nodes[$0].nags)},["!","?!","⩲","","!! ±"])
        XCTAssertEqual(ReviewFormat.glyphMeanings(d.nodes[line[4]].nags),"Brilliant move, White is better");XCTAssertNil(ReviewFormat.glyphMeanings(d.nodes[line[3]].nags))
        XCTAssertEqual([1,2,3,4,5,6,7,10,13,14,15,16,17,18,19].map{ReviewFormat.glyphs([$0])},["!","?","!!","??","!?","?!","□","=","∞","⩲","⩱","±","∓","+−","−+"])
    }
    /// R-7: the record's own comments, without the clock and evaluation commands some sites embed in them.
    func testCommentsLeaveOutEmbeddedCommands() throws {
        let d=try game("{Opening note} 1. e4 {A strong  start [%clk 0:05:00]} e5 {[%eval 0.3]} 2. Nf3 *"),line=d.mainline
        XCTAssertEqual(ReviewFormat.comments(d.nodes[0]),["Opening note"])
        XCTAssertEqual(ReviewFormat.comments(d.nodes[line[0]]),["A strong start"]);XCTAssertEqual(ReviewFormat.comments(d.nodes[line[1]]),[])
    }
    /// R-1: a graded move explains its grade in plain words, from the side that played it.
    func testGradeLineSaysWhatTheMoveGaveUp() {
        XCTAssertEqual(ReviewFormat.gradeLine(.mistake,loss:0.153,side:"w"),"Mistake (?): this move gave up about 15% of White's chances.")
        XCTAssertEqual(ReviewFormat.gradeLine(.blunder,loss:0.6,side:"b"),"Blunder (??): this move gave up about 60% of Black's chances.")
    }
    /// R-16/R-29: hovering or moving through the graph reads the move, its score and its grade.
    func testGraphReadoutNamesTheMoveScoreAndGrade() throws {
        let d=try game("1. e4 e5 2. Nf3 *")
        XCTAssertEqual(ReviewFormat.readout(d,index:3,score:AnalysisScore(kind:"cp",value:80),grade:.inaccuracy),"2. Nf3?! +0.8")
        XCTAssertEqual(ReviewFormat.readout(d,index:2,score:AnalysisScore(kind:"mate",value:-2),grade:nil),"1… e5 −M2")
        XCTAssertEqual(ReviewFormat.readout(d,index:0,score:nil,grade:nil),"Start, no score")
        let label=ReviewFormat.graphLabel(d,index:3,last:3,score:AnalysisScore(kind:"cp",value:80),grade:.inaccuracy)
        XCTAssertEqual(label,"Evaluation graph, position 3 of 3, 2. Nf3, +0.8, inaccuracy")
        XCTAssertNotNil(label.range(of:#"Evaluation graph, position (\d+) of (\d+)"#,options:.regularExpression),"the pointer gate reads the position from this label")
        XCTAssertEqual(ReviewFormat.graphLabel(d,index:nil,last:3,score:nil,grade:nil),"Evaluation graph, not on the main line")
        XCTAssertEqual(ReviewFormat.pointLabel(d,index:1,score:AnalysisScore(kind:"cp",value:30),grade:nil),"1. e4, +0.3")
    }
    /// R-23: the engine comparison says how deep the search went.
    func testEvidenceCaptionShowsDepth() {
        XCTAssertEqual(ReviewFormat.evidenceCaption(provisional:false,depth:24),"Deeper engine comparison · depth 24")
        XCTAssertEqual(ReviewFormat.evidenceCaption(provisional:true,depth:nil),"Provisional engine estimate")
    }
    /// An engine fixture with win/draw/loss: Black's 1...e5 looks costly to the quick pass and fine to the deep one; with
    /// `scorelessDeep` the deep pass returns no line for the played move.
    private final class WDLFixture:EngineService {
        let scorelessDeep:Bool
        init(scorelessDeep:Bool){self.scorelessDeep=scorelessDeep}
        var binaryIdentity:String {"review-format-wdl-fixture"}
        var capabilities:EngineCapabilities {EngineCapabilities()}
        func prepare()async throws {}
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {EngineAnalysis()}
        func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
            let deep=budget>=ReviewPolicy.deepBudget,even=[0,1000,0]
            if searchMoves.isEmpty{return EngineAnalysis(bestMove:"a1a1",budgetMs:budget,lines:[AnalysisLine(depth:20,multiPv:1,score:AnalysisScore(kind:"cp",value:0),pv:["a1a1"],san:[],wdl:even)])}
            if deep && scorelessDeep{return EngineAnalysis(bestMove:searchMoves[0],budgetMs:budget,lines:[])}
            let costly=moves.count==1 && !deep
            return EngineAnalysis(bestMove:searchMoves[0],budgetMs:budget,lines:[AnalysisLine(depth:20,multiPv:1,score:AnalysisScore(kind:"cp",value:costly ? 150:0),pv:[searchMoves[0]],san:[],wdl:costly ? [400,600,0]:even)])
        }
    }
    private func runBatch(_ analyzer:ReviewAnalyzer,_ d:GameDocument)async throws {
        analyzer.startBatch(d);let start=Date()
        while ["pending","deepening"].contains(analyzer.batchStatus),Date().timeIntervalSince(start)<20{try await Task.sleep(for:.milliseconds(10))}
        XCTAssertEqual(analyzer.batchStatus,"ready")
    }
    func testADeeperPassRetractsAQuietMomentItNoLongerRatesCostly() async throws {
        let analyzer=ReviewAnalyzer(engine:WDLFixture(scorelessDeep:false)),d=try game("1. e4 e5 2. Nf3 *");try await runBatch(analyzer,d)
        // e5 was the most costly quick moment, so it was the one deepened; the deep pass found it costs nothing.
        XCTAssertFalse(analyzer.moments.contains{$0.id==d.mainline[1]},"A retracted quiet move stayed a moment")
        XCTAssertTrue(analyzer.moments.contains{$0.id==d.mainline[2]},"The final move is always a moment")
        XCTAssertEqual(analyzer.evaluations[d.mainline[1]]?.value,0,"The deep score replaced the quick one")
    }
    func testADeepResultWithoutAScoreLeavesAGap() async throws {
        // Only the costliest moment is deepened here, so the final move keeps its quick score beside the gap.
        let analyzer=ReviewAnalyzer(engine:WDLFixture(scorelessDeep:true)),d=try game("1. e4 e5 2. Nf3 *");analyzer.momentsToDeepen=1;try await runBatch(analyzer,d)
        XCTAssertNil(analyzer.evaluations[d.mainline[1]],"An older quick score stood in for a missing deep one")
        XCTAssertNotNil(analyzer.evaluations[d.mainline[2]])
    }
}
