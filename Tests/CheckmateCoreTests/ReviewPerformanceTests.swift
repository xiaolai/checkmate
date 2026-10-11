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
        guard let path=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_PERFORMANCE"] else{throw XCTSkip("Explicit isolated build-host performance measurement gate.")}
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
        guard let path=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_PERFORMANCE"] else{throw XCTSkip("Explicit build-host scale observation.")}
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
        guard let path=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_PERFORMANCE"] else{throw XCTSkip("Explicit build-host selected quick p95 gate.")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/GameReview")
        let document=try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent("games/public-07.pgn")))[0],engine=NativeEngine(),analyzer=ReviewAnalyzer(engine:engine)
        var samples:[Double]=[],rows:[[String:Any]]=[]
        for offset in [5,10,20,30,40,50,60,70,80,90] {let node=document.mainline[offset-1],start=Date();let evidence=try await analyzer.analyze(document:document,node:node,revision:offset);let milliseconds=Date().timeIntervalSince(start)*1000;samples.append(milliseconds);rows.append(["node":node,"milliseconds":milliseconds,"budgetMs":evidence.budgetMs,"historyHash":evidence.historyHash])}
        samples.sort();let p95=samples[Int(Double(samples.count)*0.95)]
        try JSONSerialization.data(withJSONObject:["p95Ms":p95,"samples":rows,"documentHash":document.contentHash,"engineHash":engine.binaryIdentity,"workload":"Ten distinct positions from actual public game; cold analyzer and engine first sample, no disk cache; concurrent separate calibration"],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path+".selected-p95.json"))
        XCTAssertLessThanOrEqual(p95,2000)
    }

}
