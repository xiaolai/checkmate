import XCTest
import CryptoKit
@testable import CheckmateCore

/// Gap coverage for voice and MCP sessions: microphone problems and route changes (VC-11, VC-3, VC2-7), disconnect
/// hygiene and the watchdog (VC-4, VC-14), the opponent's wait event (VC2-5), the companion engine gate (VC2-4), the
/// SESSION_IN_USE explanations (VC2-2) and companion skill upgrades (VC-13, IR-13).
@MainActor final class GapVoiceMCPTests:XCTestCase {
    private let denied="Allow Checkmate in System Settings → Privacy & Security → Microphone."
    private func count(_ events:[[String:Any]],_ type:String)->Int {events.filter{$0["type"] as? String==type}.count}
    private func code(_ error:Error)->String? {(CompanionBroker.failure(error)["error"] as? [String:Any])?["code"] as? String}
    private func until(_ condition:()->Bool)async {for _ in 0..<2000 where !condition(){await Task.yield()}}
    /// A silently connected coach (quiet mode, so nothing is requested until the learner speaks).
    private func connected(microphone:Bool=true,mode:String="quiet",lease:Bool=true)throws -> (GameSession,VoiceCoach,() -> [[String:Any]]) {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode=mode;s.state.settings.voiceMicrophone=microphone
        let v=try VoiceCoach(session:s);v.settingsChanged();var events:[[String:Any]]=[];v.automationOutbound={events.append($0)}
        if lease{_ = try s.openVoice()};v.receive(["type":"session.updated"]);return (s,v,{events})
    }
    /// The coach's private response watchdog, read by reflection: its only other observable effect is a 45 s timeout.
    private func watchdog(_ v:VoiceCoach)->Task<Void,Never>? {
        guard let child=Mirror(reflecting:v).children.first(where:{$0.label=="timeout"}) else{XCTFail("VoiceCoach no longer stores its watchdog as `timeout`");return nil}
        return child.value as? Task<Void,Never>
    }

    // VC-11 and VC2-7: an input route change restarts the microphone; a permission problem keeps its own message
    // and never ends the session.
    func testInputRouteChangeKeepsTheSessionAndShowsTheSpecificMicrophoneProblem()async throws {
        let (_,v,_)=try connected();var starts=0;let message=denied
        v.automationCaptureStart={_ in starts+=1;throw CheckmateError.unavailable(message)}
        v.audio.onInputChanged?();await until{v.microphoneProblem != nil}
        XCTAssertEqual(starts,1,"A route change restarts capture");XCTAssertTrue(v.connected,"A microphone problem never ends the session")
        XCTAssertEqual(v.microphoneProblem,denied);XCTAssertEqual(v.status,"Ready — microphone unavailable. "+denied,"The specific fix is shown, not a generic message")
        v.automationCaptureStart={_ in starts+=1};v.audio.onInputChanged?();await until{v.microphoneProblem==nil}
        XCTAssertEqual(starts,2);XCTAssertNil(v.microphoneProblem,"A recovered route clears the problem");XCTAssertTrue(v.connected)
        v.disconnect();XCTAssertNil(v.microphoneProblem,"Disconnect clears the problem")
        v.audio.onInputChanged?();for _ in 0..<50{await Task.yield()};XCTAssertEqual(starts,2,"A disconnected coach never opens the microphone on a route change")
    }
    /// VC-11: a completed turn keeps the specific microphone fix on screen, not a generic "unavailable".
    func testTheSpecificMicrophoneProblemSurvivesACompletedTurn()async throws {
        let (_,v,_)=try connected();let message=denied;v.automationCaptureStart={_ in throw CheckmateError.unavailable(message)}
        v.audio.onInputChanged?();await until{v.microphoneProblem != nil};XCTAssertEqual(v.status,"Ready — microphone unavailable. "+denied)
        v.receive(["type":"input_audio_buffer.committed"]);v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertEqual(v.microphoneProblem,denied);XCTAssertEqual(v.status,"Ready — microphone unavailable. "+denied,"The fix stays visible after the coach answers");v.disconnect()
    }
    func testInputRouteChangeLeavesAMicrophoneTurnedOffAlone()async throws {
        let (_,v,_)=try connected(microphone:false);var starts=0;v.automationCaptureStart={_ in starts+=1}
        v.audio.onInputChanged?();for _ in 0..<50{await Task.yield()}
        XCTAssertEqual(starts,0);XCTAssertEqual(v.status,"Ready — microphone off");XCTAssertTrue(v.connected);v.disconnect()
    }
    func testChangingTheInputDeviceToADeniedMicrophoneKeepsTheSessionWithTheSpecificMessage()async throws {
        let (s,v,_)=try connected();let message=denied;v.automationCaptureStart={_ in throw CheckmateError.unavailable(message)}
        s.state.settings.voiceInputDevice="usb";v.settingsChanged();await until{v.microphoneProblem != nil}
        XCTAssertTrue(v.connected);XCTAssertEqual(v.status,"Ready — microphone unavailable. "+denied);v.disconnect()
    }

