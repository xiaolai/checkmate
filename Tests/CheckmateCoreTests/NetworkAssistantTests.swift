import XCTest
import CheckmateTestSupport
@testable import CheckmateApplication
@testable import CheckmateDomain
@testable import CheckmateSupport
import CheckmateRules

/// Assistance plan A5, A6, A7 and A8 over the in-memory LAN: the network assistant gives hints only to a player whose
/// agreed level allows them, on their own move, at the profile both Macs share; a result for another turn, after the
/// game ended or after leaving is dropped; a hint shown flags that turn's move; `guided` starts a hint by itself each
/// turn; and practice, Review and MCP stay closed whatever the level.
@MainActor final class NetworkAssistantTests:XCTestCase {
    typealias CountingEngine=NetworkFairnessTests.CountingEngine
    /// One Mac's fairness and assistant, over that Mac's own participation and a counting engine.
    private struct Help {let fairness:FairnessPolicy,engine:CountingEngine,assistant:NetworkAssistant}
    private func help(_ mac:Mac)->Help {
        let fairness=FairnessPolicy(participation:mac.participation),engine=CountingEngine();engine.participation=mac.participation
        return Help(fairness:fairness,engine:engine,assistant:NetworkAssistant(game:mac.game,fairness:fairness,engine:engine))
    }
    private func settle(_ done:@escaping ()->Bool,_ message:String,file:StaticString=#filePath,line:UInt=#line)async throws {
        for _ in 0..<400 where !done(){try await Task.sleep(for:.milliseconds(5))};XCTAssertTrue(done(),message,file:file,line:line)
    }
    private func code(_ error:Error)->String? {(ProtocolErrors.failure(error)["error"] as? [String:Any])?["code"] as? String}
    /// Ana hosts as White under `terms`, Ben joins as Black accepting them, and Cy watches.
    private func game(_ terms:NetworkAssistance,_ lan:MemoryLAN)throws -> (ana:Mac,ben:Mac,cy:Mac) {
        let ana=try NetworkControllerTests().hosting(lan){$0.assistance=terms}
        let ben=try NetworkControllerTests().joining(lan,"Ben",ana,accepting:terms),cy=try NetworkControllerTests().joining(lan,"Cy",ana,watching:true)
        return (ana,ben,cy)
    }

    /// A1 and A8: each player's level is their own side's, from the verified terms; a spectator's is always `off`.
    func testEachPlayerGetsTheirOwnSidesLevel()throws {
        let lan=MemoryLAN(),(ana,ben,cy)=try game(NetworkAssistance(white:.hints,black:.insight),lan)
        XCTAssertEqual(ana.participation.assistance,.hints);XCTAssertEqual(ben.participation.assistance,.insight);XCTAssertEqual(cy.participation.assistance,.off)
        let (anaHelp,benHelp,cyHelp)=(help(ana),help(ben),help(cy))
        XCTAssertEqual(anaHelp.fairness.networkAssistance,.hints);XCTAssertNoThrow(try anaHelp.fairness.requireNetworkHint())
        XCTAssertEqual(benHelp.fairness.networkAssistance,.insight);XCTAssertThrowsError(try benHelp.fairness.requireNetworkHint())
        XCTAssertEqual(cyHelp.fairness.networkAssistance,.off);XCTAssertThrowsError(try cyHelp.fairness.requireNetworkHint())
        for help in [anaHelp,benHelp,cyHelp]{XCTAssertFalse(help.fairness.engineHelpAllowed,"the D8 ban itself is never lifted")}
        XCTAssertEqual(ana.game.assistance,NetworkAssistance(white:.hints,black:.insight));XCTAssertEqual(cy.game.assistance,ana.game.assistance)
        // Leaving takes the level away with participation.
        ana.game.leave();lan.scheduler.run();XCTAssertEqual(ana.participation.assistance,.off);XCTAssertEqual(anaHelp.fairness.networkAssistance,.off)
    }

