import XCTest
import CheckmateTestSupport
@testable import CheckmateApplication
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateMacPlatform
import CheckmateRules

/// Assistance plan A10 over the in-memory LAN, silently: no socket, audio or microphone. The voice coach coaches a
/// network game only for a player whose agreed level is `hints` or `guided`, with the network game's own tools; it
/// speaks only on that player's own move, once unprompted per move under `guided`; every turn it speaks flags the move
/// as assisted; practice's tools and MCP stay closed; and leaving the game ends the session.
@MainActor final class NetworkVoiceCoachTests:XCTestCase {
    typealias CountingEngine=NetworkFairnessTests.CountingEngine
    /// One Mac's practice session and voice coach, over that Mac's participation, network game and counting engine.
    private struct Coach {let session:GameSession,voice:VoiceCoach,assistant:NetworkAssistant,engine:CountingEngine,events:Events}
    private final class Events {var all:[[String:Any]]=[]
        var responses:[[String:Any]] {all.filter{$0["type"] as? String=="response.create"}}
        var configured:[String:Any]? {all.last{$0["type"] as? String=="session.update" && ($0["session"] as? [String:Any])?["tools"] != nil}?["session"] as? [String:Any]}
    }
    private func coach(_ mac:Mac)throws -> Coach {
        let fairness=FairnessPolicy(participation:mac.participation),engine=CountingEngine();engine.participation=mac.participation
        let session=try GameSession(engine:nil,fairness:fairness),voice=try VoiceCoach(session:session),assistant=NetworkAssistant(game:mac.game,fairness:fairness,engine:engine)
        voice.network=(mac.game,assistant);let events=Events();voice.automationOutbound={events.all.append($0)}
        return Coach(session:session,voice:voice,assistant:assistant,engine:engine,events:events)
    }
    /// Ana hosts as White under `terms`, Ben joins as Black accepting them, and Cy watches.
    private func game(_ terms:NetworkAssistance,_ lan:MemoryLAN)throws -> (ana:Mac,ben:Mac,cy:Mac) {
        let ana=try NetworkControllerTests().hosting(lan){$0.assistance=terms}
        let ben=try NetworkControllerTests().joining(lan,"Ben",ana,accepting:terms),cy=try NetworkControllerTests().joining(lan,"Cy",ana,watching:true)
        return (ana,ben,cy)
    }
    /// A session opened for the network game, as a connection does once its socket is ready.
    private func open(_ coach:Coach)throws {try coach.voice.automationOpen();coach.voice.receive(["type":"session.updated"])}
    private func position(_ mac:Mac)->String {"network:\(mac.game.gameRevision ?? -1)"}
    private func speech(_ mac:Mac,_ text:String="Your knight can develop.")->[String:Any] {["positionId":position(mac),"displayIdentity":position(mac),"segments":[["text":text,"squares":["g1"],"kind":"advice"]]]}
    private func code(_ error:Error)->String? {(ProtocolErrors.failure(error)["error"] as? [String:Any])?["code"] as? String}
    private func refused(_ code:String,_ work:()async throws->Any,_ message:String,file:StaticString=#filePath,line:UInt=#line)async {
        do{_ = try await work();XCTFail("\(message) ran",file:file,line:line)}catch{XCTAssertEqual(self.code(error),code,message,file:file,line:line)}
    }
    private func refusedAny(_ work:()async throws->Any,_ message:String,file:StaticString=#filePath,line:UInt=#line)async {
        do{_ = try await work();XCTFail("\(message) ran",file:file,line:line)}catch{}
    }
    private func settle(_ done:@escaping ()->Bool,_ message:String,file:StaticString=#filePath,line:UInt=#line)async throws {
        for _ in 0..<400 where !done(){try await Task.sleep(for:.milliseconds(5))};XCTAssertTrue(done(),message,file:file,line:line)
    }

