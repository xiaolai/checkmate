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
        // A coach left connected keeps its renewal and timeout tasks, which would outlive this test.
        addTeardownBlock{@MainActor in voice.disconnect();assistant.cancel()}
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
    /// Runs everything already queued on the main queue, where the coach hears of network changes.
    private func drainMain()async {await withCheckedContinuation{done in DispatchQueue.main.async{done.resume()}}}
    private func outputs(_ coach:Coach)->[String:String] {
        var found:[String:String]=[:];for event in coach.events.all where (event["item"] as? [String:Any])?["type"] as? String=="function_call_output"{let item=event["item"] as! [String:Any];found[item["call_id"] as? String ?? ""]=item["output"] as? String}
        return found
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

    /// Protocol 1.3: a mini-game has no assistance, so neither player has the coach, even when the host sheet asked for
    /// hints before the mini-game was chosen.
    func testARulesetGameHasNoCoach()throws {
        let previous=ProcessInfo.processInfo.environment["CHECKMATE_NETWORK_MINI_GAMES"];setenv("CHECKMATE_NETWORK_MINI_GAMES","1",1)
        defer{if let previous {setenv("CHECKMATE_NETWORK_MINI_GAMES",previous,1)}else{unsetenv("CHECKMATE_NETWORK_MINI_GAMES")}}
        let lan=MemoryLAN(),ana=try NetworkControllerTests().hosting(lan){$0.miniGame = .pawnDuel;$0.side = .white;$0.assistance=NetworkAssistance(both:.hints)}
        let ben=try NetworkControllerTests().joining(lan,"Ben",ana)
        XCTAssertNotNil(ana.game.ruleset,"premise: a ruleset game");XCTAssertEqual(ana.game.assistance,.off)
        for mac in [ana,ben] {
            let coach=try coach(mac);XCTAssertFalse(coach.voice.networkVoiceAvailable,"\(mac.game.playerName) has no coach in a mini-game")
            XCTAssertThrowsError(try coach.voice.automationOpen(),"no session opens for \(mac.game.playerName)");XCTAssertFalse(coach.voice.networkSession)
        }
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
        // The network game moves on while Practice stays at the start, so a tool that read Practice would be caught.
        NetworkControllerTests().play(ana,"e2","e4",lan);await drainMain()
        XCTAssertNotEqual(ana.game.rules.fen,coach.session.rules.fen,"fixture: the network board and Practice's differ");XCTAssertNil(coach.session.rules.piece("e4"),"fixture: e4 is empty in Practice")
        let board=try await coach.voice.execute("get_board",args:[:],id:"board") as? [String:Any],network=board?["network"] as? [String:Any]
        XCTAssertEqual((board?["state"] as? [String:Any])?["mode"] as? String,"network");XCTAssertEqual(network?["fen"] as? String,ana.game.rules.fen);XCTAssertEqual(network?["moves"] as? [String],["e4"])
        XCTAssertEqual((board?["state"] as? [String:Any])?["positionId"] as? String,position(ana));XCTAssertEqual((board?["state"] as? [String:Any])?["turn"] as? String,"b")
        let legal=Set((board?["legalMoves"] as? [[String:Any]] ?? []).compactMap{$0["uci"] as? String})
        XCTAssertEqual(legal,Set(ana.game.rules.moves().map(\.uci)));XCTAssertTrue(legal.contains("e7e5"));XCTAssertFalse(legal.contains("e2e4"),"Practice's moves are not the game's")
        // The inspector reads the game's pawn on e4.
        let inspected=try await coach.voice.execute("inspect_piece",args:["positionId":position(ana),"square":"e4","mode":"attacked"],id:"inspect") as? [String:Any]
        XCTAssertEqual(inspected?["square"] as? String,"e4");XCTAssertEqual(inspected?["piece"] as? String,"p");XCTAssertEqual(inspected?["color"] as? String,"w")
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
        // A spoken turn alone, without a hint, still flags the move once the learner hears it: everything the coach says
        // counts (A7), from the moment it is said.
        _ = try await benCoach.voice.execute("speak_explanation",args:speech(ben,"Your e-pawn can take the centre."),id:"s");XCTAssertFalse(ben.game.assistedThisTurn,"queued speech is not yet advice")
        benCoach.voice.receive(["type":"response.done","response":["status":"completed"]]);benCoach.voice.audio.onPlaybackStart?();XCTAssertTrue(ben.game.assistedThisTurn)
        XCTAssertEqual(benCoach.engine.calls,0)
        // The other Mac's name is untrusted text: no event either coach sends, instructions or tool results, carries it.
        for (coach,other) in [(anaCoach,"Ben"),(benCoach,"Ana")] {
            let sent=coach.events.all.map{String(decoding:(try? JSONSerialization.data(withJSONObject:$0)) ?? Data(),as:UTF8.self)}
            XCTAssertFalse(sent.isEmpty);XCTAssertFalse(sent.contains{$0.range(of:"\\b\(other)\\b",options:.regularExpression) != nil},"\(other)'s name reached the voice model")
        }
    }
    /// The other Mac's name never reaches the model in a tool result: the calls run as the service makes them, and
    /// what the coach sends back for each is scanned.
    func testToolResultsSentToTheModelCarryNoPeerName()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.hints),lan),coach=try coach(ana)
        try open(coach);coach.voice.ask("What should I play?")
        let calls:[(String,[String:Any])]=[("get_board",[:]),("inspect_piece",["positionId":position(ana),"square":"e2","mode":"attacked"]),("get_hint",["positionId":position(ana)])]
        for (index,(name,args)) in calls.enumerated() {
            let arguments=String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self)
            coach.voice.receive(["type":"response.function_call_arguments.done","name":name,"call_id":"call-\(index)","arguments":arguments])
            try await settle({self.outputs(coach)["call-\(index)"] != nil},"\(name) answered")
            let output=try XCTUnwrap(outputs(coach)["call-\(index)"])
            XCTAssertFalse(output.contains("\"error\""),"\(name) failed: \(output)");XCTAssertNil(output.range(of:#"\bBen\b"#,options:.regularExpression),"\(name) sent the other Mac's name")
        }
        XCTAssertEqual(coach.engine.calls,1,"the hint was the agreed search")
    }

    /// A10: under `guided` the coach speaks once, unprompted, at the start of each of the learner's moves; a turn still
    /// going when the move is played stops.
    func testGuidedCommentsOncePerMove()async throws {
        let lan=MemoryLAN(),(ana,ben,_)=try game(NetworkAssistance(both:.guided),lan),anaCoach=try coach(ana),benCoach=try coach(ben)
        let comments={(coach:Coach) in coach.events.responses.filter{(($0["response"] as? [String:Any])?["instructions"] as? String ?? "").contains(VoiceCoach.commentaryPrefix)}.count}
        try open(anaCoach);try open(benCoach)
        XCTAssertEqual(comments(anaCoach),1,"Ana's first move gets one comment");XCTAssertEqual(comments(benCoach),0,"Ben waits for his move")
        // Once that comment is finished and the coach is idle, more news about the same move asks for no other.
        anaCoach.voice.receive(["type":"response.done","response":["status":"completed"]])
        for _ in 0..<3{ana.game.objectWillChange.send()};await drainMain()
        XCTAssertEqual(comments(anaCoach),1,"once a move");XCTAssertEqual(anaCoach.events.responses.count,1,"nothing else was asked")
        // Reconnecting does not earn the same move a second comment.
        anaCoach.voice.disconnect();try open(anaCoach);await drainMain();XCTAssertEqual(comments(anaCoach),1,"once a move, across a reconnection")
        NetworkControllerTests().play(ana,"e2","e4",lan)
        try await settle({comments(benCoach)==1},"Ben's move gets its comment")
        // Ben plays while his comment is still being made: it stops, and its cancellation is acknowledged.
        NetworkControllerTests().play(ben,"e7","e5",lan)
        try await settle({benCoach.events.all.contains{$0["type"] as? String=="response.cancel"}},"the comment for the move played stops")
        benCoach.voice.receive(["type":"response.done","response":["status":"cancelled"]])
        try await settle({comments(anaCoach)==2},"Ana's next move gets its comment");await drainMain();XCTAssertEqual(comments(anaCoach),2)
    }
    /// A10: a learner's move that begins while the session renews still gets its one guided comment once the renewed
    /// session is ready; renewal is not a greeting, and the comment is still once a move.
    func testAMoveBegunDuringRenewalGetsItsComment()async throws {
        let lan=MemoryLAN(),(ana,ben,_)=try game(NetworkAssistance(both:.guided),lan),benCoach=try coach(ben)
        let comments={benCoach.events.responses.filter{(($0["response"] as? [String:Any])?["instructions"] as? String ?? "").contains(VoiceCoach.commentaryPrefix)}.count}
        try open(benCoach);XCTAssertEqual(comments(),0,"fixture: Ben waits for his move")
        // The session ends to renew; Ben's move begins while no session is ready.
        benCoach.voice.disconnect();NetworkControllerTests().play(ana,"e2","e4",lan);await drainMain();XCTAssertEqual(comments(),0)
        try benCoach.voice.automationOpen(greet:false);benCoach.voice.receive(["type":"session.updated"])
        XCTAssertEqual(comments(),1,"the renewed session comments on the move begun meanwhile")
        // Renewing again within the same move asks for no second comment.
        benCoach.voice.receive(["type":"response.done","response":["status":"completed"]])
        try benCoach.voice.automationRenew();benCoach.voice.receive(["type":"session.updated"]);await drainMain()
        XCTAssertEqual(comments(),1,"still once a move")
    }
    /// A10: a practice conversation stays with practice. The network session opened after joining starts a fresh
    /// transcript, so practice advice is neither shown beside the network board nor carried into its renewals.
    func testANetworkSessionStartsAFreshTranscript()async throws {
        let lan=MemoryLAN(),terms=NetworkAssistance(both:.hints),ana=try NetworkControllerTests().hosting(lan){$0.assistance=terms},coach=try coach(ana)
        try open(coach);XCTAssertFalse(coach.voice.networkSession,"fixture: practice before anyone joins")
        coach.voice.ask("Is my practice knight safe?");XCTAssertFalse(coach.voice.history.isEmpty,"fixture: practice has a transcript")
        // A practice renewal carries its summary, so there is one for the network session to leave behind.
        try coach.voice.automationRenew();coach.voice.receive(["type":"session.updated"])
        XCTAssertTrue(coach.voice.carriedSummary.contains("practice knight"),"fixture: practice carries a renewal summary")
        _ = try NetworkControllerTests().joining(lan,"Ben",ana,accepting:terms)
        XCTAssertFalse(coach.voice.connected,"joining ended the practice session")
        // Opened as a renewal would be (no greeting, which would clear the summary itself), so only the transcript's
        // scope keeps practice's summary out of the network session.
        let before=coach.events.all.count
        try coach.voice.automationOpen(greet:false);coach.voice.receive(["type":"session.updated"]);XCTAssertTrue(coach.voice.networkSession)
        XCTAssertTrue(coach.voice.history.isEmpty,"practice's transcript is not the network game's");XCTAssertTrue(coach.voice.carriedSummary.isEmpty)
        let sent=coach.events.all.dropFirst(before).map{String(decoding:(try? JSONSerialization.data(withJSONObject:$0)) ?? Data(),as:UTF8.self)}
        XCTAssertFalse(sent.isEmpty);XCTAssertFalse(sent.contains{$0.contains("practice knight")},"the network session is told nothing of practice")
    }
    /// A10: the coach speaks only on the learner's move; a game paused for the other player is not their move, so a
    /// turn in progress stops then, though no move was played.
    func testAPausedGameStopsTheTurn()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.hints),lan),coach=try coach(ana)
        try open(coach);coach.voice.ask("What should I play?");XCTAssertEqual(coach.events.responses.count,1)
        let revision=ana.game.gameRevision
        lan.transport.stallConnects=true;lan.transport.cut(try XCTUnwrap(lan.guestConnection));lan.scheduler.run()
        XCTAssertFalse(ana.game.yourTurn,"fixture: the game is paused while Ben is away");XCTAssertEqual(ana.game.gameRevision,revision,"fixture: no move was played")
        try await settle({coach.events.all.contains{$0["type"] as? String=="response.cancel"}},"the turn stops while the game is paused")
    }

    /// A10: leaving, or the game ending, ends the network session; the coach then follows D8 and practice again.
    func testLeavingOrTheEndEndsTheSession()async throws {
        let lan=MemoryLAN(),(ana,ben,_)=try game(NetworkAssistance(both:.hints),lan),anaCoach=try coach(ana),benCoach=try coach(ben)
        try open(anaCoach);try open(benCoach);XCTAssertTrue(anaCoach.voice.connected)
        NetworkControllerTests().play(ana,"e2","e4",lan);XCTAssertTrue(benCoach.voice.connected,"the coach follows the game through its moves")
        // Ben's coach asks for a hint; its search is still running when the game ends.
        await drainMain();benCoach.engine.holding=true
        // The call arrives as the service sends it, so its result would go back to the model through the coach's own path.
        benCoach.voice.ask("Should I use the hint?")
        let arguments=String(decoding:try JSONSerialization.data(withJSONObject:["positionId":position(ben)]),as:UTF8.self)
        benCoach.voice.receive(["type":"response.function_call_arguments.done","name":"get_hint","call_id":"late","arguments":arguments])
        try await settle({benCoach.engine.held==1},"the hint's search is in flight");let sentBefore=benCoach.events.all.count
        ana.game.leave();lan.scheduler.run();benCoach.engine.releaseAll()
        // The handler runs to its end: its search returns, and what it would answer goes nowhere.
        try await settle({benCoach.engine.held==0},"the held search was released");for _ in 0..<5{await drainMain();try await Task.sleep(for:.milliseconds(10))}
        XCTAssertNil(outputs(benCoach)["late"],"no tool result for the late hint reaches the model")
        XCTAssertNil(benCoach.assistant.hint,"no hint is shown");XCTAssertFalse(ben.game.assistedThisTurn,"nothing counts as help")
        XCTAssertFalse(benCoach.events.all.dropFirst(sentBefore).contains{["response.create","conversation.item.create"].contains($0["type"] as? String ?? "")},"nothing more reaches the model")
        for coach in [anaCoach,benCoach] {
            XCTAssertFalse(coach.voice.connected,"the game ended for both");XCTAssertFalse(coach.voice.networkSession);XCTAssertFalse(coach.voice.networkVoiceAvailable)
            let before=coach.events.responses.count;coach.voice.ask("Still there?");XCTAssertEqual(coach.events.responses.count,before)
        }
        XCTAssertEqual(anaCoach.engine.calls,0);XCTAssertEqual(benCoach.engine.calls,1,"only the search begun during the game")
    }

    /// A7: speech counts as help once it reaches the learner, as audio or, when its narration cannot be verified, as
    /// text. An explanation stopped before it is heard gave no advice, so the move stays unassisted.
    func testSpeechCountsOnlyOnceItReachesTheLearner()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.hints),lan),coach=try coach(ana)
        try open(coach);coach.voice.ask("What should I play?")
        _ = try await coach.voice.execute("speak_explanation",args:speech(ana),id:"s");coach.voice.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertFalse(ana.game.assistedThisTurn,"queued, not yet heard")
        coach.voice.stopTurn();coach.voice.receive(["type":"response.done","response":["status":"cancelled"]])
        XCTAssertFalse(ana.game.assistedThisTurn,"stopped before it was heard: no advice was given")
        // Narration that cannot be verified is shown as text instead, which reaches the learner.
        coach.voice.ask("And now?");_ = try await coach.voice.execute("speak_explanation",args:speech(ana),id:"t")
        coach.voice.receive(["type":"response.done","response":["status":"completed"]])
        coach.voice.receive(["type":"response.output_audio_transcript.done","transcript":"Something else entirely."])
        XCTAssertTrue(ana.game.assistedThisTurn,"the explanation shown as text counts")
    }
    /// One explanation a turn: a second speak_explanation is refused and the first is the one narrated, never silently
    /// replaced. The same holds in Practice.
    func testASecondExplanationInOneTurnIsRefusedAndTheFirstKept()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.hints),lan),coach=try coach(ana)
        try open(coach);coach.voice.ask("What should I play?")
        let first=try await coach.voice.execute("speak_explanation",args:speech(ana,"Develop your knight."),id:"a") as? [String:Any];XCTAssertEqual(first?["queued"] as? Int,1)
        await refused("SPEECH_QUEUED",{try await coach.voice.execute("speak_explanation",args:self.speech(ana,"Push a pawn."),id:"b")},"a second explanation in the turn")
        let before=coach.events.all.count;coach.voice.receive(["type":"response.done","response":["status":"completed"]])
        let narrated=coach.events.all.dropFirst(before).map{String(decoding:(try? JSONSerialization.data(withJSONObject:$0)) ?? Data(),as:UTF8.self)}
        XCTAssertTrue(narrated.contains{$0.contains("Develop your knight.")},"the first explanation is narrated");XCTAssertFalse(narrated.contains{$0.contains("Push a pawn.")})
        let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);_ = try s.openVoice();v.receive(["type":"session.updated"]);addTeardownBlock{@MainActor in v.disconnect()}
        func practiceSpeech(_ text:String)->[String:Any] {["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":text,"squares":["e2"],"kind":"observation"]]]}
        _ = try await v.execute("speak_explanation",args:practiceSpeech("Your pawn is on e2."),id:"a")
        await refused("SPEECH_QUEUED",{try await v.execute("speak_explanation",args:practiceSpeech("Your king is on e1."),id:"b")},"a second explanation in a practice turn")
    }
    /// A10: guided commentary nobody asked for speaks one segment, in the network game too; an answer the learner asked
    /// for may speak several.
    func testGuidedNetworkCommentarySpeaksOneSegment()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.guided),lan),coach=try coach(ana)
        try open(coach);XCTAssertEqual(coach.events.responses.count,1,"fixture: Ana's move gets its comment")
        let two:[String:Any]=["positionId":position(ana),"displayIdentity":position(ana),"segments":[["text":"Develop a knight.","squares":["g1"],"kind":"advice"],["text":"Or take the centre.","squares":["e2"],"kind":"advice"]]]
        await refused("PROACTIVE_LIMIT",{try await coach.voice.execute("speak_explanation",args:two,id:"long")},"two segments of commentary")
        let one=try await coach.voice.execute("speak_explanation",args:speech(ana),id:"one") as? [String:Any];XCTAssertEqual(one?["queued"] as? Int,1)
        coach.voice.stopTurn();coach.voice.receive(["type":"response.done","response":["status":"cancelled"]])
        coach.voice.ask("What are my ideas?");XCTAssertEqual(coach.events.responses.count,2,"fixture: the learner's question is asked")
        let answer=try await coach.voice.execute("speak_explanation",args:two,id:"answer") as? [String:Any];XCTAssertEqual(answer?["queued"] as? Int,2)
    }
    /// A board whose rules cannot be read is never sent as verified board data: every read throws instead of standing
    /// in a default (an empty position, White to move, no legal moves).
    func testABoardThatCannotBeReadIsNeverSentAsVerified()throws {
        let runtime=try FailingChessRuntime(),rules=try ChessRules(runtimeFactory:{runtime})
        XCTAssertNoThrow(try VoiceCoach.networkContext(rules,side:"w",learnersMove:true,position:"network:0",level:.hints))
        runtime.failing=true
        XCTAssertThrowsError(try VoiceCoach.networkContext(rules,side:"w",learnersMove:true,position:"network:0",level:.hints),"a runtime failure is not read as a position")
    }
    /// UI automation's voice double (`--voice-double`): Connect opens a session with no socket, a turn it is asked for
    /// stays generating until Stop Speaking, whose cancellation it acknowledges, and Disconnect ends it. Nothing is
    /// played or captured.
    func testTheVoiceDoubleConnectsStopsAndDisconnectsSilently()async throws {
        let lan=MemoryLAN(),(ana,_,_)=try game(NetworkAssistance(both:.guided),lan),coach=try coach(ana)
        coach.voice.voiceDouble=true;coach.voice.connect();XCTAssertTrue(coach.voice.connecting)
        try await settle({coach.voice.connected},"the double opens a session");XCTAssertTrue(coach.voice.networkSession)
        // Ana's move asks for its guided comment, which the double leaves generating: there is a turn to stop.
        try await settle({coach.voice.canStopTurn},"a turn is in progress");XCTAssertFalse(coach.voice.turnIdle)
        coach.voice.stopTurn();try await settle({coach.voice.turnIdle && !coach.voice.canStopTurn},"the cancellation is acknowledged")
        coach.voice.disconnect();XCTAssertFalse(coach.voice.connected);XCTAssertFalse(coach.voice.audio.capturing,"no microphone")
        XCTAssertFalse(coach.events.all.contains{$0["type"] as? String=="input_audio_buffer.append"},"nothing from a microphone")
        XCTAssertTrue(coach.events.all.contains{$0["type"] as? String=="response.cancel"},"Stop Speaking cancelled the turn")
    }
}