    /// A5 and A7: a hint asked for on the learner's move searches the shared profile, is shown, and flags that move on
    /// every Mac; the next move, without a hint, is not flagged.
    func testAHintIsShownAtTheSharedProfileAndFlagsTheMove()async throws {
        let lan=MemoryLAN(),(ana,ben,cy)=try game(NetworkAssistance(both:.hints),lan),anaHelp=help(ana),benHelp=help(ben)
        XCTAssertTrue(anaHelp.assistant.canAsk);XCTAssertFalse(benHelp.assistant.canAsk,"not Ben's move")
        anaHelp.assistant.ask();XCTAssertTrue(anaHelp.assistant.thinking)
        try await settle({anaHelp.assistant.hint != nil},"the hint is shown")
        XCTAssertEqual(anaHelp.engine.limits,[.nodes(NetworkAssistance.hintNodes)]);XCTAssertEqual(anaHelp.engine.profiles,[.skill(20)]);XCTAssertEqual(anaHelp.engine.multiPvs,[1])
        XCTAssertEqual(anaHelp.engine.calls,1,"one search, nothing else");XCTAssertFalse(anaHelp.assistant.canAsk,"one hint a turn")
        let hint=try XCTUnwrap(anaHelp.assistant.hint);XCTAssertFalse(hint.automatic);XCTAssertTrue(ana.game.assistedThisTurn)
        XCTAssertTrue(ana.game.rules.moves().contains{$0.uci==hint.uci});XCTAssertEqual(hint.from+hint.to,hint.uci)
        NetworkControllerTests().play(ana,hint.from,hint.to,lan)
        XCTAssertNil(anaHelp.assistant.hint,"the hint goes with the turn");XCTAssertFalse(ana.game.assistedThisTurn)
        for mac in [ana,ben,cy]{XCTAssertEqual(mac.game.record?.assistedPlies,[1],"\(mac.game.playerName) sees the hinted move")}
        NetworkControllerTests().play(ben,"e7","e5",lan)
        for mac in [ana,ben,cy]{XCTAssertEqual(mac.game.record?.assistedPlies,[1],"Ben's own move had no hint")}
        XCTAssertEqual(benHelp.engine.calls,0)
    }

    /// A6: no hint on the opponent's move, nor for a player whose level stops below hints, nor for a spectator.
    func testNoHintOffTheLearnersMoveOrBelowTheLevel()async throws {
        let lan=MemoryLAN(),(ana,ben,cy)=try game(NetworkAssistance(white:.insight,black:.hints),lan)
        let anaHelp=help(ana),benHelp=help(ben),cyHelp=help(cy)
        benHelp.assistant.ask();anaHelp.assistant.ask();cyHelp.assistant.ask();try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(benHelp.engine.calls+anaHelp.engine.calls+cyHelp.engine.calls,0,"Ben waits for his move; Ana's level has no hints; Cy watches")
        XCTAssertFalse(anaHelp.assistant.canAsk);XCTAssertFalse(cyHelp.assistant.canAsk)
        NetworkControllerTests().play(ana,"e2","e4",lan)
        XCTAssertTrue(benHelp.assistant.canAsk);benHelp.assistant.ask()
        try await settle({benHelp.assistant.hint != nil},"Ben's hint on his own move")
    }