    /// A10 and D8: at `off` and `insight`, and for a spectator, the coach does not connect to the network game; a
    /// practice session open when the learner joins ends, even when the agreed level allows the coach.
    func testBelowHintsAndSpectatorsKeepD8()throws {
        let lan=MemoryLAN(),(ana,ben,cy)=try game(NetworkAssistance(white:.insight,black:.off),lan)
        for mac in [ana,ben,cy] {
            let coach=try coach(mac);XCTAssertFalse(coach.voice.networkVoiceAvailable,"\(mac.game.playerName) has no coach")
            coach.voice.connect();XCTAssertEqual(coach.voice.status,VoiceCoach.networkGameStatus)
            XCTAssertThrowsError(try coach.voice.automationOpen(),"no session opens for \(mac.game.playerName)");XCTAssertFalse(coach.voice.networkSession)
        }
        // A practice session open before joining a game that allows the coach still ends on joining.
        let other=MemoryLAN(),host=try NetworkControllerTests().hosting(other){$0.assistance=NetworkAssistance(both:.hints)}
        let dee=try Mac(other,name:"Dee"),practice=try coach(dee)
        try open(practice);XCTAssertTrue(practice.voice.connected);XCTAssertFalse(practice.voice.networkSession);XCTAssertNotNil(practice.session.voiceLease)
        dee.game.setShown(true);other.scheduler.run()
        let entry=try XCTUnwrap(dee.game.games.first),code=try XCTUnwrap(host.game.playCode)
        XCTAssertTrue(dee.game.join(entry,code:code.grouped,accepting:entry.assistance));other.scheduler.run()
        XCTAssertEqual(dee.participation.assistance,.hints)
        XCTAssertFalse(practice.voice.connected,"the practice conversation does not carry into the network game");XCTAssertNil(practice.session.voiceLease)
        XCTAssertTrue(practice.voice.networkVoiceAvailable,"a new session for the game may open")
    }

