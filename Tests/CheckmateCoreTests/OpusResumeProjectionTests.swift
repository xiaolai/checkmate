import XCTest
@testable import CheckmateCore

/// M9 resume-gate projection: the failed-entry hold blocks `reply()`/`commitBlack()`, so `get_session` must
/// report it as `controller.paused=true` with a readable `pauseReason` (priority over other reasons) until an
/// explicit Return to game or a deliberate replacement. Existing reasons and controller fields are unchanged.
@MainActor private final class HeldEngine:EngineService {
    var continuations:[CheckedContinuation<EngineAnalysis,Error>]=[]
    var skills:[Int]=[]
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {skills.append(skill);return try await withCheckedThrowingContinuation{continuations.append($0)}}
    func finish(at index:Int,_ move:String){continuations[index].resume(returning:EngineAnalysis(bestMove:move))}
}
@MainActor final class OpusResumeProjectionTests:XCTestCase {
    private static let controllerKeys:Set<String>=["enabled","role","connected","paused","pauseReason","suspended","side"]
    private func settle()async{for _ in 0..<30{await Task.yield()}}
    private func controller(_ state:[String:Any],file:StaticString=#filePath,line:UInt=#line)->[String:Any] {
        let value=state["controller"] as? [String:Any] ?? [:]
        XCTAssertEqual(Set(value.keys),Self.controllerKeys,"Controller schema fields changed",file:file,line:line);return value
    }
    private func assertPaused(_ state:[String:Any],_ reason:String?,_ note:String,file:StaticString=#filePath,line:UInt=#line) {
        let c=controller(state,file:file,line:line)
        XCTAssertEqual(c["paused"] as? Bool,reason != nil,"paused: \(note)",file:file,line:line)
        if let reason=reason{XCTAssertEqual(c["pauseReason"] as? String,reason,"pauseReason: \(note)",file:file,line:line)}
        else{XCTAssertTrue(c["pauseReason"] is NSNull,"pauseReason must be null: \(note) got \(String(describing:c["pauseReason"]))",file:file,line:line)}
    }
    /// Practice after 1.e4 with the opponent's reply in flight, then a saved review whose restore really fails.
    private func failedEntry()async throws -> (GameSession,HeldEngine,ReviewController) {
        let engine=HeldEngine(),session=try GameSession(engine:engine),review=ReviewController();session.reviewController=review
        try session.playWhite(from:"e2",to:"e4");await settle();XCTAssertEqual(session.busyReason,"opponent")
        assertPaused(session.publicState(),nil,"before the failed entry the reply is merely running")
        let document=try PGNImporter.parse(Data("[Event \"Saved\"]\n1. d4 d5 *".utf8))[0]
        review.open(document,practice:session)
        XCTAssertThrowsError(try review.restoreSaved(cursor:document.nodes.count+7,branches:[]))
        XCTAssertTrue(review.abandonFailedEntry(practice:session));XCTAssertTrue(session.explicitResumeRequired)
        return (session,engine,review)
    }