    // VC2-7: an output route change during a reply finishes that turn, so the coach never waits on lost audio.
    func testOutputRouteChangeDuringPlaybackFinishesTheTurn()async throws {
        let (s,v,events)=try connected(mode:"quiet")
        _ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":"Your pawn is on e2.","squares":["e2"],"kind":"observation"],["text":"Your king is on e1.","squares":["e1"],"kind":"observation"]]],id:"script")
        v.receive(["type":"response.done","response":["status":"completed"]])
        v.audio.onPlaybackStart?();XCTAssertEqual(s.voiceFocus,["e2"])
        v.receive(["type":"response.output_audio_transcript.done","response_id":"script","transcript":"Your pawn is on e2."]);v.receive(["type":"response.done","response":["status":"completed"]])
        let requests=count(events(),"response.create");XCTAssertEqual(v.status,"Speaking — microphone paused","Still waiting for the first segment's audio to end")
        v.audio.onOutputChanged?(false);XCTAssertEqual(count(events(),"response.create"),requests,"A route change with nothing playing changes nothing");XCTAssertEqual(s.voiceFocus,["e2"])
        v.audio.onOutputChanged?(true)
        XCTAssertEqual(count(events(),"response.create"),requests+1,"The interrupted segment ends and the next one is requested");XCTAssertTrue(v.connected);v.disconnect()
    }

    // VC-3: Test microphone is refused while voice holds the microphone, so it cannot stop the live capture.
    func testMicrophoneTestIsRefusedWhileVoiceIsConnected()async throws {
        let (_,v,_)=try connected();var starts=0;v.automationCaptureStart={_ in starts+=1};let before=v.status
        v.testMicrophone();for _ in 0..<50{await Task.yield()}
        XCTAssertEqual(starts,0);XCTAssertEqual(v.status,before,"No microphone test starts");XCTAssertTrue(v.connected);v.disconnect()
    }