    /// A10 and A9: a network session is configured with the network game's tools only and its own rules; practice's
    /// tools are refused even when called directly, and MCP stays `NETWORK_GAME`.
    func testANetworkSessionOffersOnlyTheGamesTools()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.hints),lan),coach=try coach(ana)
        XCTAssertTrue(coach.voice.networkVoiceAvailable);try open(coach);XCTAssertTrue(coach.voice.networkSession);XCTAssertNil(coach.session.voiceLease,"the network game takes no practice lease")
        let configured=try XCTUnwrap(coach.events.configured),tools=(configured["tools"] as? [[String:Any]] ?? []).compactMap{$0["name"] as? String}
        XCTAssertEqual(Set(tools),VoiceCoach.networkToolNames);XCTAssertEqual(tools.count,4)
        XCTAssertTrue((configured["instructions"] as? String ?? "").contains("network game against another person"))
        XCTAssertFalse((configured["instructions"] as? String ?? "").contains("Ben"),"the other Mac's name is data, never instructions")
        for name in ["analyze_position","test_move","highlight_squares","demonstrate_moves","control_demonstration","play_requested_move"] {
            await refused(FairnessPolicy.refusal,{try await coach.voice.execute(name,args:["positionId":self.position(ana)],id:name)},name)
        }
        let board=try await coach.voice.execute("get_board",args:[:],id:"board") as? [String:Any]
        XCTAssertEqual((board?["state"] as? [String:Any])?["mode"] as? String,"network");XCTAssertEqual((board?["network"] as? [String:Any])?["fen"] as? String,ana.game.rules.fen)
        XCTAssertEqual((board?["state"] as? [String:Any])?["positionId"] as? String,position(ana))
        // A9: the voice coach's tools never reopen the MCP surface.
        let mcp=try CompanionTools(session:coach.session);coach.session.setConnection(enabled:true,role:"coach",lease:"fixture")
        do{_ = try await mcp.call("play_move",args:["sessionId":coach.session.sessionId,"revision":coach.session.revision,"requestId":"one"],lease:"fixture");XCTFail("MCP answered during the game")}catch{XCTAssertEqual(code(error),FairnessPolicy.refusal)}
        XCTAssertEqual(coach.engine.calls,0)
    }

    /// A10 and A7: the coach answers only on the learner's own move; what it says flags that move as assisted; the
    /// hint and the inspector are the network game's own, and hints come from the assistant at the shared profile.
    func testTheCoachSpeaksOnlyOnTheLearnersMoveAndFlagsIt()async throws {
        let lan=MemoryLAN(),(ana,ben,cy)=try game(NetworkAssistance(both:.hints),lan),anaCoach=try coach(ana),benCoach=try coach(ben)
        try open(anaCoach);try open(benCoach)
        XCTAssertEqual(anaCoach.events.responses.count+benCoach.events.responses.count,0,"at hints the coach speaks only when asked")
        // Ben waits for his move: a spoken or typed turn is not answered, and nothing he could be told runs.
        benCoach.voice.receive(["type":"input_audio_buffer.committed","item_id":"b1"]);XCTAssertEqual(benCoach.voice.status,VoiceCoach.networkOwnMove)
        benCoach.voice.ask("What now?");XCTAssertEqual(benCoach.events.responses.count,0)
        await refused("NOT_YOUR_MOVE",{try await benCoach.voice.execute("speak_explanation",args:self.speech(ben),id:"s")},"Ben's speech off his move")
        await refused("NOT_YOUR_MOVE",{try await benCoach.voice.execute("get_hint",args:["positionId":self.position(ben)],id:"h")},"Ben's hint off his move")
        XCTAssertEqual(benCoach.engine.calls,0)
        // Ana's move: her question is answered with the agreed hint and the inspector, and her move is flagged.
        anaCoach.voice.ask("What should I play?");XCTAssertEqual(anaCoach.events.responses.count,1)
        let inspected=try await anaCoach.voice.execute("inspect_piece",args:["positionId":position(ana),"square":"e2","mode":"protected"],id:"i") as? [String:Any]
        XCTAssertEqual(inspected?["square"] as? String,"e2");XCTAssertEqual(inspected?["mode"] as? String,"protected");XCTAssertFalse((inspected?["relations"] as? [Any] ?? []).isEmpty)
        XCTAssertEqual(anaCoach.engine.calls,0,"the inspector is rules only");XCTAssertFalse(ana.game.assistedThisTurn)
        let hint=try await anaCoach.voice.execute("get_hint",args:["positionId":position(ana)],id:"h") as? [String:Any]
        XCTAssertEqual(anaCoach.engine.calls,1);XCTAssertEqual(anaCoach.engine.limits,[.nodes(NetworkAssistance.hintNodes)])
        XCTAssertEqual(hint?["uci"] as? String,anaCoach.assistant.hint?.uci,"the coach's hint is the one on the board");XCTAssertTrue(ana.game.assistedThisTurn)
        _ = try await anaCoach.voice.execute("get_hint",args:["positionId":position(ana)],id:"h2");XCTAssertEqual(anaCoach.engine.calls,1,"one search a turn")
        let queued=try await anaCoach.voice.execute("speak_explanation",args:speech(ana),id:"s") as? [String:Any];XCTAssertEqual(queued?["queued"] as? Int,1)
        NetworkControllerTests().play(ana,"g1","f3",lan)
        for mac in [ana,ben,cy]{XCTAssertEqual(mac.game.record?.assistedPlies,[1],"\(mac.game.playerName) sees the coached move")}
        // A stale position is refused; Ben's own move is now his to ask about.
        await refused("STALE_STATE",{try await anaCoach.voice.execute("inspect_piece",args:["positionId":"network:-5","square":"e2","mode":"attacked"],id:"x")},"a tool bound to an earlier move")
        benCoach.voice.ask("And now?");XCTAssertEqual(benCoach.events.responses.count,1)
        // A spoken turn alone, without a hint, still flags the move: everything the coach says counts (A7).
        _ = try await benCoach.voice.execute("speak_explanation",args:speech(ben,"Your e-pawn can take the centre."),id:"s");XCTAssertTrue(ben.game.assistedThisTurn)
        XCTAssertEqual(benCoach.engine.calls,0)
        // The other Mac's name is untrusted text: no event either coach sends, instructions or tool results, carries it.
        for (coach,other) in [(anaCoach,"Ben"),(benCoach,"Ana")] {
            let sent=coach.events.all.map{String(decoding:(try? JSONSerialization.data(withJSONObject:$0)) ?? Data(),as:UTF8.self)}
            XCTAssertFalse(sent.isEmpty);XCTAssertFalse(sent.contains{$0.range(of:"\\b\(other)\\b",options:.regularExpression) != nil},"\(other)'s name reached the voice model")
        }
        let board=try await anaCoach.voice.execute("get_board",args:[:],id:"board2")
        XCTAssertFalse(String(decoding:try JSONSerialization.data(withJSONObject:board),as:UTF8.self).contains("Ben"),"the board tool carries no name")
    }

    /// A10: under `guided` the coach speaks once, unprompted, at the start of each of the learner's moves; a turn still
    /// going when the move is played stops.
    func testGuidedCommentsOncePerMove()async throws {
        let lan=MemoryLAN(),(ana,ben,_)=try game(NetworkAssistance(both:.guided),lan),anaCoach=try coach(ana),benCoach=try coach(ben)
        let comments={(coach:Coach) in coach.events.responses.filter{(($0["response"] as? [String:Any])?["instructions"] as? String ?? "").contains(VoiceCoach.commentaryPrefix)}.count}
        try open(anaCoach);try open(benCoach)
        XCTAssertEqual(comments(anaCoach),1,"Ana's first move gets one comment");XCTAssertEqual(comments(benCoach),0,"Ben waits for his move")
        ana.game.objectWillChange.send();try await Task.sleep(for:.milliseconds(20));XCTAssertEqual(comments(anaCoach),1,"once a move")
        // Ana plays while her comment is still being made: it stops, and its cancellation is acknowledged.
        NetworkControllerTests().play(ana,"e2","e4",lan);try await Task.sleep(for:.milliseconds(20))
        XCTAssertTrue(anaCoach.events.all.contains{$0["type"] as? String=="response.cancel"},"the comment for the move played stops")
        anaCoach.voice.receive(["type":"response.done","response":["status":"cancelled"]])
        try await settle({comments(benCoach)==1},"Ben's move gets its comment")
        NetworkControllerTests().play(ben,"e7","e5",lan)
        try await settle({comments(anaCoach)==2},"Ana's next move gets its comment");try await Task.sleep(for:.milliseconds(20));XCTAssertEqual(comments(anaCoach),2)
    }

    /// A10: leaving, or the game ending, ends the network session; the coach then follows D8 and practice again.
    func testLeavingOrTheEndEndsTheSession()async throws {
        let lan=MemoryLAN(),(ana,ben,_)=try game(NetworkAssistance(both:.hints),lan),anaCoach=try coach(ana),benCoach=try coach(ben)
        try open(anaCoach);try open(benCoach);XCTAssertTrue(anaCoach.voice.connected)
        NetworkControllerTests().play(ana,"e2","e4",lan);XCTAssertTrue(benCoach.voice.connected,"the coach follows the game through its moves")
        ana.game.leave();lan.scheduler.run()
        for coach in [anaCoach,benCoach] {
            XCTAssertFalse(coach.voice.connected,"the game ended for both");XCTAssertFalse(coach.voice.networkSession);XCTAssertFalse(coach.voice.networkVoiceAvailable)
            await refusedAny({try await coach.voice.execute("get_hint",args:["positionId":"network:1"],id:"late")},"a late hint after the game")
            let before=coach.events.responses.count;coach.voice.ask("Still there?");XCTAssertEqual(coach.events.responses.count,before)
        }
        XCTAssertEqual(anaCoach.engine.calls+benCoach.engine.calls,0)
    }
}
