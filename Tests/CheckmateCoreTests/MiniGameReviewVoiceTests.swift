import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// Plan D5: a finished mini-game's review, read aloud with a sign-in. Only its facts' exact text is spoken, through
/// script responses with no tools, microphone or conversation; never during play, never without facts, and any change
/// of review, sheet or place ends the reading. Silent: the voice double and `receive` stand in for the provider.
@MainActor final class MiniGameReviewVoiceTests:XCTestCase {
    struct Fixture {let session:GameSession,player:LearningPlayer,voice:VoiceCoach;var events:[[String:Any]] {box.events};let box:Box}
    final class Box {var events:[[String:Any]]=[]}
    static let fact="Move 1: you had a forced win in 1 move here."
    func fixture(library:Bool=false,facts:Bool=true)throws->Fixture {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session),voice=try VoiceCoach(session:session),box=Box()
        session.state.settings.pieceDuration=0;session.state.settings.voiceMicrophone=true
        session.state.miniGames=[MiniGameKind.rookSweep.rawValue:MiniGameReviewerTests.almostWon()]
        if library{player.startMini(.rookSweep,fromLibrary:true)}else{player.openLesson(index:try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="rook-practice"}));player.startMini(.rookSweep)}
        if !facts{player.miniReview.budget=0}
        voice.attachMiniReview(player.miniReview);voice.voiceDouble=true;voice.automationOutbound={box.events.append($0)}
        return Fixture(session:session,player:player,voice:voice,box:box)
    }
    func waitFor(_ what:String,_ condition:@escaping ()->Bool)async throws {for _ in 0..<200 {if condition(){return};try await Task.sleep(for:.milliseconds(20))};XCTFail(what)}
    func finish(_ f:Fixture)async throws {f.player.click("a1");f.player.click("a7");try await waitFor("the review is ready"){f.player.miniReview.review != nil && f.player.miniReview.sheetOpen}}
    func scripts(_ f:Fixture)->[[String:Any]] {f.events.compactMap{$0["type"] as? String=="response.create" ? $0["response"] as? [String:Any]:nil}}
    func code(_ body:() async throws -> Any) async -> String? {do{_ = try await body();return nil}catch{return (ProtocolErrors.failure(error)["error"] as? [String:Any])?["code"] as? String}}
    func segments(_ text:String,_ squares:[String])throws->[SpeechSegment] {try JSONDecoder().decode([SpeechSegment].self,from:JSONSerialization.data(withJSONObject:[["text":text,"squares":squares,"kind":"focus"]]))}

    func testReadAloudSpeaksOnlyTheFactsExactTextInBothOrigins()async throws {
        for library in [false,true] {
            let f=try fixture(library:library);defer{f.voice.disconnect();f.player.shutdown()}
            try await finish(f);XCTAssertTrue(f.voice.miniReviewReadable,"library \(library)")
            f.voice.readMiniReviewAloud();try await waitFor("the reading connects"){f.voice.connected};try await Task.sleep(for:.milliseconds(50))
            XCTAssertNotNil(f.voice.miniReviewSession);XCTAssertNotNil(f.session.voiceLease,"a lease scoped to the review")
            let configuration=try XCTUnwrap(f.events.first{$0["type"] as? String=="session.update"}?["session"] as? [String:Any])
            XCTAssertEqual((configuration["tools"] as? [Any])?.count,0,"no tools are offered")
            XCTAssertFalse((configuration["instructions"] as? String ?? "").contains("speak_explanation"),"no coach instructions")
            let requests=scripts(f);XCTAssertEqual(requests.count,1,"one script per fact, no greeting")
            XCTAssertEqual(requests.first?["conversation"] as? String,"none");XCTAssertEqual(requests.first?["tool_choice"] as? String,"none")
            XCTAssertTrue((requests.first?["instructions"] as? String ?? "").hasSuffix("SCRIPT:\n"+Self.fact),"the fact's exact text")
            f.voice.receive(["type":"response.output_audio_transcript.done","transcript":Self.fact]);f.voice.receive(["type":"response.done","response":["status":"completed"]])
            try await waitFor("the reading ends"){f.voice.turnIdle};XCTAssertEqual(scripts(f).count,1,"nothing follows the facts")
            XCTAssertEqual(f.voice.history.last?.text,Self.fact);XCTAssertEqual(f.voice.status,VoiceCoach.miniReviewReady)
            // No conversation: speech, a typed question and a recheck ask the model nothing; nothing is captured.
            f.voice.receive(["type":"input_audio_buffer.speech_started"]);f.voice.receive(["type":"input_audio_buffer.committed","item_id":"learner"])
            f.voice.ask("Was that a good move?");f.voice.recheck();try await Task.sleep(for:.milliseconds(50))
            XCTAssertEqual(scripts(f).count,1);XCTAssertFalse(f.voice.audio.capturing);XCTAssertFalse(f.voice.microphone)
            XCTAssertFalse(f.events.contains{$0["type"] as? String=="conversation.item.create"},"nothing enters a conversation")
            // Read Aloud again starts over from the first fact.
            f.voice.readMiniReviewAloud();XCTAssertEqual(scripts(f).count,2)
        }
    }
    func testInventedTextAndToolsAreRefused()async throws {
        let f=try fixture();defer{f.voice.disconnect();f.player.shutdown()}
        try await finish(f);f.voice.readMiniReviewAloud();try await waitFor("the reading connects"){f.voice.connected}
        try await Task.sleep(for:.milliseconds(50));f.voice.stopTurn(release:false);try await waitFor("the double acknowledges the stop"){f.voice.turnIdle}
        let squares=try XCTUnwrap(f.player.miniReview.review?.facts.first?.squares)
        for (text,cues) in [(Self.fact+" Well played!",squares),("White was winning all along.",[]),(Self.fact,["h8"])] {
            let refused=await code{try f.voice.narrateMiniReview(try self.segments(text,cues))}
            XCTAssertEqual(refused,"UNGROUNDED_REVIEW_SPEECH",text)
        }
        let empty=await code{try f.voice.narrateMiniReview([])};XCTAssertEqual(empty,"UNGROUNDED_REVIEW_SPEECH")
        let before=scripts(f).count
        XCTAssertNoThrow(try f.voice.narrateMiniReview(try segments(Self.fact,squares)),"a proved fact's exact text is accepted")
        XCTAssertEqual(scripts(f).count,before+1)
        for name in ["speak_explanation","get_board","highlight_squares"] {
            let refused=await code{try await f.voice.execute(name,args:["positionId":"mini-review","displayIdentity":"mini-review","segments":[["text":Self.fact,"squares":squares,"kind":"focus"]]],id:name)}
            XCTAssertEqual(refused,"ROLE_FORBIDDEN","\(name): a reading offers no tools")
        }
    }
    func testAnyChangeOfReviewSheetOrPlaceDisconnects()async throws {
        for change in ["close","restart","undo","leave","lesson","companion"] {
            let f=try fixture();defer{f.voice.disconnect();f.player.shutdown()}
            try await finish(f);f.voice.readMiniReviewAloud();try await waitFor("\(change): connected"){f.voice.connected}
            switch change {
            case "close":f.player.miniReview.dismissSheet()
            case "restart":f.player.restartMini()
            case "undo":f.player.undoMini()
            case "leave":f.player.leaveMini()
            case "lesson":f.player.openLesson(index:0)
            default:f.session.setConnection(enabled:true,role:"coach",lease:"mcp")
            }
            try await waitFor("\(change): the reading ends"){!f.voice.connected && f.voice.miniReviewSession==nil}
            XCTAssertNil(f.session.voiceLease,change);XCTAssertFalse(f.voice.miniReviewReadable,change)
        }
    }
    func testNotAvailableDuringPlayWithoutFactsOrWithoutASignIn()async throws {
        let play=try fixture();defer{play.player.shutdown()}
        XCTAssertNil(play.session.finishedMiniGameReview(),"nothing to read during play");XCTAssertFalse(play.voice.miniReviewReadable)
        play.voice.readMiniReviewAloud();XCTAssertTrue(play.voice.connectRequests.isEmpty);XCTAssertFalse(play.voice.connecting)
        XCTAssertThrowsError(try play.session.openVoice(),"voice stays refused during play")
        let none=try fixture(facts:false);defer{none.player.shutdown()}
        try await finish(none);XCTAssertEqual(none.player.miniReview.review?.facts.count,0)
        XCTAssertNil(none.session.finishedMiniGameReview());XCTAssertFalse(none.voice.miniReviewReadable,"no facts, nothing to read")
        none.voice.readMiniReviewAloud();XCTAssertTrue(none.voice.connectRequests.isEmpty)
        let signedOut=try fixture();defer{signedOut.player.shutdown()};signedOut.voice.voiceDouble=false
        try await finish(signedOut);XCTAssertNotNil(signedOut.session.finishedMiniGameReview())
        XCTAssertFalse(signedOut.voice.signInAvailable);XCTAssertFalse(signedOut.voice.miniReviewReadable,"without a sign-in the review stays text")
        signedOut.voice.readMiniReviewAloud();XCTAssertTrue(signedOut.voice.connectRequests.isEmpty)
    }
}