    // VC-4: a tool result that finishes after disconnect is dropped, not sent into the closed (or a newer) session.
    func testAToolResultFinishingAfterDisconnectIsDropped()async throws {
        let (s,v,events)=try connected();v.receive(["type":"input_audio_buffer.committed"])
        v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"late","arguments":"{}"])
        v.disconnect();_ = try s.openVoice();v.receive(["type":"session.updated"])
        try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertFalse(events().contains{($0["item"] as? [String:Any])?["call_id"] as? String=="late"},"A pre-disconnect tool result never reaches the new session")
        v.disconnect()
    }
    // VC-14: disconnect releases the guided hold even without a lease, and forgets that the learner was speaking.
    func testDisconnectReleasesAHoldWithoutALease()throws {
        let (s,v,_)=try connected(mode:"guided",lease:false);XCTAssertNil(s.voiceLease);XCTAssertTrue(s.voiceHold,"Guided voice holds the opponent")
        v.disconnect();XCTAssertFalse(s.voiceHold,"A hold left without a lease is still released")
    }
    func testDisconnectForgetsTheLearnersSpokenTurn()async throws {
        let (s,v,_)=try connected();s.state.settings.voiceAssistMoves=true;v.receive(["type":"input_audio_buffer.committed"])
        v.disconnect();_ = try s.openVoice();v.receive(["type":"session.updated"])
        do{_ = try await v.execute("play_requested_move",args:["positionId":s.positionId,"from":"e2","to":"e4"],id:"stale");XCTFail("A spoken request from the old session played a move")}catch{XCTAssertEqual(code(error),"ROLE_FORBIDDEN")}
        XCTAssertTrue(s.rules.history.isEmpty)
        v.receive(["type":"input_audio_buffer.committed"])
        _ = try await v.execute("play_requested_move",args:["positionId":s.positionId,"from":"e2","to":"e4"],id:"fresh")
        XCTAssertEqual(s.rules.history.count,1,"A request spoken in this session is honoured");v.disconnect()
    }
    // VC-14: Stop during a reply re-arms the watchdog until the cancellation is confirmed; Stop when idle disarms it.
    func testStopDuringAReplyRearmsTheWatchdog()throws {
        let (_,v,events)=try connected();v.receive(["type":"input_audio_buffer.committed"]);XCTAssertEqual(count(events(),"response.create"),1)
        let replying=try XCTUnwrap(watchdog(v),"A request arms the watchdog");XCTAssertFalse(replying.isCancelled)
        v.stopTurn();XCTAssertEqual(count(events(),"response.cancel"),1)
        let stopping=try XCTUnwrap(watchdog(v),"Stop keeps a watchdog while the cancellation is unconfirmed")
        XCTAssertTrue(replying.isCancelled);XCTAssertNotEqual(stopping,replying,"A fresh 45 s window starts at Stop");XCTAssertFalse(stopping.isCancelled)
        v.receive(["type":"response.done","response":["status":"cancelled"]]);XCTAssertTrue(stopping.isCancelled,"The confirmed cancellation disarms it")
        XCTAssertTrue(v.connected);v.stopTurn();XCTAssertTrue(watchdog(v)?.isCancelled ?? true,"Stop when idle leaves no live watchdog");v.disconnect()
    }

    // VC2-5: the Opponent waits for its own turn with `opponent_turn`, on whichever side it plays.
    func testOpponentTurnWakesOnlyOnTheOpponentsTurn()async throws {
        let s=try GameSession(engine:nil),tools=try CompanionTools(session:s);s.state.settings.coachingMode="on_request";s.setConnection(enabled:true,role:"opponent",lease:"fixture")
        let waiter=Task{try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":s.cursor,"event":"opponent_turn","timeoutMs":3000],lease:"fixture") as! [String:Any]}
        try await Task.sleep(nanoseconds:20_000_000);s.emit();try await Task.sleep(nanoseconds:20_000_000)
        try s.playWhite(from:"e2",to:"e4")
        let started=Date(),woke=try await waiter.value
        XCTAssertEqual(woke["changed"] as? Bool,true);XCTAssertLessThan(Date().timeIntervalSince(started),1,"It wakes on the learner's move, not at the timeout")
        XCTAssertEqual((woke["state"] as? [String:Any])?["positionId"] as? String,s.positionId,"It woke after the move, not at the earlier change during the learner's turn")
        let learnerTurn=try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":s.cursor-1,"event":"learner_turn","timeoutMs":1],lease:"fixture") as! [String:Any]
        XCTAssertEqual(learnerTurn["changed"] as? Bool,false,"learner_turn is not the opponent's event")
    }
    func testOpponentTurnIgnoresChangesDuringTheLearnersTurn()async throws {
        let s=try GameSession(engine:nil),tools=try CompanionTools(session:s);s.setConnection(enabled:true,role:"opponent",lease:"fixture");let cursor=s.cursor;s.emit()
        let result=try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":cursor,"event":"opponent_turn","timeoutMs":150],lease:"fixture") as! [String:Any]
        XCTAssertEqual(result["changed"] as? Bool,false,"A change while the learner (White) is to move does not wake the opponent")
        let any=try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":cursor,"timeoutMs":150],lease:"fixture") as! [String:Any]
        XCTAssertEqual(any["changed"] as? Bool,true,"Control: the same change wakes `any`")
    }
    func testOpponentTurnFollowsTheLearnersSide()async throws {
        let s=try GameSession(engine:nil),tools=try CompanionTools(session:s);s.state.settings.practiceSide="b";s.setConnection(enabled:true,role:"opponent",lease:"fixture")
        XCTAssertEqual(s.opponentSide,"w");let cursor=s.cursor;s.emit()
        let result=try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":cursor,"event":"opponent_turn","timeoutMs":150],lease:"fixture") as! [String:Any]
        XCTAssertEqual(result["changed"] as? Bool,true,"With the learner on Black, White to move is the opponent's turn")
    }

    // VC2-4: one companion engine request at a time, and never while Stockfish chooses the opponent's move.
    @MainActor final class CountingEngine:EngineService {
        var active=0,peak=0,calls=0,gated=false,waiting:[CheckedContinuation<Void,Never>]=[]
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
            calls+=1;active+=1;peak=max(peak,active);defer{active-=1}
            if gated{await withCheckedContinuation{waiting.append($0)}}
            let move=try ChessRules(fen:fen).moves().first!;return EngineAnalysis(bestMove:move.uci,lines:[AnalysisLine(depth:1,multiPv:1,score:AnalysisScore(kind:"cp",value:0),pv:[move.uci],san:[])])
        }
        func releaseAll(){let all=waiting;waiting=[];all.forEach{$0.resume()}}
    }
    func testCompanionAnalysesNeverOverlapOnTheEngineAndTheOpponentStillReplies()async throws {
        let engine=CountingEngine(),s=try GameSession(engine:engine),tools=try CompanionTools(session:s)
        var settings=s.state.settings;settings.coachingMode="on_request";s.updateSettings(settings);s.setConnection(enabled:true,role:"coach",lease:"fixture")
        func analysis()->[String:Any] {["sessionId":s.sessionId,"revision":s.revision]}
        func preview()->[String:Any] {["sessionId":s.sessionId,"revision":s.revision,"from":"e2","to":"e4"]}
        engine.gated=true;let first=Task{try await tools.call("analyze_position",args:analysis(),lease:"fixture")}
        await until{engine.waiting.count==1};XCTAssertEqual(engine.waiting.count,1)
        /// Runs a call that must be refused; a call that reaches the gated engine instead fails and is released, never hangs.
        func refused(_ name:String,_ args:[String:Any])async {
            var outcome:String?;let reached=engine.calls
            let call=Task{do{_ = try await tools.call(name,args:args,lease:"fixture");outcome="returned"}catch{outcome=code(error) ?? "\(error)"}}
            await until{outcome != nil || engine.calls>reached}
            if engine.calls>reached{XCTFail("\(name) reached the engine while another search was running");engine.gated=false;engine.releaseAll()}
            await call.value;XCTAssertEqual(outcome,"BUSY",name)
        }
        for (name,args) in [("analyze_position",analysis()),("preview_move",preview()),("analyze_position",analysis())]{await refused(name,args);engine.gated=true}
        XCTAssertEqual(engine.calls,1,"Refused requests never reach the engine");engine.releaseAll();_ = try await first.value
        engine.gated=false;_ = try await tools.call("analyze_position",args:analysis(),lease:"fixture");XCTAssertEqual(engine.calls,2,"The gate reopens after a request finishes")
        engine.gated=true;try s.playWhite(from:"e2",to:"e4");await until{engine.waiting.count==1};XCTAssertEqual(s.busyReason,"opponent")
        await refused("analyze_position",analysis())
        engine.releaseAll();await until{s.rules.history.count==2}
        XCTAssertEqual(s.rules.history.count,2,"The opponent's reply completes");XCTAssertNil(s.error);XCTAssertEqual(engine.peak,1,"No two engine searches ever overlapped")
    }

    // VC2-2: SESSION_IN_USE says who holds the session and what to do, distinguishing voice from another Codex task.
    func testSessionInUseExplainsWhetherVoiceOrAnotherTaskHoldsTheSession()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let s=try GameSession(engine:nil),broker=try CompanionBroker(session:s,directory:directory);defer{broker.disable();try? FileManager.default.removeItem(at:directory)}
        _ = try s.openVoice();try broker.enable(role:"coach",standby:true)
        let file=directory.appendingPathComponent("connection.json");for _ in 0..<200{if FileManager.default.fileExists(atPath:file.path){break};try await Task.sleep(nanoseconds:10_000_000)}
        let d=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        func error(_ client:String)async throws -> [String:Any]? {
            var r=URLRequest(url:URL(string:(d["url"] as! String)+"/rpc")!);r.httpMethod="POST";r.setValue("Bearer "+(d["token"] as! String),forHTTPHeaderField:"Authorization");r.setValue(client,forHTTPHeaderField:"X-Checkmate-Client")
            r.httpBody=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":"get_session","args":[:]]);let (data,_)=try await URLSession.shared.data(for:r);return (try JSONSerialization.jsonObject(with:data) as! [String:Any])["error"] as? [String:Any]
        }
        let owner=UUID().uuidString,other=UUID().uuidString
        let voice=try await error(owner);XCTAssertEqual(voice?["code"] as? String,"SESSION_IN_USE")
        let voiceMessage=voice?["message"] as? String ?? "";XCTAssertTrue(voiceMessage.contains("voice coach is connected"),voiceMessage);XCTAssertTrue(voiceMessage.contains("disconnect voice in Checkmate"),voiceMessage);XCTAssertTrue(voiceMessage.contains("refused, not queued"),voiceMessage)
        s.closeVoice();let accepted=try await error(owner);XCTAssertNil(accepted)
        let task=try await error(other);XCTAssertEqual(task?["code"] as? String,"SESSION_IN_USE")
        let taskMessage=task?["message"] as? String ?? "";XCTAssertTrue(taskMessage.contains("Another Codex task is connected"),taskMessage);XCTAssertTrue(taskMessage.contains("one companion conversation at a time"),taskMessage)
        XCTAssertFalse(taskMessage.contains("voice"),"Another task is not blamed on voice")
    }

    // VC-13 and IR-13: Checkmate records the hash of the skill it wrote; only a copy matching that record is updated.
    private func home()throws -> URL {let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root}
    private let tool=URL(fileURLWithPath:"/usr/bin/true")
    private func folder(_ root:URL)->URL {CompanionInstallation.skillFolder(home:root)}
    private func hex(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func testTheMarkerRecordsTheHashOfTheSkillCheckmateWrote()throws {
        let root=try home(),v1=Data("v1 skill".utf8),v2=Data("v2 skill".utf8),marker=folder(root).appendingPathComponent(".checkmate-installed.sha256")
        try CompanionInstallation.register(executable:tool,codex:tool,skill:v1,home:root);XCTAssertEqual(try String(contentsOf:marker,encoding:.utf8),hex(v1))
        try CompanionInstallation.register(executable:tool,codex:tool,skill:v2,home:root);XCTAssertEqual(try String(contentsOf:marker,encoding:.utf8),hex(v2),"An update records the new hash, so the next upgrade is recognised too")
    }
    func testACurrentSkillIsLeftUntouched()throws {
        let root=try home(),skill=Data("v1 skill".utf8),file=folder(root).appendingPathComponent("SKILL.md")
        try CompanionInstallation.register(executable:tool,codex:tool,skill:skill,home:root)
        let before=try FileManager.default.attributesOfItem(atPath:file.path)[.systemFileNumber] as? Int
        XCTAssertEqual(try CompanionInstallation.register(executable:tool,codex:tool,skill:skill,home:root),.current)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.path)[.systemFileNumber] as? Int,before,"An atomic rewrite would replace the file; a current one is not rewritten")
    }
    func testAnUnrecordedOrMismatchedCopyIsTreatedAsTheLearners()throws {
        let root=try home(),file=folder(root).appendingPathComponent("SKILL.md"),marker=folder(root).appendingPathComponent(".checkmate-installed.sha256")
        try FileManager.default.createDirectory(at:folder(root),withIntermediateDirectories:true);try Data("old skill".utf8).write(to:file)
        XCTAssertEqual(CompanionInstallation.skillState(bundled:Data("new skill".utf8),home:root),.customized,"Without a record, the copy may hold the learner's edits")
        try Data(hex(Data("something else".utf8)).utf8).write(to:marker)
        XCTAssertEqual(try CompanionInstallation.register(executable:tool,codex:tool,skill:Data("new skill".utf8),home:root),.customized)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"old skill","A copy that differs from what Checkmate wrote is never overwritten")
        XCTAssertEqual(try CompanionInstallation.unregister(codex:tool,home:root,bundledSkill:Data("new skill".utf8)),.kept);XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        try Data((hex(Data("old skill".utf8))+"\n").utf8).write(to:marker)
        XCTAssertEqual(CompanionInstallation.skillState(bundled:Data("new skill".utf8),home:root),.outdated,"A matching record, even with a trailing newline, marks Checkmate's own older copy")
        XCTAssertEqual(try CompanionInstallation.unregister(codex:tool,home:root,bundledSkill:Data("new skill".utf8)),.removed,"Checkmate's own outdated copy is removed with the setup");XCTAssertFalse(FileManager.default.fileExists(atPath:folder(root).path))
    }
}
