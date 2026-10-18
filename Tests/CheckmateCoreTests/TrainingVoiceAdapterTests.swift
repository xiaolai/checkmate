import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// Mini-game plan WI-021: the voice coach in a standard-rule training game, through `TrainingVoiceAdapter`. Help is
/// recorded before the first disclosure and never on connecting; each response is bound to a ticket that the
/// adapter's own help record refreshes and any other change makes stale; a refusal discloses nothing and retries
/// nothing; only a thinking defender is waited for, once. Silent: no socket, audio or microphone, and the provider's
/// events are delivered with `receive`.
@MainActor final class TrainingVoiceAdapterTests:XCTestCase {
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1);setenv("CHECKMATE_TRAINING_VOICE","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B");unsetenv("CHECKMATE_TRAINING_VOICE")}
    typealias Line=TrainingVoiceAdapter.NeutralLine
    /// Text the exercise holds for the learner's own hints and its solved explanation, which no payload may carry.
    static let secrets=["SECRET-EXPLANATION","SECRET-HINT-ONE","SECRET-HINT-TWO"]
    /// King and queen against king, White to move; g1g2 is a quiet move, and the defender answers h8h7.
    static func scenario(id:String="voice-ending")->TrainingScenario {
        TrainingScenario(id:id,entry:"finish-the-game",variant:"kqk",tier:1,cluster:id,learner:"w",prompt:"Checkmate the lone king.",explanation:secrets[0],hints:[secrets[1],secrets[2]],fen:"7k/8/5K2/8/8/8/8/6Q1 w - - 0 1",review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion),check:.ending)
    }
    final class Box {var events:[[String:Any]]=[]}
    struct Fixture {
        let session:GameSession,player:LearningPlayer,controller:TrainingController,adapter:TrainingVoiceAdapter,voice:VoiceCoach,defender:ScriptedDefender,box:Box
        var events:[[String:Any]] {box.events}
        @MainActor var exercise:TrainingController.Exercise {controller.exercise!}
    }
    /// A training game shown, with the coach wired to its adapter. `practice` plays two practice moves first, so the
    /// practice board differs from the training one.
    func fixture(practice:Bool=false,engine:EngineService?=nil)throws -> Fixture {
        let defender=ScriptedDefender(),(session,player,controller)=try TrainingEndgameTests.fixture([Self.scenario()],defender:defender)
        if let engine{controller.games.engine=engine}
        if practice{try session.playWhite(from:"e2",to:"e4");_ = try session.commitBlack("e7e5")}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        let adapter=TrainingVoiceAdapter(session:session,controller:controller),voice=try VoiceCoach(session:session),box=Box()
        voice.training=adapter;voice.automationOutbound={box.events.append($0)}
        addTeardownBlock{@MainActor in voice.disconnect();defender.release();player.shutdown()}
        return Fixture(session:session,player:player,controller:controller,adapter:adapter,voice:voice,defender:defender,box:box)
    }
    /// A training session opened as a connection does once its socket is ready.
    func open(_ f:Fixture)throws {try f.voice.automationOpen(greet:false,training:true);f.voice.receive(["type":"session.updated"])}
    func ask(_ f:Fixture,_ item:String="question"){f.voice.receive(["type":"input_audio_buffer.committed","item_id":item])}
    func call(_ f:Fixture,_ name:String,_ id:String,_ args:[String:Any]=[:])throws {f.voice.receive(["type":"response.function_call_arguments.done","name":name,"call_id":id,"arguments":String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self)])}
    func done(_ f:Fixture){f.voice.receive(["type":"response.done","response":["status":"completed"]])}
    /// Speaks the script being read, as the provider would, and completes it.
    func spoken(_ f:Fixture)throws {let text=try XCTUnwrap(scripts(f).last);f.voice.receive(["type":"response.output_audio_transcript.done","transcript":text]);done(f)}
    func responses(_ f:Fixture)->[[String:Any]] {f.events.compactMap{$0["type"] as? String=="response.create" ? $0["response"] as? [String:Any]:nil}}
    /// Coaching requests (the model asked to answer), as opposed to scripts read aloud.
    func coaching(_ f:Fixture)->[String] {responses(f).filter{$0["conversation"] as? String != "none"}.map{$0["instructions"] as? String ?? ""}}
    func scripts(_ f:Fixture)->[String] {responses(f).filter{$0["conversation"] as? String=="none"}.compactMap{($0["instructions"] as? String)?.components(separatedBy:"SCRIPT:\n").last}}
    func outputs(_ f:Fixture)->[String:String] {
        var found:[String:String]=[:]
        for event in f.events{guard let item=event["item"] as? [String:Any],item["type"] as? String=="function_call_output" else{continue};found[item["call_id"] as? String ?? ""]=item["output"] as? String}
        return found
    }
    func object(_ text:String?)throws -> [String:Any] {try XCTUnwrap(JSONSerialization.jsonObject(with:Data(try XCTUnwrap(text).utf8)) as? [String:Any])}
    func waitFor(_ what:String,file:StaticString=#filePath,line:UInt=#line,_ condition:@escaping ()->Bool)async throws {for _ in 0..<400 {if condition(){return};try await Task.sleep(for:.milliseconds(5))};XCTFail(what,file:file,line:line)}
    /// Runs what is queued on the main queue, where the coach hears of training changes.
    func drain()async {for _ in 0..<3{await withCheckedContinuation{done in DispatchQueue.main.async{done.resume()}}}}
    func code(_ body:() async throws -> Any)async -> String? {do{_ = try await body();return nil}catch{return (ProtocolErrors.failure(error)["error"] as? [String:Any])?["code"] as? String}}
    func speech(_ key:String,_ text:String="Your queen on g1 can take squares from the king.")->[String:Any] {["positionId":key,"displayIdentity":key,"segments":[["text":text,"squares":["g1"],"kind":"advice"]]]}
    func recorded(_ f:Fixture)->Bool {f.session.state.training?.active?.recordedHelp ?? false}
    func encoded<T:Encodable>(_ value:T?)throws -> Data {let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;return try encoder.encode(value)}

    /// The recorder's outcomes, each tested before it is used: only `recorded` saves, and every refusal leaves the
    /// attempt and its record exactly as they were. A finished attempt (its review included) is never recorded.
    func testRecordAgentHelpReturnsATypedOutcome()throws {
        let f=try fixture()
        func unchanged(_ outcome:TrainingController.AgentHelpOutcome,_ change:()->Void,undo:()->Void)throws {
            let record=try encoded(f.session.state.training);change()
            XCTAssertEqual(f.controller.recordAgentHelp(),outcome);XCTAssertFalse(outcome.helped)
            XCTAssertEqual(try encoded(f.session.state.training),record,"\(outcome) recorded nothing");XCTAssertFalse(f.exercise.snapshot.recordedHelp,"\(outcome)");undo()
        }
        try unchanged(.defenderThinking,{f.controller.games.thinking=true},undo:{f.controller.games.thinking=false})
        try unchanged(.unwritable,{f.session.state.trainingRaw = .object([:])},undo:{f.session.state.trainingRaw=nil})
        let place=f.session.activity.place
        try unchanged(.stale,{f.session.enter(.reviewing(ReviewVisit(document:nil,draft:true,returnTo:place)))},undo:{f.session.enter(.at(place))})
        let revision=f.exercise.snapshot.revision
        try unchanged(.storageFull,{f.controller.exercise?.snapshot.revision=TrainingState.maximumCount},undo:{f.controller.exercise?.snapshot.revision=revision})
        XCTAssertEqual(f.controller.recordAgentHelp(),.recorded);XCTAssertEqual(f.exercise.snapshot.revision,revision+1);XCTAssertTrue(recorded(f))
        XCTAssertEqual(f.controller.recordAgentHelp(),.alreadyRecorded);XCTAssertEqual(f.exercise.snapshot.revision,revision+1,"nothing saved again")
        // The review after an attempt is not help: a finished attempt's record never changes.
        let other=try fixture();XCTAssertTrue(other.controller.finish(other.exercise,.incorrect))
        let attempts=try encoded(other.session.state.training?.attempts)
        XCTAssertEqual(other.controller.recordAgentHelp(),.finished);XCTAssertEqual(try encoded(other.session.state.training?.attempts),attempts)
        XCTAssertFalse(other.adapter.connectable,"a finished game offers no coach")
        XCTAssertEqual(Set(TrainingController.AgentHelpOutcome.allCases.filter(\.helped)),[.recorded,.alreadyRecorded])
    }
    /// Connecting records nothing and says nothing; one answer is then delivered exactly once across the adapter's own
    /// help save (r to r+1), with its ticket refreshed in the same step, so even the response's original position
    /// identity still names the live board.
    func testOneAnswerIsDeliveredExactlyOnceAcrossItsOwnHelpRecord()async throws {
        let f=try fixture();try open(f)
        let start=try XCTUnwrap(f.adapter.liveTicket)
        XCTAssertTrue(f.voice.trainingSession);XCTAssertNil(f.session.voiceLease,"a training game takes no practice lease")
        XCTAssertFalse(recorded(f),"connecting records nothing");XCTAssertTrue(responses(f).isEmpty,"and asks the model nothing")
        ask(f);XCTAssertEqual(coaching(f).count,1)
        XCTAssertFalse(coaching(f)[0].contains("7k/8/5K2"),"a training turn carries no board")
        try call(f,"get_board","board");try await waitFor("the board is read"){self.outputs(f)["board"] != nil}
        let saved=try XCTUnwrap(f.session.state.training?.active)
        XCTAssertTrue(saved.recordedHelp,"recorded before the first tool result");XCTAssertEqual(saved.revision,start.revision+1)
        let next=Ticket(attempt:start.attempt,revision:start.revision+1)
        XCTAssertEqual(f.adapter.liveTicket,next);XCTAssertTrue(f.adapter.accepts(start.key),"the adapter's own record refreshed the ticket")
        let board=try object(outputs(f)["board"]),state=try XCTUnwrap(board["state"] as? [String:Any])
        XCTAssertEqual(state["positionId"] as? String,next.key);XCTAssertEqual((board["legalMoves"] as? [Any])?.isEmpty,false)
        done(f);XCTAssertEqual(coaching(f).count,2,"the tool results continue the same answer")
        try call(f,"speak_explanation","speech",speech(start.key))
        try await waitFor("the answer is queued"){self.outputs(f)["speech"] != nil}
        XCTAssertEqual(try object(outputs(f)["speech"])["queued"] as? Int,1)
        done(f);XCTAssertEqual(scripts(f),["Your queen on g1 can take squares from the king."])
        try spoken(f);try await waitFor("the answer ends"){f.voice.turnIdle}
        await drain()
        XCTAssertEqual(scripts(f).count,1,"spoken exactly once");XCTAssertEqual(outputs(f).count,2)
        XCTAssertFalse(outputs(f).values.contains{$0.contains("STALE_STATE")});XCTAssertFalse(coaching(f).contains{$0.contains(VoiceCoach.trainingRegenerate)},"nothing was asked again")
        XCTAssertEqual(f.session.state.training?.active?.revision,start.revision+1,"one help record");XCTAssertTrue(f.voice.connected)
        XCTAssertEqual(f.voice.history.last?.context,"Training game")
    }
    typealias Ticket=TrainingVoiceAdapter.Ticket
    /// Opens a session, asks, reads the board (recording the help) and queues an answer that is not yet spoken.
    func prepareAnswer(_ f:Fixture)async throws -> String {
        ask(f);try call(f,"get_board","board");try await waitFor("the board is read"){self.outputs(f)["board"] != nil}
        done(f);let key=try XCTUnwrap(f.adapter.liveTicket?.key)
        try call(f,"speak_explanation","speech",speech(key,"The old answer."));try await waitFor("the answer is queued"){self.outputs(f)["speech"] != nil}
        return key
    }
    /// An answer prepared before the learner's move is dropped: it is never spoken, and once the defender has replied
    /// it is asked again, from the new board.
    func testAnAnswerPreparedBeforeALearnerMoveIsDroppedAndAskedAgain()async throws {
        let f=try fixture();f.defender.holding=true;try open(f)
        _ = try await prepareAnswer(f)
        f.controller.attempt(from:"g1",to:"g2",promotion:nil);XCTAssertTrue(f.controller.games.thinking)
        await drain();XCTAssertTrue(f.events.contains{$0["type"] as? String=="response.cancel"},"the answer in progress is cancelled")
        done(f);await drain()
        XCTAssertEqual(coaching(f).count,2,"nothing is asked while the defender thinks");XCTAssertEqual(f.voice.status,Line.moment.text)
        f.defender.release();await TrainingEndgameTests.settle(f.controller);await drain()
        XCTAssertEqual(f.exercise.line,["g1g2","h8h7"])
        XCTAssertEqual(coaching(f).count,3);XCTAssertTrue(coaching(f)[2].contains(VoiceCoach.trainingRegenerate),"asked again from the new board")
        try call(f,"get_board","new-board");try await waitFor("the new board is read"){self.outputs(f)["new-board"] != nil}
        XCTAssertEqual((try object(outputs(f)["new-board"])["state"] as? [String:Any])?["positionId"] as? String,f.adapter.liveTicket?.key)
        XCTAssertTrue(scripts(f).isEmpty,"the old answer was never spoken")
    }
    /// An answer prepared before the defender's reply (asked again after a pause) is dropped and asked again.
    func testAnAnswerPreparedBeforeADefenderReplyIsDroppedAndAskedAgain()async throws {
        let f=try fixture();f.defender.failure=CheckmateError.unavailable("down")
        f.controller.attempt(from:"g1",to:"g2",promotion:nil);await TrainingEndgameTests.settle(f.controller)
        XCTAssertNotNil(f.exercise.paused,"the defender failed, so the game waits for it")
        f.defender.failure=nil;f.defender.holding=true;try open(f)
        _ = try await prepareAnswer(f)
        f.controller.retryDefender();XCTAssertTrue(f.controller.games.thinking)
        f.defender.release();await TrainingEndgameTests.settle(f.controller);await drain()
        XCTAssertEqual(f.exercise.line,["g1g2","h8h7"],"the reply landed")
        done(f);await drain()
        XCTAssertTrue(scripts(f).isEmpty,"the answer about the board before the reply was never spoken")
        XCTAssertEqual(coaching(f).filter{$0.contains(VoiceCoach.trainingRegenerate)}.count,1,"asked again once, from the new board")
    }
    /// An answer prepared before the learner takes a move back is dropped and asked again.
    func testAnAnswerPreparedBeforeAnUndoIsDroppedAndAskedAgain()async throws {
        let f=try fixture();f.controller.attempt(from:"g1",to:"g2",promotion:nil);await TrainingEndgameTests.settle(f.controller)
        try open(f);_ = try await prepareAnswer(f)
        f.controller.undo();XCTAssertEqual(f.exercise.line,[]);await drain()
        done(f);await drain()
        XCTAssertTrue(scripts(f).isEmpty,"the answer about the board before the undo was never spoken")
        XCTAssertEqual(coaching(f).filter{$0.contains(VoiceCoach.trainingRegenerate)}.count,1)
    }
    /// While the learner switches attempts, nothing reaches the new attempt: a search in flight for the old one is
    /// dropped, the new attempt cannot be disclosed to before its own help record, and the coach stops.
    func testSwitchingAttemptsSuspendsAuthorizationAndStopsTheCoach()async throws {
        let f=try fixture();try open(f)
        ask(f);try call(f,"get_board","board");try await waitFor("the board is read"){self.outputs(f)["board"] != nil}
        done(f);let old=try XCTUnwrap(f.adapter.liveTicket),first=f.exercise.snapshot.id
        f.defender.holding=true
        try call(f,"analyze_position","analysis",["positionId":old.key])
        try await waitFor("the coaching search starts"){f.defender.requests.contains{$0.budget==TrainingVoiceAdapter.budget}}
        f.controller.begin(try f.controller.prepare(entry:"finish-the-game"))
        let second=f.exercise.snapshot.id;XCTAssertNotEqual(first,second)
        // Before the coach hears of the change: the new attempt's board is refused too, and nothing is recorded on it.
        XCTAssertFalse(f.adapter.inScope)
        for key in [old.key,"training:\(second):\(f.exercise.snapshot.revision)"] {
            XCTAssertThrowsError(try f.adapter.disclose([key])){XCTAssertEqual($0 as? TrainingVoiceAdapter.Stop,.outOfScope)}
        }
        f.defender.release()
        try await waitFor("the coach stops"){!f.voice.connected}
        XCTAssertNil(outputs(f)["analysis"],"the old attempt's search reached nobody");XCTAssertTrue(scripts(f).isEmpty)
        XCTAssertFalse(f.exercise.snapshot.recordedHelp,"the new attempt has no help record");XCTAssertEqual(f.session.state.training?.active?.id,second);XCTAssertFalse(recorded(f))
        XCTAssertEqual(f.voice.status,Line.stopped.text);XCTAssertFalse(f.voice.trainingSession);XCTAssertNil(f.adapter.scope)
    }
    /// Each refusal (`stale`, `storageFull`, `unwritable`) ends the disclosure: no tool result, no coaching, only the
    /// neutral line, nothing recorded, and nothing asked again afterwards.
    func testEachRefusalEndsTheDisclosureWithNoRetry()async throws {
        for refusal in ["stale","storageFull","unwritable"] {
            let f=try fixture();try open(f)
            switch refusal {
            case "stale":let place=f.session.activity.place;f.session.enter(.reviewing(ReviewVisit(document:nil,draft:true,returnTo:place)))
            case "storageFull":f.controller.exercise?.snapshot.revision=TrainingState.maximumCount
            default:f.session.state.trainingRaw = .object([:])
            }
            await drain();XCTAssertTrue(f.voice.connected,refusal)
            let record=try encoded(f.session.state.training)
            ask(f);try call(f,"get_board","board")
            try await waitFor("\(refusal): the answer is cancelled"){f.events.contains{$0["type"] as? String=="response.cancel"}}
            done(f);XCTAssertEqual(scripts(f),[Line.cannotHelp.text],refusal)
            try spoken(f);try await waitFor("\(refusal): idle"){f.voice.turnIdle};await drain()
            XCTAssertNil(outputs(f)["board"],"\(refusal): no tool result");XCTAssertEqual(coaching(f).count,1,"\(refusal): nothing asked again")
            XCTAssertEqual(try encoded(f.session.state.training),record,"\(refusal): nothing recorded");XCTAssertFalse(f.exercise.snapshot.recordedHelp,refusal)
        }
        // `finished`: the attempt ended, so the disclosure is refused before anything is recorded or asked again.
        let f=try fixture();try open(f);let key=try XCTUnwrap(f.adapter.liveTicket?.key)
        XCTAssertTrue(f.controller.finish(f.exercise,.incorrect))
        XCTAssertThrowsError(try f.adapter.disclose([key])){XCTAssertEqual($0 as? TrainingVoiceAdapter.Stop,.refused(.finished))}
        await drain();XCTAssertFalse(f.voice.connected,"a finished game stops the coach");XCTAssertEqual(f.voice.status,Line.stopped.text)
        XCTAssertEqual(f.session.state.training?.attempts.last?.recordedHelp,false,"the finished attempt was never recorded as helped")
    }
    /// Only a thinking defender is waited for, and once: the answer is dropped with "One moment", asked again after the
    /// reply, and a second refusal while it still thinks ends it with nothing asked again.
    func testOnlyAThinkingDefenderIsWaitedForAndOnlyOnce()async throws {
        let f=try fixture();try open(f)
        ask(f);f.controller.games.thinking=true
        try call(f,"get_board","board");try await waitFor("the answer is cancelled"){f.events.contains{$0["type"] as? String=="response.cancel"}}
        done(f);XCTAssertEqual(scripts(f),[Line.moment.text]);XCTAssertNil(outputs(f)["board"]);XCTAssertFalse(recorded(f))
        try spoken(f);await drain()
        XCTAssertEqual(coaching(f).count,1,"held while the defender thinks");XCTAssertEqual(f.voice.status,Line.moment.text)
        f.controller.games.thinking=false;f.controller.objectWillChange.send();await drain()
        XCTAssertEqual(coaching(f).count,2,"asked again after the reply");XCTAssertTrue(coaching(f)[1].contains(VoiceCoach.trainingRegenerate))
        f.controller.games.thinking=true
        try call(f,"get_board","board-again");try await waitFor("the second answer is cancelled"){f.events.filter{$0["type"] as? String=="response.cancel"}.count==2}
        done(f);XCTAssertEqual(scripts(f),[Line.moment.text,Line.cannotHelp.text],"no second wait")
        try spoken(f);try await waitFor("idle"){f.voice.turnIdle}
        f.controller.games.thinking=false;f.controller.objectWillChange.send();await drain()
        XCTAssertEqual(coaching(f).count,2,"nothing survives the refusal");XCTAssertNil(outputs(f)["board-again"]);XCTAssertFalse(recorded(f))
        XCTAssertTrue(f.voice.connected,"waiting and refusing keep the session")
    }
    /// The neutral lines are this fixed list, and they need no help record: every script spoken in the refusals above is
    /// one of them while the attempt stays unhelped.
    func testNeutralLinesAreAFixedListThatNeedsNoRecord()async throws {
        XCTAssertEqual(Line.allCases.map(\.text),["One moment.","I can't help with this one.","The coach has stopped."])
        let f=try fixture();try open(f);f.session.state.trainingRaw = .object([:])
        ask(f);try call(f,"get_board","board");try await waitFor("cancelled"){f.events.contains{$0["type"] as? String=="response.cancel"}}
        done(f);try spoken(f);try await waitFor("idle"){f.voice.turnIdle}
        XCTAssertFalse(scripts(f).isEmpty);XCTAssertTrue(scripts(f).allSatisfy{Line(rawValue:$0) != nil},"\(scripts(f))");XCTAssertFalse(f.exercise.snapshot.recordedHelp)
        XCTAssertTrue(f.voice.history.filter{$0.role=="coach"}.allSatisfy{Line(rawValue:$0.text) != nil})
    }
    /// Every tool's payload, and everything sent to the provider, is free of the exercise's hints, explanation and any
    /// answer set; the practice game (a different board) is byte-identical after every tool; the real attempt is
    /// unchanged by a tried move.
    func testToolsCarryNoAnswersAndNeverTouchPracticeOrTheRealAttempt()async throws {
        let f=try fixture(practice:true)
        f.defender.analysis={_,rules in let best=rules.moves().map(\.uci).sorted().first;return EngineAnalysis(bestMove:best,lines:[AnalysisLine(depth:12,multiPv:1,score:AnalysisScore(kind:"mate",value:5),pv:[best ?? ""],san:["Qg2"])])}
        func practice()throws -> Data {try encoded(f.session.state.practice)+Data(f.session.rules.fen.utf8)+Data(f.session.rules.history.joined().utf8)+Data("\(f.session.highlights)\(f.session.arrows)\(f.session.preview==nil)\(f.session.demonstration==nil)".utf8)}
        let before=try practice();XCTAssertTrue(f.session.rules.fen.contains("4p3/4P3"),"practice holds its own game")
        try open(f);ask(f);try call(f,"get_board","get_board");try await waitFor("board"){self.outputs(f)["get_board"] != nil};done(f)
        XCTAssertEqual(try practice(),before,"get_board")
        let key=try XCTUnwrap(f.adapter.liveTicket?.key),line=f.exercise.line,attempt=try encoded(f.session.state.training?.active)
        let calls:[(String,[String:Any])]=[("analyze_position",["positionId":key]),("test_move",["positionId":key,"from":"g1","to":"g2"]),("test_move",["positionId":key,"from":"g1","to":"a8"]),("inspect_piece",["positionId":key,"square":"g1"]),("highlight_squares",["positionId":key,"squares":["g1","h8"],"arrows":[["g1","g7"]]])]
        for (index,(name,args)) in calls.enumerated() {
            let id="\(name)-\(index)";try call(f,name,id,args);try await waitFor(id){self.outputs(f)[id] != nil}
            XCTAssertFalse(outputs(f)[id]!.contains("\"error\""),"\(id): \(outputs(f)[id]!)")
            XCTAssertEqual(try practice(),before,"\(id): practice is untouched");XCTAssertEqual(f.exercise.line,line,"\(id): the real attempt is untouched")
            XCTAssertEqual(try encoded(f.session.state.training?.active),attempt,"\(id): nothing saved")
        }
        let tried=try object(outputs(f)["test_move-1"]);XCTAssertEqual(tried["hypothetical"] as? Bool,true);XCTAssertEqual((tried["defenderBest"] as? [String:Any])?["san"] as? String,"Kh7")
        XCTAssertEqual(try object(outputs(f)["test_move-2"])["legal"] as? Bool,false,"an illegal try is explained, not played")
        XCTAssertEqual(f.adapter.shownMarks?.squares,["g1","h8"]);XCTAssertTrue(f.session.highlights.isEmpty,"the coach's marks are the training board's own")
        let sent=f.events.compactMap{try? JSONSerialization.data(withJSONObject:$0)}.map{String(decoding:$0,as:UTF8.self)}.joined(separator:"\n")
        for secret in Self.secrets{XCTAssertFalse(sent.contains(secret),"\(secret) reached the provider")}
        for (id,output) in outputs(f) {for key in ["\"accepted\"","\"nodes\"","\"solution\"","\"hints\"","\"explanation\"","\"teaching\""]{XCTAssertFalse(output.contains(key),"\(id) carries \(key)")}}
    }
    /// Tools a training session does not offer are refused even when called directly, through the coach and the
    /// adapter alike, and nothing is recorded; the session is configured with exactly its own tools.
    func testOmittedToolsAreRefusedWhenCalledDirectly()async throws {
        let f=try fixture();try open(f);let key=try XCTUnwrap(f.adapter.liveTicket?.key)
        let configured=try XCTUnwrap(f.events.last{$0["type"] as? String=="session.update" && ($0["session"] as? [String:Any])?["tools"] != nil}?["session"] as? [String:Any])
        XCTAssertEqual(Set(((configured["tools"] as? [[String:Any]]) ?? []).compactMap{$0["name"] as? String}),VoiceCoach.trainingToolNames)
        XCTAssertFalse(VoiceCoach.trainingToolNames.contains("play_requested_move"))
        for name in ["play_requested_move","demonstrate_moves","control_demonstration","get_hint","preview_move","show_annotation","submit_training_action","request_training_hint"] {
            let refused=await code{try await f.voice.execute(name,args:["positionId":key,"from":"g1","to":"g2"],id:name)}
            XCTAssertEqual(refused,"ROLE_FORBIDDEN",name)
            let direct=await code{try await f.adapter.call(name,args:[:],key:key)};XCTAssertEqual(direct,"ROLE_FORBIDDEN",name)
        }
        XCTAssertFalse(f.exercise.snapshot.recordedHelp);XCTAssertFalse(recorded(f))
        // The adapter's own tools say nothing before the help record either.
        let early=await code{try await f.adapter.call("get_board",args:[:],key:key)};XCTAssertEqual(early,"UNAVAILABLE")
        // TrainingTools keeps refusing the voice coach, and practice voice keeps refusing training.
        XCTAssertThrowsError(try f.session.openVoice())
    }
    /// The defender has the shared engine first: a coaching search running when the defender starts is cancelled, and
    /// the answer waits for the reply, then is asked again.
    func testTheDefenderSearchesBeforeTheCoach()async throws {
        let engine=YieldingEngine(),f=try fixture(engine:engine);engine.failDefender=true
        f.controller.attempt(from:"g1",to:"g2",promotion:nil);await TrainingEndgameTests.settle(f.controller);XCTAssertNotNil(f.exercise.paused)
        engine.failDefender=false;try open(f)
        ask(f);try call(f,"get_board","board");try await waitFor("board"){self.outputs(f)["board"] != nil};done(f)
        try call(f,"analyze_position","analysis",["positionId":try XCTUnwrap(f.adapter.liveTicket?.key)])
        try await waitFor("the coaching search runs"){engine.log.contains("coach")}
        f.controller.retryDefender()
        try await waitFor("the coaching search is cancelled"){engine.log.contains("coach-cancelled")}
        await TrainingEndgameTests.settle(f.controller);await drain()
        XCTAssertEqual(f.exercise.line,["g1g2","h8h7"],"the defender replied");XCTAssertNil(outputs(f)["analysis"],"the cancelled search gave nothing")
        XCTAssertEqual(engine.log.filter{$0=="coach"}.count,1)
        // The cancellation is acknowledged; "One moment" is spoken unless the reply landed first and dropped the answer.
        done(f);if scripts(f).last==Line.moment.text{try spoken(f)};await drain()
        XCTAssertTrue(coaching(f).last?.contains(VoiceCoach.trainingRegenerate) ?? false,"the answer is asked again after the reply")
    }
    /// With `CHECKMATE_TRAINING_VOICE` off nothing changes: the adapter offers nothing, the coach cannot connect to a
    /// training game, and practice voice still refuses training.
    func testWithTheFlagOffNothingChanges()throws {
        unsetenv("CHECKMATE_TRAINING_VOICE")
        let f=try fixture()
        XCTAssertFalse(f.adapter.connectable);XCTAssertFalse(f.voice.trainingVoiceAvailable)
        f.voice.connectTraining();XCTAssertTrue(f.voice.connectRequests.isEmpty)
        XCTAssertThrowsError(try f.voice.automationOpen(greet:false,training:true));XCTAssertFalse(f.voice.trainingSession)
        XCTAssertThrowsError(try f.session.openVoice());XCTAssertFalse(f.exercise.snapshot.recordedHelp)
    }
}
/// An engine whose coaching searches (Stockfish at full strength for the coach's budget) wait until cancelled, and
/// whose defender searches answer at once, logging both.
@MainActor final class YieldingEngine:EngineService {
    var binaryIdentity:String {"yielding"}
    var capabilities:EngineCapabilities {EngineCapabilities()}
    var log:[String]=[],failDefender=false
    func prepare()async throws {}
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {throw CheckmateError.unavailable("history only")}
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
        if budget==TrainingVoiceAdapter.budget{log.append("coach");do{try await Task.sleep(for:.seconds(30))}catch{log.append("coach-cancelled");throw error};return EngineAnalysis()}
        log.append("defender");if failDefender{throw CheckmateError.unavailable("down")}
        let rules=try ChessRules(fen:startFEN);for move in moves{try rules.move(uci:move)}
        return EngineAnalysis(bestMove:rules.moves().map(\.uci).sorted().first)
    }
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int)async throws -> EngineAnalysis {
        guard case .movetime(let budget)=limit else{throw CheckmateError.unavailable("time only")};return try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:[])
    }
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
        guard case .movetime(let budget)=limit else{throw CheckmateError.unavailable("time only")};return try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:searchMoves)
    }
}
