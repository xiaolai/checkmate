import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// LAN-play plan D8 and D15: while the learner plays or watches a network game, no engine help, cached evidence or
/// voice coaching reaches them, whether the work starts during the game or started before it and finishes after.
@MainActor final class NetworkFairnessTests:XCTestCase {
    /// Counts every engine call, and those made while participating; holds calls while `holding` is set.
    @MainActor final class CountingEngine:EngineService {
        var binaryIdentity:String {"counting-engine"}
        var capabilities:EngineCapabilities {EngineCapabilities()}
        var participation:NetworkParticipation?
        private(set) var calls=0,callsWhileParticipating=0
        /// Calls whose task had been cancelled by the time they returned: the engine would have stopped them.
        private(set) var cancelled=0
        var holding=false
        private var waiting:[CheckedContinuation<Void,Never>]=[]
        var held:Int {waiting.count}
        func prepare()async throws {record()}
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {try await analyzeHistory(startFEN:fen,moves:[],profile:.skill(skill),budget:budget,multiPv:multiPv,searchMoves:[])}
        func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
            record();if holding{await withCheckedContinuation{waiting.append($0)}}
            if Task.isCancelled {cancelled+=1}
            let rules=try ChessRules(fen:startFEN);for move in moves{try rules.move(uci:move)}
            let legal=searchMoves.isEmpty ? rules.moves().map(\.uci).sorted():searchMoves
            return EngineAnalysis(bestMove:legal.first,lines:legal.prefix(max(1,multiPv)).enumerated().map{AnalysisLine(depth:12,multiPv:$0.offset+1,score:AnalysisScore(kind:"cp",value:-$0.offset*5),pv:[$0.element],san:[])})
        }
        /// Searches given an explicit limit (assistance plan A5), their profiles and the positions they start from. Only
        /// the network assistant asks for a node limit.
        private(set) var limits:[EngineSearchLimit]=[],profiles:[OpponentProfile]=[],multiPvs:[Int]=[],startFENs:[String]=[]
        private(set) var nodeCallsWhileParticipating=0
        /// Calls made while participating by anything but a node-limited search, the network assistant's kind: always
        /// zero (A8). Which caller asked is the fairness inventory's to prove; this counts only what reached the engine.
        var otherCallsWhileParticipating:Int {callsWhileParticipating-nodeCallsWhileParticipating}
        /// Explicitly limited searches still to fail, one each, before they succeed again.
        var failures=0
        func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int)async throws -> EngineAnalysis {
            limits.append(limit);profiles.append(profile);multiPvs.append(multiPv);startFENs.append(startFEN)
            if failures>0 {failures-=1;record();throw CheckmateError.unavailable("ENGINE_UNAVAILABLE")}
            if case .nodes=limit,participation?.role != nil{nodeCallsWhileParticipating+=1}
            return try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:0,multiPv:multiPv,searchMoves:[])
        }
        private func record(){calls+=1;if participation?.role != nil{callsWhileParticipating+=1}}
        /// Lets the oldest held call finish; later ones stay held.
        func releaseFirst(){guard !waiting.isEmpty else{return};waiting.removeFirst().resume()}
        func releaseAll(){let all=waiting;waiting=[];all.forEach{$0.resume()}}
    }
    override func tearDown(){unsetenv("CHECKMATE_BEGINNER_OPPONENT_ENABLED")}
    private func code(_ error:Error)->String? {(ProtocolErrors.failure(error)["error"] as? [String:Any])?["code"] as? String}
    private func settle(_ done:@escaping ()->Bool,_ message:String)async throws {for _ in 0..<400 where !done(){try await Task.sleep(for:.milliseconds(5))};XCTAssertTrue(done(),message)}
    private func session(side:String="w",preset:String="custom")throws -> (GameSession,CountingEngine) {
        var state=ApplicationState();state.settings.practiceSide=side;state.settings.opponentPreset=preset
        let engine=CountingEngine(),session=try GameSession(engine:engine,state:state);engine.participation=session.fairness.participation;return (session,engine)
    }
    private func practiceBytes(_ session:GameSession)throws -> Data {let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;return try encoder.encode(session.state.practice)}
    private func refused(_ work:() async throws -> Void,_ what:String)async {do{try await work();XCTFail("\(what) ran during a network game")}catch{XCTAssertEqual(code(error),"NETWORK_GAME",what)}}

    // MARK: D9 — practice protection

    /// A Stockfish reply held across joining and leaving never lands: the saved practice game is byte-identical, and the
    /// engine is not asked anything while participating. After leaving, practice replies again.
    func testAReplyHeldAcrossJoiningAndLeavingLeavesThePracticeGameByteIdentical()async throws {
        for role in [NetworkParticipation.Role.player,.spectator] {
            let (session,engine)=try session();var saved:[Data]=[];session.onPersist={[weak session] _ in guard let session else{return};saved.append((try? self.practiceBytes(session)) ?? Data())}
            engine.holding=true;try session.playWhite(from:"e2",to:"e4")
            try await settle({engine.held==1},"the reply is asked for and held")
            let before=try practiceBytes(session),savedBefore=saved.count
            session.fairness.participation.begin(role)
            XCTAssertFalse(session.busy,"joining cancels the reply")
            session.fairness.participation.end()
            try await settle({engine.held==2},"leaving asks for a fresh reply, which is also held")
            engine.releaseFirst();try await Task.sleep(for:.milliseconds(50))
            XCTAssertEqual(try practiceBytes(session),before,"the stale reply did not change the practice game (\(role))")
            XCTAssertEqual(saved.last,before,"nothing else was saved over it");XCTAssertEqual(session.rules.history,["e4"])
            XCTAssertGreaterThanOrEqual(saved.count,savedBefore)
            XCTAssertEqual(engine.callsWhileParticipating,0)
            engine.holding=false;engine.releaseAll()
            try await settle({session.rules.history.count==2},"the fresh reply lands after leaving")
        }
    }

    // MARK: D8 — the entry-point table, as a player and as a spectator

    func testEveryEntryPointIsRefusedWhileParticipating()async throws {
        setenv("CHECKMATE_BEGINNER_OPPONENT_ENABLED","1",1)
        for role in [NetworkParticipation.Role.player,.spectator] {
            // Practice: Stockfish (to move as White here) does not move; hints, analysis, previews and voice are refused.
            let (blackSide,blackEngine)=try session(side:"b")
            blackSide.fairness.participation.begin(role)
            blackSide.reply();try await Task.sleep(for:.milliseconds(20))
            XCTAssertEqual(blackEngine.calls,0,"no reply while participating (\(role))");XCTAssertTrue(blackSide.rules.history.isEmpty)
            await refused({_ = try await blackSide.chooseOpponentMove(engine:blackEngine)},"chooseOpponentMove")
            await refused({_ = try blackSide.commitBlack("e2e4")},"commitBlack")
            let (s,engine)=try session()
            s.fairness.participation.begin(role)
            s.hint();XCTAssertFalse(s.busy,"no hint while participating");XCTAssertEqual(engine.calls,0)
            await refused({_ = try await s.analyze()},"analyze")
            await refused({_ = try await s.evaluateCandidate(from:"e2",to:"e4")},"evaluateCandidate")
            await refused({try await s.testMove(from:"e2",to:"e4")},"testMove")
            await refused({_ = try s.openVoice()},"openVoice")
            // MCP: refused before any request-ID receipt; reading the session still works.
            let tools=try CompanionTools(session:s);s.setConnection(enabled:true,role:"coach",lease:"fixture")
            for (name,args) in [("get_legal_moves",["sessionId":s.sessionId,"revision":s.revision] as [String:Any]),("analyze_position",["sessionId":s.sessionId,"revision":s.revision]),("preview_move",["sessionId":s.sessionId,"revision":s.revision,"from":"e2","to":"e4"]),("get_turn_brief",[:])] {
                await refused({_ = try await tools.call(name,args:args,lease:"fixture")},name)
            }
            let state=try await tools.call("get_session",args:[:],lease:"fixture") as! [String:Any]
            XCTAssertEqual(state["mode"] as? String,"network")
            // Review: no search, batch or cached evidence; the controller does not even start one.
            let review=ReviewController();review.fairness=s.fairness
            let analyzer=ReviewAnalyzer(engine:engine,fairness:s.fairness),document=try XCTUnwrap(PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8)).first)
            await refused({_ = try await analyzer.analyze(document:document,node:1,revision:0)},"ReviewAnalyzer.analyze")
            await refused({_ = try await analyzer.analyzeBranch(document:document,root:1,moves:["e7e5"],revision:0)},"ReviewAnalyzer.analyzeBranch")
            analyzer.startBatch(document);XCTAssertEqual(analyzer.batchStatus,"idle","no whole-game analysis")
            review.load(document);review.analyze(using:analyzer);XCTAssertEqual(review.analysisStatus,"idle")
            // Lesson exercises and training: their controllers refuse before any engine call.
            let lesson=try LessonAttemptController(session:s);lesson.replyDelay={.zero}
            // Authored hints are the lesson's own words, not engine output; only the computer's reply needs the engine.
            lesson.open(lessonID:"test",practice:try castling());lesson.click("e1");lesson.click("g1");lesson.playOn();try await Task.sleep(for:.milliseconds(30))
            XCTAssertEqual(lesson.record?.moves,["e1g1"],"the lesson's computer does not reply")
            // Voice: the coach does not connect.
            let voice=try VoiceCoach(session:s);voice.connect();XCTAssertEqual(voice.status,VoiceCoach.networkGameStatus)
            XCTAssertEqual(engine.calls,0,"nothing reached the engine (\(role))");XCTAssertEqual(blackEngine.callsWhileParticipating+engine.callsWhileParticipating,0)
        }
    }

    /// Training's defender: a reply asked for before joining is dropped when it arrives; none is asked while participating.
    func testTrainingDefenderRepliesAreDroppedAndRefused()async throws {
        setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1);defer{unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
        let defender=ScriptedDefender();defender.holding=true
        let (session,player,controller)=try TrainingEndgameTests.fixture([TrainingEndgameTests.ending("8/8/8/8/K7/3Q4/8/k7 w - - 0 1")],defender:defender);defer{player.shutdown()}
        controller.games.fairness=session.fairness
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d3",to:"d2",promotion:nil);try await settle({defender.requests.count==1},"the defender is asked")
        session.fairness.participation.begin(.player)
        defender.release();try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(controller.exercise?.line,["d3d2"],"the reply that arrived after joining did not land")
        controller.games.cancel();controller.requestReply();XCTAssertEqual(defender.requests.count,1,"no reply is asked for while participating")
    }

    /// R5-2: MCP play_move with the beginner opponent. Its first search is held, participation begins, and the result
    /// that would lead to exploration arrives: no further engine call, no result delivered, no practice change.
    func testBeginnerPlayMoveStopsExploringWhenParticipationBegins()async throws {
        setenv("CHECKMATE_BEGINNER_OPPONENT_ENABLED","1",1)
        let (s,engine)=try session(side:"b",preset:"first_steps");XCTAssertEqual(OpponentProfile.settings(s.state.settings).mode,"beginner")
        let tools=try CompanionTools(session:s);s.setConnection(enabled:true,role:"opponent",lease:"fixture")
        // The first choice saves the game as it stands (and its new opponent seed): the baseline is that saved game.
        s.emit(semantic:false,save:true);engine.holding=true;let before=try practiceBytes(s)
        let call=Task{try await tools.call("play_move",args:["sessionId":s.sessionId,"revision":s.revision,"requestId":"one"],lease:"fixture")}
        try await settle({engine.held==1},"the root search is held")
        s.fairness.participation.begin(.player);engine.holding=false;engine.releaseAll()
        do{_ = try await call.value;XCTFail("play_move delivered a move")}catch{XCTAssertEqual(code(error),"NETWORK_GAME")}
        XCTAssertEqual(engine.calls,1,"no exploration search after joining");XCTAssertEqual(engine.callsWhileParticipating,0)
        XCTAssertEqual(try practiceBytes(s),before);XCTAssertTrue(s.rules.history.isEmpty)
    }

    /// The same for Stockfish's own reply in practice, with the beginner opponent.
    func testBeginnerNativeReplyStopsExploringWhenParticipationBegins()async throws {
        setenv("CHECKMATE_BEGINNER_OPPONENT_ENABLED","1",1)
        let (s,engine)=try session(side:"b",preset:"first_steps")
        s.emit(semantic:false,save:true);engine.holding=true;let before=try practiceBytes(s);s.reply()
        try await settle({engine.held==1},"the root search is held")
        s.fairness.participation.begin(.spectator);engine.holding=false;engine.releaseAll();try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(engine.calls,1,"no exploration search after joining");XCTAssertEqual(try practiceBytes(s),before);XCTAssertTrue(s.rules.history.isEmpty)
    }

    /// Work in flight when joining: a hint, a review analysis and a lesson hint all deliver nothing.
    func testWorkStartedBeforeJoiningDeliversNothing()async throws {
        let (s,engine)=try session();engine.holding=true
        s.hint();try await settle({engine.held==1},"the hint is held")
        let analyzer=ReviewAnalyzer(engine:engine,fairness:s.fairness),document=try XCTUnwrap(PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8)).first)
        let review=Task{try await analyzer.analyze(document:document,node:1,revision:0)}
        try await settle({engine.held==2},"the review search is held")
        s.fairness.participation.begin(.player);engine.holding=false;engine.releaseAll()
        do{_ = try await review.value;XCTFail("cached or fresh evidence was delivered")}catch{XCTAssertEqual(code(error),"NETWORK_GAME")}
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertNotEqual(s.coaching.status,"ready");XCTAssertNil(s.coaching.recommendation);XCTAssertTrue(s.arrows.isEmpty)
        // A cached result is withheld too: compute it after leaving, then ask again while participating.
        s.fairness.participation.end();_ = try await analyzer.analyze(document:document,node:1,revision:0)
        s.fairness.participation.begin(.spectator);let calls=engine.calls
        do{_ = try await analyzer.analyze(document:document,node:1,revision:0);XCTFail("cached evidence was handed out")}catch{XCTAssertEqual(code(error),"NETWORK_GAME")}
        XCTAssertEqual(engine.calls,calls)
    }

    /// The table's remaining rows, as a player and as a spectator: a whole-game review analysis running when the learner
    /// joins is cancelled and delivers nothing; an MCP answer computed before joining is not handed out again for its
    /// request ID; and the review analysis tools are refused.
    func testReviewBatchesReceiptsAndReviewToolsAreStoppedOnJoining()async throws {
        for role in [NetworkParticipation.Role.player,.spectator] {
            let (s,engine)=try session()
            let analyzer=ReviewAnalyzer(engine:engine,fairness:s.fairness),document=try XCTUnwrap(PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8)).first)
            engine.holding=true;analyzer.startBatch(document)
            try await settle({engine.held>=1},"the batch's first search is held")
            s.fairness.participation.begin(role)
            XCTAssertEqual(analyzer.batchStatus,"cancelled","joining cancels the batch (\(role))")
            engine.holding=false;engine.releaseAll();try await Task.sleep(for:.milliseconds(50))
            XCTAssertTrue(analyzer.moments.isEmpty);XCTAssertTrue(analyzer.evaluations.isEmpty);XCTAssertEqual(engine.callsWhileParticipating,0)
            s.fairness.participation.end()
            let tools=try CompanionTools(session:s);s.setConnection(enabled:true,role:"coach",lease:"fixture")
            let args:[String:Any]=["sessionId":s.sessionId,"revision":s.revision,"requestId":"before-joining","positionId":s.positionId]
            _ = try await tools.call("clear_annotations",args:args,lease:"fixture")
            s.fairness.participation.begin(role)
            await refused({_ = try await tools.call("clear_annotations",args:args,lease:"fixture")},"a receipt from before joining")
            let review:[String:Any]=["sessionId":s.sessionId,"revision":s.revision,"documentId":document.id.uuidString,"reviewRevision":0,"nodeId":1]
            await refused({_ = try await tools.call("analyze_review",args:review,lease:"fixture")},"analyze_review")
            await refused({_ = try await tools.call("get_review_analysis",args:review.merging(["jobId":"job"]){$1},lease:"fixture")},"get_review_analysis")
            s.fairness.participation.end()
        }
    }

    /// The voice rows, as a player and as a spectator: a coach turn running when the learner joins is stopped and the
    /// coach disconnects; afterwards asking, rechecking, narrating a review and committed speech start nothing, and a
    /// tool call refuses.
    func testVoiceTurnsStopOnJoiningAndNothingStartsWhileParticipating()async throws {
        for role in [NetworkParticipation.Role.player,.spectator] {
            let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet"
            let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)}
            _ = try s.openVoice();v.receive(["type":"session.updated"])
            let responses={events.filter{$0["type"] as? String=="response.create"}.count}
            v.ask("Why did my pawn move?");XCTAssertEqual(responses(),1,"a turn is running")
            s.fairness.participation.begin(role)
            XCTAssertFalse(v.connected,"joining disconnects the coach (\(role))");XCTAssertNil(s.voiceLease)
            let before=responses()
            v.receive(["type":"response.done","response":["status":"completed"]]);v.receive(["type":"input_audio_buffer.committed"])
            v.ask("And now?");v.recheck();v.narrateReview()
            XCTAssertEqual(responses(),before,"nothing starts while participating (\(role))")
            do{_ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":"Your pawn is on e2.","squares":["e2"],"kind":"observation"]]],id:"late");XCTFail("speak_explanation ran during a network game")}catch{}
            v.connect();XCTAssertEqual(v.status,VoiceCoach.networkGameStatus)
            s.fairness.participation.end()
        }
    }
    /// The review tools' own guard, behind the dispatcher's: engine evidence is refused even when called directly.
    func testReviewToolsRefuseEngineEvidenceThemselves()async throws {
        let (s,engine)=try session()
        let review=ReviewController(),document=try XCTUnwrap(PGNImporter.parse(Data("1. e4 e5 *".utf8)).first)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("checkmate-fairness-\(UUID().uuidString)");defer{try? FileManager.default.removeItem(at:root)}
        let tools=ReviewTools(review:review,session:s,store:ReviewStore(directory:root),analyzer:ReviewAnalyzer(engine:engine,fairness:s.fairness))
        review.load(document);s.fairness.participation.begin(.spectator)
        let identity:[String:Any]=["documentId":document.id.uuidString,"reviewRevision":review.revision,"nodeId":review.nodeID]
        await refused({_ = try await tools.call("analyze_review",args:identity)},"ReviewTools analyze_review")
        await refused({_ = try await tools.call("get_review_analysis",args:identity.merging(["jobId":"job"]){$1})},"ReviewTools get_review_analysis")
        XCTAssertEqual(engine.calls,0)
    }

    /// Joining stops a review search already running for one position or a branch, not only the whole-game batch.
    func testJoiningCancelsReviewSearchesInFlight()async throws {
        let (s,engine)=try session();engine.holding=true
        let analyzer=ReviewAnalyzer(engine:engine,fairness:s.fairness),document=try XCTUnwrap(PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8)).first)
        let position=Task{try await analyzer.analyze(document:document,node:1,revision:0)}
        try await settle({engine.held==1},"the position search is held")
        let branch=Task{try await analyzer.analyzeBranch(document:document,root:1,moves:["e7e5"],revision:0)}
        try await settle({engine.held==2},"the branch search is held")
        s.fairness.participation.begin(.player);engine.holding=false;engine.releaseAll()
        for task in [position,branch] {do{_ = try await task.value;XCTFail("a search delivered during a network game")}catch{XCTAssertEqual(code(error),"NETWORK_GAME","the readable reason, not a bare cancellation")}}
        XCTAssertEqual(engine.cancelled,2,"both searches were cancelled on joining")
    }

    // MARK: D15 — the MCP projection

    /// The exact `get_session` object while participating, a changed wait, a timed-out wait, a filtered wait woken by
    /// both transitions, and the first state after leaving.
    func testMCPProjectionWhileParticipating()async throws {
        let (s,_)=try session();let tools=try CompanionTools(session:s);s.setConnection(enabled:true,role:"coach",lease:"fixture")
        let practice=try await tools.call("get_session",args:[:],lease:"fixture") as! [String:Any]
        // A wait filtered to the learner's turn, started before joining, wakes on the transition itself.
        let waiting=Task{try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":s.cursor,"event":"learner_turn","timeoutMs":5000],lease:"fixture") as! [String:Any]}
        try await Task.sleep(for:.milliseconds(30));s.fairness.participation.begin(.player)
        let woken=try await waiting.value
        let golden:[String:Any]=["schemaVersion":1,"sessionId":s.sessionId,"revision":s.revision,"positionId":s.positionId,"cursor":s.cursor,"mode":"network","capabilities":[String](),"display":["activeView":"network","fen":NSNull(),"identity":"network"],"learnerSide":"w","state":NSNull(),"controller":["enabled":true,"role":"coach","connected":true,"suspended":false,"paused":true,"pauseReason":"network_game"]]
        let current=try await tools.call("get_session",args:[:],lease:"fixture") as! [String:Any]
        XCTAssertEqual(NSDictionary(dictionary:current),NSDictionary(dictionary:golden),"get_session")
        XCTAssertEqual(NSDictionary(dictionary:woken),NSDictionary(dictionary:["changed":true,"resyncRequired":false,"state":golden]),"the filtered wait woke on joining")
        let timedOut=try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":s.cursor,"timeoutMs":30],lease:"fixture") as! [String:Any]
        XCTAssertEqual(NSDictionary(dictionary:timedOut),NSDictionary(dictionary:["changed":false,"state":golden]),"a timed-out wait")
        // A wait from before joining, still filtered, also sees leaving; the first state after is practice again.
        let leaving=Task{try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":s.cursor,"event":"opponent_turn","timeoutMs":5000],lease:"fixture") as! [String:Any]}
        try await Task.sleep(for:.milliseconds(30));s.fairness.participation.end()
        let after=try await leaving.value
        XCTAssertEqual(after["changed"] as? Bool,true);XCTAssertEqual(after["resyncRequired"] as? Bool,false)
        // Joining cleared any coaching marks, which advances the overlay revision; nothing else differs.
        var expected=practice;expected["cursor"]=s.cursor;expected["overlayRevision"]=s.overlayRevision
        XCTAssertEqual(s.overlayRevision,(practice["overlayRevision"] as! Int)+1)
        XCTAssertEqual(NSDictionary(dictionary:after["state"] as! [String:Any]),NSDictionary(dictionary:expected),"the first state after leaving is the practice projection, changed only in its cursor and overlay revision")
        // A review opened mid-game is redacted too: redaction comes before the review branch.
        s.fairness.participation.begin(.spectator);let review=ReviewController();review.fairness=s.fairness;s.reviewController=review
        review.load(try XCTUnwrap(PGNImporter.parse(Data("1. e4 *".utf8)).first));s.enterReview(document:review.document!.id)
        let redacted=try await tools.call("get_session",args:[:],lease:"fixture") as! [String:Any]
        XCTAssertEqual(redacted["mode"] as? String,"network")
    }

    // MARK: Fixtures

    private let castleFEN="4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1"
    private func castling()throws -> LessonPractice {
        let rules=try ChessRules(fen:castleFEN)
        return LessonPractice(fen:castleFEN,goal:"Castle kingside.",beat:"test:0",teaching:[LessonTeachingNode(fingerprint:LessonAttemptJudge.fingerprint(rules.fen),accepted:["e1g1"])],checkpoints:[.init(kind:.castle,label:"Castle kingside")],opponent:.beginner,hints:["Tuck the king away.","Look at the king and the h1 rook."],offTrack:"Castle instead.",mistakes:[:],success:"You castled.")
    }
}
