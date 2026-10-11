import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// Audit round findings for the companion and voice coach: a BUSY refusal is retryable with the same requestId (#10),
/// and a microphone start queued before disconnect never opens capture afterwards (#11).
@MainActor final class VoiceCompanionRetryTests:XCTestCase {
    /// An engine whose first search waits until the test releases it.
    @MainActor final class HeldEngine:TestEngineService {
        var hold=false,waiting:CheckedContinuation<Void,Never>?
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {if hold{hold=false;await withCheckedContinuation{waiting=$0}};return EngineAnalysis(bestMove:try ChessRules(fen:fen).moves().first?.uci)}
        func release(){waiting?.resume();waiting=nil}
    }
    private func code(_ error:Error)->String? {(CompanionBroker.failure(error)["error"] as? [String:Any])?["code"] as? String}

    // #10
    func testAMoveRefusedAsBusyRunsWhenRetriedWithTheSameRequestID()async throws {
        let engine=HeldEngine(),s=try GameSession(engine:engine),tools=try CompanionTools(session:s)
        var settings=s.state.settings;settings.coachingMode="on_request";s.updateSettings(settings)
        s.setConnection(enabled:true,role:"opponent",lease:"fixture");try s.playWhite(from:"e2",to:"e4")
        let observed:[String:Any]=["sessionId":s.sessionId,"revision":s.revision],move=observed.merging(["requestId":"retry-after-busy"]){$1}
        engine.hold=true
        let analysis=Task{try await tools.call("analyze_position",args:observed,lease:"fixture")}
        var spins=0;while engine.waiting==nil,spins<10_000{spins+=1;await Task.yield()}
        XCTAssertNotNil(engine.waiting,"The analysis must hold the engine when the move is asked for")
        do{_ = try await tools.call("play_move",args:move,lease:"fixture");XCTFail("A move during analysis is refused")}catch{XCTAssertEqual(code(error),"BUSY")}
        XCTAssertEqual(s.rules.history.count,1,"A refused move is never played")
        engine.release();_ = try await analysis.value
        let retry=try await tools.call("play_move",args:move,lease:"fixture") as? [String:Any]
        XCTAssertNotNil(retry?["uci"],"The retry runs once the engine is free instead of replaying BUSY");XCTAssertEqual(s.rules.history.count,2)
        let replay=try await tools.call("play_move",args:move,lease:"fixture") as? [String:Any]
        XCTAssertEqual(replay?["uci"] as? String,retry?["uci"] as? String);XCTAssertEqual(s.rules.history.count,2,"A completed move is still replayed, never played twice")
    }

    // #11
    func testARouteChangeRestartQueuedBeforeDisconnectNeverOpensTheMicrophone()async throws {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet";s.state.settings.voiceMicrophone=true
        let v=try VoiceCoach(session:s);v.settingsChanged();v.automationOutbound={_ in};_ = try s.openVoice();v.receive(["type":"session.updated"])
        var starts=0;v.automationCaptureStart={_ in starts+=1}
        v.audio.onInputChanged?();v.disconnect();for _ in 0..<50{await Task.yield()}
        XCTAssertEqual(starts,0,"A restart cancelled by disconnect never reopens capture")
    }
    func testAMicrophoneTestQueuedBeforeDisconnectNeverOpensTheMicrophone()async throws {
        let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);var starts=0;v.automationCaptureStart={_ in starts+=1}
        v.testMicrophone();v.disconnect();for _ in 0..<50{await Task.yield()}
        XCTAssertEqual(starts,0,"A test cancelled by disconnect never opens capture")
    }
}
