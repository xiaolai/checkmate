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


/// A companion opponent must play at the strength the learner configured, exactly as Stockfish's own reply does.
@MainActor final class CompanionOpponentStrengthTests:XCTestCase {
    final class SkillRecordingEngine:TestEngineService {
        var skills:[Int]=[]
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {skills.append(skill);return EngineAnalysis(bestMove:try ChessRules(fen:fen).moves().first?.uci)}
    }
    func testCompanionOpponentUsesTheConfiguredProfileNotTheRawSkill()async throws {
        let engine=SkillRecordingEngine(),s=try GameSession(engine:engine),tools=try CompanionTools(session:s)
        var settings=s.state.settings;settings.skill=20;settings.opponentPreset="gentle";settings.coachingMode="on_request";s.updateSettings(settings)
        s.setConnection(enabled:true,role:"opponent",lease:"fixture");try s.playWhite(from:"e2",to:"e4")
        engine.skills=[]
        _ = try await tools.call("play_move",args:["sessionId":s.sessionId,"revision":s.revision,"requestId":"one"],lease:"fixture")
        XCTAssertEqual(engine.skills,[0],"The gentle preset plays at skill 0, not the raw skill setting");XCTAssertEqual(s.rules.history.count,2)
    }
}
