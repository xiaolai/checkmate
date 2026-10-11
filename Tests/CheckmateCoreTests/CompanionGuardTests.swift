import XCTest
import Foundation
@testable import CheckmateCore

/// Audit fix: a companion opponent's move shares the one-request engine gate, `opponent_turn` never wakes on a finished
/// game, and registering an already-current skill records its hash so a later update still recognises Checkmate's copy.
@MainActor final class CompanionGuardTests:XCTestCase {
    @MainActor final class GatedEngine:EngineService {
        var calls=0,active=0,peak=0,waiting:[CheckedContinuation<Void,Never>]=[]
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
            calls+=1;active+=1;peak=max(peak,active);defer{active-=1};await withCheckedContinuation{waiting.append($0)}
            let move=try ChessRules(fen:fen).moves().first!;return EngineAnalysis(bestMove:move.uci,lines:[AnalysisLine(depth:1,multiPv:1,score:AnalysisScore(kind:"cp",value:0),pv:[move.uci],san:[])])
        }
        func releaseAll(){let all=waiting;waiting=[];all.forEach{$0.resume()}}
    }
    private func code(_ error:Error)->String? {(CompanionBroker.failure(error)["error"] as? [String:Any])?["code"] as? String}
    private func until(_ condition:()->Bool)async {for _ in 0..<2000 where !condition(){await Task.yield()}}
    func testACompanionOpponentMoveHoldsTheEngineGate()async throws {
        let engine=GatedEngine(),s=try GameSession(engine:engine),tools=try CompanionTools(session:s)
        var settings=s.state.settings;settings.coachingMode="on_request";s.updateSettings(settings);s.setConnection(enabled:true,role:"opponent",lease:"fixture");try s.playWhite(from:"e2",to:"e4")
        func args(_ id:String)->[String:Any] {["sessionId":s.sessionId,"revision":s.revision,"requestId":id]}
        let first=Task{try await tools.call("play_move",args:args("one"),lease:"fixture")}
        await until{engine.waiting.count==1};XCTAssertEqual(engine.waiting.count,1)
        for (name,a) in [("play_move",args("two")),("analyze_position",["sessionId":s.sessionId,"revision":s.revision] as [String:Any])] {
            var outcome:String?;let reached=engine.calls
            let call=Task{do{_ = try await tools.call(name,args:a,lease:"fixture");outcome="returned"}catch{outcome=self.code(error) ?? "\(error)"}}
            await until{outcome != nil || engine.calls>reached}
            if engine.calls>reached{XCTFail("\(name) reached the engine while the opponent's move was being chosen");engine.releaseAll()}
            await call.value;XCTAssertEqual(outcome,"BUSY",name)
        }
        engine.releaseAll();_ = try await first.value
        XCTAssertEqual(s.rules.history.count,2,"The opponent's move completes");XCTAssertEqual(engine.calls,1,"Refused requests never reach the engine");XCTAssertEqual(engine.peak,1)
    }
    func testOpponentTurnDoesNotWakeAfterTheLearnerResigns()async throws {
        let s=try GameSession(engine:nil),tools=try CompanionTools(session:s);s.state.settings.coachingMode="on_request";s.setConnection(enabled:true,role:"opponent",lease:"fixture")
        try s.playWhite(from:"e2",to:"e4");let cursor=s.cursor;s.resign();XCTAssertTrue(s.finished);XCTAssertEqual(s.rules.turn,s.opponentSide)
        let result=try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":cursor,"event":"opponent_turn","timeoutMs":150],lease:"fixture") as! [String:Any]
        XCTAssertEqual(result["changed"] as? Bool,false,"A resigned game is over, so it is never the opponent's turn")
        let legal=try await tools.call("get_legal_moves",args:["sessionId":s.sessionId,"revision":s.revision],lease:"fixture") as! [String:Any]
        XCTAssertEqual(legal["gameOver"] as? Bool,true,"Legal moves agree with the session that a resigned game is over")
    }
    private let tool=URL(fileURLWithPath:"/usr/bin/true"),release="ai.xiaolai.checkmate"
    func testRegisteringACurrentSkillWithoutAMarkerStillAllowsTheNextUpdate()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:root)}
        let old=Data("---\nname: checkmate-companion\n---\nold\n".utf8),new=Data("---\nname: checkmate-companion\n---\nnew\n".utf8)
        try CompanionInstallation.register(executable:tool,codex:tool,skill:old,bundleIdentifier:release,home:root)
        let marker=CompanionInstallation.markerFile(home:root,bundleIdentifier:release);try FileManager.default.removeItem(at:marker)
        XCTAssertEqual(try CompanionInstallation.register(executable:tool,codex:tool,skill:old,bundleIdentifier:release,home:root),.current)
        XCTAssertEqual(CompanionInstallation.skillState(bundled:new,bundleIdentifier:release,home:root),.outdated,"Checkmate's unchanged copy is not mistaken for the learner's edits")
        XCTAssertEqual(try CompanionInstallation.register(executable:tool,codex:tool,skill:new,bundleIdentifier:release,home:root),.current)
    }
}
