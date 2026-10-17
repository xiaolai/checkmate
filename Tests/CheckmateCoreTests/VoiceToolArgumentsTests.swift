import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// A tool call whose streamed arguments can no longer be valid ends its turn at once, instead of streaming until the
/// turn timeout; ordinary calls are untouched. Driven only through the silent hooks: no network, no audio.
@MainActor final class VoiceToolArgumentsTests:XCTestCase {
    private func connected()throws -> (GameSession,VoiceCoach,() -> [[String:Any]]) {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet"
        let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)}
        _ = try s.openVoice();v.receive(["type":"session.updated"]);XCTAssertTrue(v.connected,"fixture: the silent session did not become ready")
        return (s,v,{events})
    }
    /// Starts a learner turn and the response that answers it, as the service would.
    private func respond(_ v:VoiceCoach,_ events:() -> [[String:Any]],id:String="resp-1"){
        v.receive(["type":"input_audio_buffer.committed"])
        let turn=(events().last{$0["type"] as? String=="response.create"}?["response"] as? [String:Any]).flatMap{($0["metadata"] as? [String:String])?["checkmate_turn"]} ?? ""
        v.receive(["type":"response.created","response":["id":id,"metadata":["checkmate_turn":turn]]])
    }
    private func call(_ v:VoiceCoach,_ name:String,id:String="call-1",response:String="resp-1"){v.receive(["type":"response.output_item.added","response_id":response,"item":["type":"function_call","name":name,"call_id":id,"arguments":""]])}
    private func delta(_ v:VoiceCoach,_ text:String,id:String="call-1",response:String="resp-1"){v.receive(["type":"response.function_call_arguments.delta","response_id":response,"call_id":id,"delta":text])}
    private func outputs(_ events:[[String:Any]])->[String] {events.filter{($0["item"] as? [String:Any])?["type"] as? String=="function_call_output"}.compactMap{($0["item"] as? [String:Any])?["output"] as? String}}
    private func cancels(_ events:[[String:Any]])->Int {events.filter{$0["type"] as? String=="response.cancel"}.count}
    private func until(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<200{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};XCTFail("timed out waiting for \(what)")}
    private var definitions:[[String:Any]] {get throws {try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("voice-tools.json"))) as! [[String:Any]]}}

    /// Every tool the coach is offered, practice and network, has a finite bound below the whole-call cap, so a
    /// runaway in any of them is caught at its own size.
    func testEveryOfferedToolHasABound()throws {
        let tools=try definitions+VoiceCoach.networkTools(try definitions)
        for tool in tools {
            let name=tool["name"] as! String,limit=VoiceToolArguments.limit(schema:tool["parameters"] as! [String:Any])
            XCTAssertNotNil(limit,"\(name) has a string or array without a bound")
            if name != "demonstrate_moves"{XCTAssertLessThan(limit ?? .max,VoiceToolArguments.maximumBytes,name)}
        }
    }
    /// The largest valid speech, pretty-printed and in characters JSON must escape, still fits its bound: no
    /// legitimate call is cut.
    func testTheLargestValidSpeechFits()throws {
        let schema=try definitions.first{$0["name"] as? String=="speak_explanation"}!["parameters"] as! [String:Any]
        let limit=try XCTUnwrap(VoiceToolArguments.limit(schema:schema))
        let segment:[String:Any]=["text":String(repeating:"\"\\\u{1}",count:133)+"\"","squares":["a1","b2","c3","d4"],"kind":"possibility"]
        let speech:[String:Any]=["positionId":String(repeating:"\"",count:100),"displayIdentity":String(repeating:"\u{1}",count:300),"segments":Array(repeating:segment,count:4)]
        XCTAssertTrue(try ToolSchemas.validateValue(speech,schema:schema) is [String:Any],"fixture: the speech is valid")
        for options:JSONSerialization.WritingOptions in [[],[.prettyPrinted,.sortedKeys]] {
            let text=String(decoding:try JSONSerialization.data(withJSONObject:speech,options:options),as:UTF8.self)
            var arguments=VoiceToolArguments(limit:limit);for piece in text.chunked(3){arguments.append(piece)}
            XCTAssertTrue(arguments.withinBounds,"\(text.utf8.count) bytes against a bound of \(limit)")
        }
    }
    /// Whitespace inside strings is speech; outside them it is insignificant, and an unending run of it is a runaway.
    func testWhitespaceCountsOnlyOutsideStrings(){
        var speech=VoiceToolArguments();speech.append("{\"text\":\"");speech.append(String(repeating:" ",count:5000));speech.append("\\\" \"}")
        XCTAssertTrue(speech.withinBounds);XCTAssertEqual(speech.whitespace,0)
        var runaway=VoiceToolArguments();runaway.append("{\"segments\":[")
        for _ in 0..<VoiceToolArguments.maximumWhitespace{runaway.append("\n")};XCTAssertTrue(runaway.withinBounds,"at the allowance itself")
        runaway.append("\n");XCTAssertFalse(runaway.withinBounds)
    }
    /// The defect: the service streamed a speech's arguments until the 45 s timeout. Now the turn ends as soon as the
    /// call passes its bound: the response is cancelled, the call never runs, and the session stays up.
    func testARunawaySpeechEndsItsTurnAtOnce()async throws {
        // Whitespace forever between fields, and one segment's text repeating forever inside its string.
        for (prefix,runaway) in [("","\n"),("\"segments\":[{\"text\":\"","again and again ")] {
            let (_,v,events)=try connected();defer{v.disconnect()}
            respond(v,events);call(v,"speak_explanation");delta(v,"{\"positionId\":\"x\","+prefix)
            let limit=v.argumentLimit("speak_explanation");var sent=0
            XCTAssertLessThan(limit,VoiceToolArguments.maximumBytes,"fixture: speech has its own bound")
            while cancels(events())==0 && sent<20000 {delta(v,runaway);sent+=1}
            XCTAssertEqual(cancels(events()),1,"\(runaway.debugDescription): the response is cancelled")
            XCTAssertLessThanOrEqual(sent*runaway.utf8.count,max(limit,2*VoiceToolArguments.maximumWhitespace)+runaway.utf8.count,"cut at its bound, not later")
            // The rest of the stream and its end are ignored: the call never runs.
            delta(v,"\"}");v.receive(["type":"response.function_call_arguments.done","response_id":"resp-1","name":"speak_explanation","call_id":"call-1","arguments":"{}"])
            try await Task.sleep(nanoseconds:50_000_000)
            XCTAssertTrue(outputs(events()).isEmpty,"no tool result for a cut call");XCTAssertTrue(v.connected,"only the turn ends")
            v.receive(["type":"response.done","response":["id":"resp-1","status":"cancelled"]])
            XCTAssertEqual(v.status,VoiceCoach.turnFailure,"the turn ends with the failure message");XCTAssertFalse(v.canStopTurn)
        }
    }
    /// A call streamed in ordinary pieces runs exactly as before.
    func testAnOrdinaryStreamedCallRuns()async throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        respond(v,events);call(v,"get_board")
        for piece in ["{","}"]{delta(v,piece)}
        v.receive(["type":"response.function_call_arguments.done","response_id":"resp-1","name":"get_board","call_id":"call-1","arguments":"{}"])
        try await until("the board result"){outputs(events()).count==1}
        XCTAssertEqual(cancels(events()),0);XCTAssertNotEqual(v.status,VoiceCoach.turnFailure)
    }
    /// Finished arguments that are not a JSON object are answered as invalid, so the coach can correct its call; they
    /// were dropped silently, which left the turn to time out.
    func testUnreadableArgumentsAreAnswered()async throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        respond(v,events);v.receive(["type":"response.function_call_arguments.done","response_id":"resp-1","name":"get_board","call_id":"call-1","arguments":"{\"unterminated"])
        try await until("an answer"){outputs(events()).count==1}
        XCTAssertTrue(outputs(events())[0].contains("INVALID_ARGUMENT"),outputs(events())[0])
    }
    /// Finished arguments over the whole-call cap end the turn at once, as they always should have.
    func testOversizeFinishedArgumentsEndTheTurn()throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        respond(v,events);v.receive(["type":"response.function_call_arguments.done","response_id":"resp-1","name":"get_board","call_id":"call-1","arguments":"{\"x\":\""+String(repeating:"a",count:VoiceToolArguments.maximumBytes)+"\"}"])
        XCTAssertEqual(cancels(events()),1,"the response is cancelled at once");XCTAssertTrue(outputs(events()).isEmpty)
        v.receive(["type":"response.done","response":["id":"resp-1","status":"cancelled"]]);XCTAssertEqual(v.status,VoiceCoach.turnFailure)
    }
}
private extension String {
    func chunked(_ size:Int)->[String] {var pieces:[String]=[],rest=Substring(self);while !rest.isEmpty{pieces.append(String(rest.prefix(size)));rest=rest.dropFirst(size)};return pieces}
}
