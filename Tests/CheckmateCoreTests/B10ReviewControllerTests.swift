import XCTest
import Combine
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// B10 review findings RV-9, RV-10, RV-11, RV-13 and RV2-2c: whole-game analysis that neither restarts nor reports an
/// empty result, cleanup of a deleted review's analysis, a fork target that names the exact position, route-aware
/// progress, and a fork check that equals a full replay without performing one.
@MainActor final class B10ReviewControllerTests:XCTestCase {
    private func opened(_ text:String)throws -> (ReviewController,GameSession,GameDocument) {
        let document=try PGNImporter.parse(Data(text.utf8))[0],review=ReviewController(),session=try GameSession(engine:nil)
        review.open(document,practice:session);return (review,session,document)
    }
    /// The answer the fast check must equal: replay the whole history in chess.js and ask whether the game is over.
    private func replayed(_ review:ReviewController)->Bool {(try? review.practiceForkRules()).map{!$0.over} ?? false}
    private var missingEngine:NativeEngine {NativeEngine(executable:URL(fileURLWithPath:"/missing-engine"))}
    func testProgressFollowsTheRouteThroughAVariation()throws {
        let (review,_,document)=try opened("1. e4 e5 (1... c5 2. Nf3 d6) 2. Nf3 *");XCTAssertEqual(review.progress,0)
        try review.select(try XCTUnwrap(document.nodes.first{$0.san=="c5"}).id);XCTAssertEqual(review.progress,0.5,accuracy:1e-9,"c5 is move 2 of the 4 on its own route")
        try review.select(try XCTUnwrap(document.nodes.first{$0.san=="e5"}).id);XCTAssertEqual(review.progress,2.0/3,accuracy:1e-9)
        try review.beginBranch();try review.playBranch("d2d4");try review.playBranch("e5d4");review.seekBranch(1);XCTAssertEqual(review.progress,0.5,accuracy:1e-9)
    }
    func testTheForkTargetNamesTheExactPositionShown()throws {
        let (review,session,_)=try opened("1. e4 e5 *");let start=try XCTUnwrap(review.practiceForkTarget)
        review.pause();review.cancel();review.clearAnnotations();XCTAssertEqual(review.practiceForkTarget,start,"Nothing shown changed")
        try review.select(1);let first=review.practiceForkTarget;XCTAssertNotEqual(first,start)
        try review.beginBranch();XCTAssertNotEqual(review.practiceForkTarget,first,"An idea is a different fork, even at its root")
        try review.playBranch("c7c5");let idea=review.practiceForkTarget
        review.seekBranch(0);XCTAssertNotEqual(review.practiceForkTarget,idea);review.seekBranch(1);XCTAssertEqual(review.practiceForkTarget,idea)
        review.close(practice:session);XCTAssertNil(review.practiceForkTarget)
        review.open(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],practice:session);XCTAssertNotEqual(review.practiceForkTarget,start,"Another record of the same text is another fork")
    }
    func testForkAvailabilityEqualsAFullReplayForRepetitionAndTheMoveClock()throws {
        let (review,_,document)=try opened("1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8 5. Nf3 Nf6 6. Ng1 Ng8 7. Nf3 Nf6 8. Ng1 Ng8 *")
        for node in document.nodes.indices{try review.select(node);XCTAssertEqual(review.practiceForkAvailable,replayed(review),"node \(node)")}
        try review.select(16);XCTAssertFalse(review.practiceForkAvailable,"Fifth occurrence of the start");try review.select(12);XCTAssertTrue(review.practiceForkAvailable)
        try review.beginBranch();for move in ["g1f3","g8f6","f3g1","f6g8"]{try review.playBranch(move)}
        for ply in 0...4{review.seekBranch(ply);XCTAssertEqual(review.practiceForkAvailable,replayed(review),"idea ply \(ply)")}
        XCTAssertFalse(review.practiceForkAvailable,"The idea brings the start back a fifth time")
        let (clock,_,_)=try opened("8/8/8/4k3/8/8/8/4K2R w - - 149 80");XCTAssertTrue(clock.practiceForkAvailable);XCTAssertEqual(clock.practiceForkAvailable,replayed(clock))
        try clock.beginBranch();try clock.playBranch("h1h2");XCTAssertFalse(clock.practiceForkAvailable,"The 75-move rule ends the game");XCTAssertEqual(clock.practiceForkAvailable,replayed(clock))
    }
    func testWholeGameAnalysisNeitherRestartsNorReportsAnEmptyReady()throws {
        let analyzer=ReviewAnalyzer(engine:missingEngine),position=try PGNImporter.parse(Data("8/8/8/4k3/8/8/8/4K3 w - - 0 1".utf8))[0]
        analyzer.startBatch(position);XCTAssertEqual(analyzer.batchStatus,"idle");XCTAssertNil(analyzer.batchDocument,"A position without moves is never reported ready")
        let game=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0];var statuses:[String]=[];let watch=analyzer.$batchStatus.sink{statuses.append($0)}
        analyzer.startBatch(game);XCTAssertTrue(analyzer.batchRunning(game.id));let started=statuses
        analyzer.startBatch(game);XCTAssertEqual(statuses,started,"A second start while it runs keeps the batch and its progress")
        analyzer.cancelBatch();XCTAssertFalse(analyzer.batchRunning(game.id))
        analyzer.startBatch(game);XCTAssertEqual(statuses.last,"pending","Once stopped, it can start again");analyzer.cancelBatch();withExtendedLifetime(watch){}
    }
    func testForgettingADeletedReviewRemovesOnlyItsAnalysis()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        func evidence(_ id:UUID)->ReviewEvidence {ReviewEvidence(schemaVersion:1,documentID:id,documentHash:"document",nodeID:1,historyHash:"history",revision:1,engineVersion:"test",options:[:],budgetMs:500,createdAt:Date(),root:EngineAnalysis(),played:nil,quality:"provisional",provisional:true)}
        let deleted=UUID(),kept=UUID(),cache=ReviewAnalysisCache(directory:root)
        try cache.save(evidence(deleted),key:"deleted");try cache.save(evidence(kept),key:"kept")
        try await ReviewAnalyzer(engine:missingEngine,cacheDirectory:root).forgetAnalysis(documentID:deleted)
        XCTAssertNil(cache.load("deleted"));XCTAssertEqual(cache.load("kept")?.documentID,kept)
    }
}