    func testFailedEntryGetSessionReportsPauseThroughCallbacksUntilExplicitResume()async throws {
        let (session,engine,_)=try await failedEntry()
        let state=session.publicState();assertPaused(state,"review_restore_failed","immediately after the failed entry")
        XCTAssertEqual(state["mode"] as? String,"practice");XCTAssertEqual((state["state"] as? [String:Any])?["busy"] as? Bool,false)
        // Through the real MCP tool path (voice lease is accepted by CompanionTools.access).
        let tools=try CompanionTools(session:session),lease=try session.openVoice()
        assertPaused(try await tools.call("get_session",args:[:],lease:lease) as! [String:Any],"review_restore_failed","get_session via voice lease")
        // The hold has priority over a simultaneous coach_speaking reason, and survives the release.
        session.holdVoice(true);assertPaused(session.publicState(),"review_restore_failed","voice hold during the gate")
        assertPaused(try await tools.call("get_session",args:[:],lease:lease) as! [String:Any],"review_restore_failed","get_session while voice is holding")
        session.holdVoice(false);session.closeVoice();await settle();assertPaused(session.publicState(),"review_restore_failed","after voice release/close")
        // Companion coach connection via a real lease, then a companion-opponent disconnect: the gate stays the reason.
        session.setConnection(enabled:true,role:"coach",lease:"coach-lease");await settle()
        assertPaused(try await tools.call("get_session",args:[:],lease:"coach-lease") as! [String:Any],"review_restore_failed","get_session via companion lease")
        session.setConnection(enabled:false,role:"coach");await settle()
        session.setConnection(enabled:true,role:"opponent",lease:"opponent-lease");session.setConnection(enabled:false,role:"opponent");await settle()
        XCTAssertTrue(session.pausedOpponent);assertPaused(session.publicState(),"review_restore_failed","companion disconnect during the gate")
        session.continueWithStockfish();await settle();assertPaused(session.publicState(),"review_restore_failed","Continue with Stockfish is not the explicit return")
        var settings=session.state.settings;settings.opponentPreset="club";session.updateSettings(settings);await settle()
        session.selectPresentation(false);session.closePresentation();session.retryEngine();await settle()
        assertPaused(session.publicState(),"review_restore_failed","after settings/presentation/retry callbacks")
        XCTAssertEqual(engine.skills,[0],"No callback restarted the computer");XCTAssertEqual(session.rules.history,["e4"])
        // Explicit Return to game: unpaused, the reply runs.
        session.resumePractice();await settle()
        XCTAssertFalse(session.explicitResumeRequired);assertPaused(session.publicState(),nil,"after explicit resume")
        XCTAssertEqual((session.publicState()["state"] as? [String:Any])?["busyReason"] as? String,"opponent");XCTAssertEqual(engine.skills,[0,10])
        engine.finish(at:1,"c7c5");await settle();XCTAssertEqual(session.rules.history,["e4","c5"]);assertPaused(session.publicState(),nil,"after the resumed reply")
    }

    func testLaterReviewReturnAndReplacementsUnpauseTheProjection()async throws {
        do{let (session,engine,review)=try await failedEntry()
            review.open(try PGNImporter.parse(Data("1. c4 *".utf8))[0],practice:session)
            // The review-mode projection has its own (pre-existing, unchanged) controller shape with paused=true.
            XCTAssertEqual((session.publicState()["controller"] as? [String:Any])?["paused"] as? Bool,true,"Review projection keeps its own paused=true")
            review.close(practice:session);await settle()
            assertPaused(session.publicState(),nil,"Return to game from a later review");XCTAssertEqual(engine.skills,[0,0])}
        do{let (session,_,_)=try await failedEntry();session.newGame();await settle();assertPaused(session.publicState(),nil,"new game replaced the held game")}
        do{let (session,_,_)=try await failedEntry();session.undo();await settle();assertPaused(session.publicState(),nil,"undo replaced the held position")}
    }

    func testExistingPauseReasonsAreUnchangedWithoutTheGate()async throws {
        let engine=HeldEngine(),session=try GameSession(engine:engine)
        assertPaused(session.publicState(),nil,"ordinary practice")
        session.holdVoice(true);assertPaused(session.publicState(),"coach_speaking","voice hold");session.holdVoice(false)
        try session.demonstrate(title:"Line",introduction:"Imagine",lines:[DemoLineInput(label:"Main",moves:[DemoStepInput(uci:"e2e4")])])
        assertPaused(session.publicState(),"temporary_view","demonstration");session.closePresentation();assertPaused(session.publicState(),nil,"demonstration closed")
        session.setConnection(enabled:true,role:"opponent",lease:"lease");try session.playWhite(from:"e2",to:"e4");session.setConnection(enabled:false,role:"opponent");await settle()
        XCTAssertFalse(session.explicitResumeRequired);assertPaused(session.publicState(),"companion_disconnected","companion opponent disconnected")
        session.continueWithStockfish();await settle();assertPaused(session.publicState(),nil,"Continue with Stockfish");XCTAssertEqual(engine.skills,[0])
        // A human-to-move failed entry holds nothing and reports nothing.
        let other=try GameSession(engine:HeldEngine()),review=ReviewController();other.reviewController=review
        review.open(try PGNImporter.parse(Data("1. d4 *".utf8))[0],practice:other);XCTAssertFalse(review.abandonFailedEntry(practice:other))
        assertPaused(other.publicState(),nil,"human-to-move failure")
    }
}
