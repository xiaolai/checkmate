import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

@MainActor final class ReviewPerformanceTests:XCTestCase {
    func testImportNavigationAndSelectedLatency()async throws {
        guard let path=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_PERFORMANCE"] else{throw XCTSkip("Explicit isolated test-host performance measurement gate.")}
        var pgn="";for i in 0..<50{pgn+="\(i*2+1). Nf3 Nf6 \(i*2+2). Ng1 Ng8 "};pgn+="*"
        let bytes=Data(pgn.utf8),start=Date(),document=try await Task.detached{try PGNImporter.parse(bytes)[0]}.value,importMs=Date().timeIntervalSince(start)*1000
        let session=try GameSession(engine:nil),review=ReviewController();review.open(document,practice:session);var navigation:[Double]=[]
        for node in document.mainline {let start=Date();try review.select(node);_ = review.displayFEN;_ = review.board;_ = review.explanation;_ = review.explanation;_ = review.destinations;navigation.append(Date().timeIntervalSince(start)*1000)}
        navigation.sort();let p95=navigation[Int(Double(navigation.count)*0.95)]
        let engine=NativeEngine(),analyzer=ReviewAnalyzer(engine:engine),analysisStart=Date();_ = try await analyzer.analyze(document:document,node:1,revision:review.revision);let selectedMs=Date().timeIntervalSince(analysisStart)*1000
        let result:[String:Any]=["workload":"200-ply authored repetition/navigation stress fixture, not quality calibration","plies":document.mainline.count,"importMs":importMs,"navigationP50Ms":navigation[navigation.count/2],"navigationP95Ms":p95,"selectedAnalysisMs":selectedMs,"importTargetMs":1000,"navigationTargetMs":100,"selectedTargetMs":2000,"engine":engine.capabilities.name,"engineHash":engine.binaryIdentity,"simultaneousCalibration":"Explicitly report if a baseline node-tier calibration was running; these timings are conservative contention observations."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path));XCTAssertLessThanOrEqual(importMs,1000);XCTAssertLessThanOrEqual(p95,100);XCTAssertLessThanOrEqual(selectedMs,2000)
    }
    func testMaximumMainlineNavigationScale()async throws {
        guard let path=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_PERFORMANCE"] else{throw XCTSkip("Explicit test-host scale observation.")}
        var pgn="";for i in 0..<500{pgn+="\(i*2+1). Nf3 Nf6 \(i*2+2). Ng1 Ng8 "};pgn+="*"
        let bytes=Data(pgn.utf8),start=Date(),document=try await Task.detached{try PGNImporter.parse(bytes)[0]}.value,importMs=Date().timeIntervalSince(start)*1000
        XCTAssertEqual(document.mainline.count,2000)
        let review=ReviewController(),session=try GameSession(engine:nil);review.open(document,practice:session)
        var samples:[Double]=[]
        for node in stride(from:1,through:2000,by:100) {let start=Date();try review.select(node);_ = review.board;_ = review.displayFEN;_ = review.explanation;_ = review.destinations;samples.append(Date().timeIntervalSince(start)*1000)}
        samples.sort();let p95=samples[Int(Double(samples.count)*0.95)]
        try JSONSerialization.data(withJSONObject:["plies":2000,"importMs":importMs,"navigationP95Ms":p95,"navigationSamplesMs":samples,"workload":"Maximum supported synthetic repetition record; sampled navigation; concurrent node-tier calibration"],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path+".2000.json"))
        XCTAssertLessThanOrEqual(p95,100)
    }

    func testSelectedQuickP95OnActualGame()async throws {
        guard let path=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_PERFORMANCE"] else{throw XCTSkip("Explicit test-host selected quick p95 gate.")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/GameReview")
        let document=try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent("games/public-07.pgn")))[0],engine=NativeEngine(),analyzer=ReviewAnalyzer(engine:engine)
        var samples:[Double]=[],rows:[[String:Any]]=[]
        for offset in [5,10,20,30,40,50,60,70,80,90] {let node=document.mainline[offset-1],start=Date();let evidence=try await analyzer.analyze(document:document,node:node,revision:offset);let milliseconds=Date().timeIntervalSince(start)*1000;samples.append(milliseconds);rows.append(["node":node,"milliseconds":milliseconds,"budgetMs":evidence.budgetMs,"historyHash":evidence.historyHash])}
        samples.sort();let p95=samples[Int(Double(samples.count)*0.95)]
        try JSONSerialization.data(withJSONObject:["p95Ms":p95,"samples":rows,"documentHash":document.contentHash,"engineHash":engine.binaryIdentity,"workload":"Ten distinct positions from actual public game; cold analyzer and engine first sample, no disk cache; concurrent separate calibration"],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path+".selected-p95.json"))
        XCTAssertLessThanOrEqual(p95,2000)
    }

    /// R-5: the whole-game analysis of a 100-ply game (public-07's first 100 plies) and a 271-ply one (Carlsen–
    /// Nepomniachtchi 2021, game 6) with each game's plan and `EngineResources.review()`, cold. Reports wall time, the
    /// plan, the searches run and the overhead each cost beyond its budget to the path in CHECKMATE_REVIEW_RESOURCES;
    /// each run stays within the 90-second acceptance limit and below the plan's worst case.
    func testWholeGameAnalysisFitsItsBudget()async throws {
        guard let path=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_RESOURCES"] else{throw XCTSkip("Explicit test-host measurement of the whole-game analysis budget.")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let full=try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent("Fixtures/GameReview/games/public-07.pgn")))[0]
        let movetext=full.mainline.prefix(100).map{id in let n=full.nodes[id];return (n.side=="w" ? "\(n.fullmove). ":"")+(n.san ?? "")}.joined(separator:" ")+" *"
        let library=try String(contentsOf:root.deletingLastPathComponent().appendingPathComponent("Sources/CheckmateCore/Resources/game-library/world-championship.pgn"),encoding:.utf8)
        let long=try XCTUnwrap(library.components(separatedBy:"\n\n[Event").first{$0.contains("[Date \"2021.12.03\"]")})
        let games=[("public-07, first 100 plies",try PGNImporter.parse(Data(movetext.utf8))[0]),("Carlsen-Nepomniachtchi 2021 game 6",try PGNImporter.parse(Data(("[Event"+long).utf8))[0])]
        XCTAssertEqual(games.map{$0.1.mainline.count},[100,271])
        func mean(_ values:[Int])->Double {values.isEmpty ? 0:(Double(values.reduce(0,+))/Double(values.count)*10).rounded()/10}
        // A position searched once when the played move is among the root's lines, twice otherwise, none when the game is over.
        func searches(_ e:ReviewEvidence)->Int {e.root.lines.isEmpty ? 0:e.root.lines.contains{$0.pv.first==e.played?.lines.first?.pv.first} || e.played==nil ? 1:2}
        var runs:[[String:Any]]=[]
        for (name,document) in games {
            let engine=NativeEngine(),analyzer=ReviewAnalyzer(engine:engine),plan=ReviewPolicy.batchPlan(plies:document.mainline.count)
            try await engine.prepare();let start=Date();analyzer.startBatch(document)
            while ["pending","deepening"].contains(analyzer.batchStatus),Date().timeIntervalSince(start)<300{try await Task.sleep(for:.milliseconds(50))}
            let seconds=Date().timeIntervalSince(start);XCTAssertEqual(analyzer.batchStatus,"ready",name)
            // The batch stored each search's evidence, so these read it back at its budget, after the timing; a deeper
            // moment's read-back also runs the learner's full quick baseline, which the batch does not.
            var quick:[Int]=[],deep:[Int]=[],count=0,budgetMs=0;let deepened=analyzer.moments.prefix(plan.moments).map(\.id)
            for node in document.mainline{let e=try await analyzer.analyze(document:document,node:node,revision:0,budget:plan.quickBudget);if let d=e.root.lines.first?.depth{quick.append(d)};count+=searches(e);budgetMs+=searches(e)*max(EngineSearchPolicy.minimumMs,plan.quickBudget)}
            for node in deepened{let e=try await analyzer.analyze(document:document,node:node,revision:0,budget:ReviewPolicy.deepBudget);if let d=e.root.lines.first?.depth{deep.append(d)};count+=searches(e);budgetMs+=searches(e)*ReviewPolicy.deepBudget}
            let worst=ReviewPolicy.worstCaseMs(plies:document.mainline.count,plan)
            runs.append(["game":name,"plies":document.mainline.count,"quickBudgetMs":plan.quickBudget,"moments":plan.moments,"deepened":deepened.count,"seconds":(seconds*10).rounded()/10,"worstCaseSeconds":Double(worst)/1000,"searches":count,"overheadMsPerSearch":count==0 ? 0:Int((seconds*1000-Double(budgetMs))/Double(count)),"quickDepthMean":mean(quick),"quickDepthMin":quick.min() ?? 0,"deepDepths":deep])
            XCTAssertLessThanOrEqual(seconds,90,"\(name) stays within the acceptance limit");XCTAssertLessThanOrEqual(seconds*1000,Double(worst),"\(name) stays below its worst case")
        }
        try JSONSerialization.data(withJSONObject:["processors":ProcessInfo.processInfo.activeProcessorCount,"threads":EngineResources.review().threads,"hashMB":EngineResources.review().hashMB,"runs":runs],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
    }
}