    /// A6: a hint still searching when the turn ends, the game ends or the learner leaves is dropped: nothing is shown
    /// and no move is flagged.
    func testAHintArrivingAfterTheTurnIsDropped()async throws {
        // The turn ends: Ana moves while her hint searches.
        do {
            let lan=MemoryLAN(),(ana,ben,_)=try game(NetworkAssistance(both:.hints),lan),anaHelp=help(ana)
            anaHelp.engine.holding=true;anaHelp.assistant.ask();try await settle({anaHelp.engine.held==1},"the search is held")
            NetworkControllerTests().play(ana,"d2","d4",lan);XCTAssertFalse(anaHelp.assistant.thinking,"the turn's end cancels it")
            anaHelp.engine.releaseAll();try await Task.sleep(for:.milliseconds(30))
            XCTAssertNil(anaHelp.assistant.hint);XCTAssertNil(anaHelp.assistant.error);XCTAssertEqual(ben.game.record?.assistedPlies,[])
        }
        // The game ends: Ben resigns while Ana's hint searches.
        do {
            let lan=MemoryLAN(),(ana,ben,_)=try game(NetworkAssistance(both:.hints),lan),anaHelp=help(ana)
            anaHelp.engine.holding=true;anaHelp.assistant.ask();try await settle({anaHelp.engine.held==1},"the search is held")
            ben.game.resign();lan.scheduler.run();XCTAssertNotNil(ana.game.outcome)
            anaHelp.engine.releaseAll();try await Task.sleep(for:.milliseconds(30))
            XCTAssertNil(anaHelp.assistant.hint);XCTAssertFalse(anaHelp.assistant.thinking);XCTAssertFalse(ana.game.assistedThisTurn)
        }
        // The learner leaves while the hint searches.
        do {
            let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.hints),lan),anaHelp=help(ana)
            anaHelp.engine.holding=true;anaHelp.assistant.ask();try await settle({anaHelp.engine.held==1},"the search is held")
            ana.game.leave();lan.scheduler.run();XCTAssertNil(ana.participation.role)
            anaHelp.engine.releaseAll();try await Task.sleep(for:.milliseconds(30))
            XCTAssertNil(anaHelp.assistant.hint);XCTAssertFalse(anaHelp.assistant.thinking)
        }
    }

    /// A8 after the await, on its own: participation ending with no game event to follow it (so nothing cancels the
    /// search) still drops the result, because the level is checked again when it arrives.
    func testTheLevelIsCheckedAgainWhenTheResultArrives()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.hints),lan),anaHelp=help(ana)
        anaHelp.engine.holding=true;anaHelp.assistant.ask();try await settle({anaHelp.engine.held==1},"the search is held")
        ana.participation.end();XCTAssertTrue(anaHelp.assistant.thinking,"no event reached the assistant")
        anaHelp.engine.releaseAll();try await settle({!anaHelp.assistant.thinking},"the search settles")
        XCTAssertNil(anaHelp.assistant.hint);XCTAssertNil(anaHelp.assistant.error);XCTAssertFalse(ana.game.assistedThisTurn)
    }

    /// A6: a failed search says so on the same turn, and may be asked again.
    func testAFailedHintCanBeAskedAgain()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.hints),lan)
        let fairness=FairnessPolicy(participation:ana.participation),assistant=NetworkAssistant(game:ana.game,fairness:fairness,engine:NodelessEngine())
        assistant.ask();try await settle({assistant.error != nil},"the failure is shown")
        XCTAssertEqual(assistant.error,NetworkAssistant.unavailable);XCTAssertNil(assistant.hint);XCTAssertTrue(assistant.canAsk);XCTAssertFalse(ana.game.assistedThisTurn)
    }

    /// A6: under `guided`, each player's turn starts its own hint, once, marked automatic; the other side's waits.
    func testGuidedStartsAHintAtTheStartOfEachTurn()async throws {
        let lan=MemoryLAN(),terms=NetworkAssistance(both:.guided)
        let ana=try NetworkControllerTests().hosting(lan){$0.assistance=terms},anaHelp=help(ana)
        let ben=try Mac(lan,name:"Ben"),benHelp=help(ben);ben.game.setShown(true);lan.scheduler.run()
        XCTAssertTrue(ben.game.join(try XCTUnwrap(ben.game.games.first),code:ana.game.playCode!.grouped,accepting:terms));lan.scheduler.run()
        try await settle({anaHelp.assistant.hint != nil},"White's first turn starts a hint by itself")
        XCTAssertEqual(anaHelp.assistant.hint?.automatic,true);XCTAssertEqual(benHelp.engine.calls,0,"not Ben's turn")
        anaHelp.assistant.sync();XCTAssertEqual(anaHelp.engine.calls,1,"once a turn")
        NetworkControllerTests().play(ana,"e2","e4",lan)
        try await settle({benHelp.assistant.hint != nil},"Black's turn starts his")
        XCTAssertNil(anaHelp.assistant.hint);XCTAssertEqual(anaHelp.engine.calls,1)
        NetworkControllerTests().play(ben,"e7","e5",lan)
        for mac in [ana,ben]{XCTAssertEqual(mac.game.record?.assistedPlies,[1,2],"both guided moves were shown a hint")}
    }

    /// A8 at `guided`, the most help there is: practice, Review and MCP stay closed, and the counting engine sees no call
    /// but the network assistant's own.
    func testGuidedOpensNothingButTheNetworkGamesOwnHints()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.guided),lan),anaHelp=help(ana)
        try await settle({anaHelp.assistant.hint != nil},"the network game's own hint works")
        // Practice on the same Mac, under the same fairness.
        let engine=CountingEngine();engine.participation=ana.participation
        let practice=try GameSession(engine:engine,state:ApplicationState(),fairness:anaHelp.fairness)
        practice.hint();practice.reply();try await Task.sleep(for:.milliseconds(30))
        do{_ = try await practice.analyze();XCTFail("practice analysis ran")}catch{XCTAssertEqual(code(error),"NETWORK_GAME")}
        do{_ = try await practice.evaluateCandidate(from:"e2",to:"e4");XCTFail("a practice preview ran")}catch{XCTAssertEqual(code(error),"NETWORK_GAME")}
        // Review evidence is withheld.
        let analyzer=ReviewAnalyzer(engine:engine,fairness:anaHelp.fairness),document=try XCTUnwrap(PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8)).first)
        do{_ = try await analyzer.analyze(document:document,node:1,revision:0);XCTFail("review evidence was delivered")}catch{XCTAssertEqual(code(error),"NETWORK_GAME")}
        analyzer.startBatch(document);XCTAssertEqual(analyzer.batchStatus,"idle")
        // MCP: every tool but D15's five refuses, each called with arguments its schema accepts.
        let tools=try CompanionTools(session:practice),schemas=try ToolSchemas();practice.setConnection(enabled:true,role:"coach",lease:"fixture")
        let open:Set<String>=["get_session","wait_for_change","list_review_games","open_review","get_review"]
        XCTAssertEqual(Set(schemas.names).intersection(open),open);XCTAssertGreaterThan(schemas.names.count,open.count)
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/CheckmateCore/Resources/tool-schemas.json")
        let all=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:[String:Any]])
        for name in schemas.names where !open.contains(name) {
            let args=try XCTUnwrap(Self.sample(try XCTUnwrap(all[name])) as? [String:Any]);XCTAssertNoThrow(try schemas.parse(name,args:args),"the sample fits \(name)'s schema")
            do{_ = try await tools.call(name,args:args,lease:"fixture");XCTFail("\(name) answered")}catch{XCTAssertEqual(code(error),"NETWORK_GAME",name)}
        }
        XCTAssertEqual(engine.calls,0,"practice, Review and MCP asked the engine nothing")
        XCTAssertEqual(anaHelp.engine.otherCallsWhileParticipating,0);XCTAssertEqual(anaHelp.engine.nodeCallsWhileParticipating,1)
    }
    /// The smallest value a tool schema accepts: required keys only, the first enum value, minimum counts and lengths,
    /// and a sample for each pattern the schemas use.
    private static func sample(_ schema:[String:Any])->Any {
        if let values=schema["enum"] as? [Any],let first=values.first{return first}
        switch schema["type"] as? String {
        case "object":
            let properties=schema["properties"] as? [String:[String:Any]] ?? [:]
            return Dictionary(uniqueKeysWithValues:(schema["required"] as? [String] ?? []).map{($0,sample(properties[$0] ?? [:]))})
        case "string":
            switch schema["pattern"] as? String {
            case "^[a-h][1-8]$"?:return "e2"
            case "^[a-h][1-8][a-h][1-8][qrbn]?$"?:return "e2e4"
            case "^[a-z0-9]+(-[a-z0-9]+)*$"?:return "sample"
            default:return String(repeating:"x",count:max(1,schema["minLength"] as? Int ?? 1))
            }
        case "integer","number":return schema["minimum"] as? Int ?? 0
        case "boolean":return false
        case "array":
            if let prefix=schema["prefixItems"] as? [[String:Any]]{return prefix.map{sample($0)}}
            return Array(repeating:sample(schema["items"] as? [String:Any] ?? [:]),count:schema["minItems"] as? Int ?? 0)
        default:return "x"
        }
    }
}
/// An engine that searches only for a time, as the protocol's default does: it refuses a node limit (A5).
@MainActor private final class NodelessEngine:TestEngineService {
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {XCTFail("a network hint must not fall back to a timed search");return EngineAnalysis()}
}
