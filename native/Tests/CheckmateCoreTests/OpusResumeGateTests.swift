import XCTest
@testable import CheckmateCore

/// M9 resume gate: a practice reply suspended by a failed review entry resumes only on an explicit Return to game
/// (plan rule 4), whatever other reply entry point fires meanwhile.
@MainActor private final class PendingEngine:EngineService {
    var continuations:[CheckedContinuation<EngineAnalysis,Error>]=[]
    var skills:[Int]=[]
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {skills.append(skill);return try await withCheckedThrowingContinuation{continuations.append($0)}}
    func finish(at index:Int,_ move:String){continuations[index].resume(returning:EngineAnalysis(bestMove:move))}
}
@MainActor final class OpusResumeGateTests:XCTestCase {
    private func settle()async{for _ in 0..<30{await Task.yield()}}
    /// Practice after 1.e4 with the opponent's reply in flight, then a saved review whose restore fails.
    private func failedEntry()async throws -> (GameSession,PendingEngine,ReviewController) {
        let engine=PendingEngine(),session=try GameSession(engine:engine),review=ReviewController();session.reviewController=review
        try session.playWhite(from:"e2",to:"e4");await settle();XCTAssertEqual(engine.skills,[0]);XCTAssertEqual(session.busyReason,"opponent")
        let document=try PGNImporter.parse(Data("[Event \"Saved\"]\n1. d4 d5 *".utf8))[0]
        review.open(document,practice:session);XCTAssertFalse(session.busy)
        XCTAssertThrowsError(try review.restoreSaved(cursor:document.nodes.count+7,branches:[]))
        XCTAssertTrue(review.abandonFailedEntry(practice:session),"A Black-to-move practice reply was waiting")
        XCTAssertTrue(session.explicitResumeRequired);XCTAssertFalse(review.active);XCTAssertFalse(session.reviewSuspended)
        XCTAssertEqual(session.mode,.practice);XCTAssertNil(session.lesson);XCTAssertFalse(session.busy)
        return (session,engine,review)
    }
    func testHeldReplyIgnoresCallbacksAndResumesOnlyOnExplicitReturnWithNewProfile()async throws {
        let (session,engine,_)=try await failedEntry()
        session.holdVoice(true);session.holdVoice(false);await settle()
        _ = try session.openVoice();session.closeVoice();await settle()
        session.setConnection(enabled:true,role:"coach");session.setConnection(enabled:false,role:"coach");await settle()
        var settings=session.state.settings;settings.opponentPreset="club";session.updateSettings(settings);await settle()
        session.selectPresentation(false);session.closePresentation();session.retryEngine();session.continueWithStockfish();await settle()
        XCTAssertThrowsError(try session.commitBlack("e7e5"),"A companion commit bypassed the held reply")
        XCTAssertEqual(engine.skills,[0],"A callback restarted the computer without an explicit Return to game")
        XCTAssertFalse(session.busy);XCTAssertTrue(session.explicitResumeRequired);XCTAssertEqual(session.rules.history,["e4"])
        engine.finish(at:0,"e7e5");await settle();XCTAssertEqual(session.rules.history,["e4"],"The suspended stale reply committed")
        session.resumePractice();await settle()
        XCTAssertFalse(session.explicitResumeRequired);XCTAssertEqual(engine.skills,[0,10],"Explicit resume uses the new effective (Club) profile")
        engine.finish(at:1,"c7c5");await settle();XCTAssertEqual(session.rules.history,["e4","c5"])
    }
    func testLaterReviewReturnIsAnExplicitResume()async throws {
        let (session,engine,review)=try await failedEntry()
        review.open(try PGNImporter.parse(Data("1. c4 *".utf8))[0],practice:session);await settle();XCTAssertEqual(engine.skills,[0])
        review.close(practice:session);await settle()
        XCTAssertFalse(session.explicitResumeRequired);XCTAssertEqual(engine.skills,[0,0],"Return to game from a later review resumes the reply")
    }
    func testNormalReviewReturnAndCompanionPauseAreUnchanged()async throws {
        let engine=PendingEngine(),session=try GameSession(engine:engine),review=ReviewController();session.reviewController=review
        try session.playWhite(from:"e2",to:"e4");await settle()
        review.open(try PGNImporter.parse(Data("1. c4 *".utf8))[0],practice:session);review.close(practice:session);await settle()
        XCTAssertEqual(engine.skills,[0,0]);XCTAssertFalse(session.explicitResumeRequired)
        review.open(try PGNImporter.parse(Data("1. c4 *".utf8))[0],practice:session);review.close(practice:session,resumePractice:false);await settle()
        XCTAssertFalse(session.explicitResumeRequired,"Leaving review for another activity is not a failed-entry hold");XCTAssertEqual(engine.skills,[0,0])
        session.setConnection(enabled:true,role:"opponent",lease:"lease");session.setConnection(enabled:false,role:"opponent");await settle()
        XCTAssertTrue(session.pausedOpponent);XCTAssertFalse(session.explicitResumeRequired);XCTAssertEqual(engine.skills,[0,0])
        session.continueWithStockfish();await settle();XCTAssertEqual(engine.skills,[0,0,0],"Companion pause still resumes with Continue with Stockfish")
    }
    func testHumanToMoveFailureHoldsNothing()async throws {
        let engine=PendingEngine(),session=try GameSession(engine:engine),review=ReviewController();session.reviewController=review
        let document=try PGNImporter.parse(Data("1. d4 *".utf8))[0];review.open(document,practice:session)
        XCTAssertFalse(review.abandonFailedEntry(practice:session));XCTAssertFalse(session.explicitResumeRequired)
    }
    func testDeliberateReplacementsClearTheObsoleteHold()async throws {
        // New game: the held game is replaced; the human is to move, nothing is held or started.
        do{let (session,engine,_)=try await failedEntry();session.newGame();await settle()
            XCTAssertFalse(session.explicitResumeRequired);XCTAssertTrue(session.rules.history.isEmpty);XCTAssertEqual(engine.skills,[0])}
        // Restore previous game: the restored Black-to-move game starts normally.
        do{let (session,engine,review)=try await failedEntry();session.newGame();try session.playWhite(from:"d2",to:"d4");await settle();XCTAssertEqual(engine.skills,[0,0])
            review.open(try PGNImporter.parse(Data("1. d4 *".utf8))[0],practice:session);XCTAssertThrowsError(try review.restoreSaved(cursor:99,branches:[]))
            XCTAssertTrue(review.abandonFailedEntry(practice:session));XCTAssertTrue(session.explicitResumeRequired)
            try session.restorePrevious();await settle()
            XCTAssertFalse(session.explicitResumeRequired);XCTAssertEqual(session.rules.history,["e4"]);XCTAssertEqual(engine.skills,[0,0,0])}
        // Practice fork as Black from 1.e4 e5 2.Nf3: the fork's own opponent (White) starts at once.
        do{let (session,engine,_)=try await failedEntry();let fork=try ChessRules();try fork.restore("1. e4 e5 2. Nf3 Nc6")
            try session.installPracticeFork(fork,side:"b");await settle()
            XCTAssertFalse(session.explicitResumeRequired);XCTAssertEqual(session.rules.turn,"w");XCTAssertEqual(engine.skills,[0,0])}
        // Undo changes the held position back to the human's move.
        do{let (session,engine,_)=try await failedEntry();session.undo();await settle()
            XCTAssertFalse(session.explicitResumeRequired);XCTAssertTrue(session.rules.history.isEmpty);XCTAssertEqual(engine.skills,[0])}
        // Imported state replaces the game and its owner.
        do{let (session,engine,_)=try await failedEntry();var imported=ApplicationState();let g=try ChessRules();_ = try g.move("d2","d4");imported.practice.pgn=g.pgn
            try session.installImportedState(imported);await settle()
            XCTAssertFalse(session.explicitResumeRequired);XCTAssertEqual(session.rules.history,["d4"]);XCTAssertEqual(engine.skills,[0,0])}
    }
}
