import XCTest
@testable import CheckmateCore
final class VoiceScriptRequestTests:XCTestCase {
    func testScriptUsesIsolatedNoContextResponseAndKeepsScopeMetadata()throws {
        let event=VoiceScriptRequest.event(text:"Black moved the pawn to a6.",language:"English",metadata:["checkmate_turn":"12"]),response=event["response"] as! [String:Any]
        XCTAssertEqual(response["conversation"] as? String,"none");XCTAssertEqual((response["input"] as? [Any])?.count,0)
        XCTAssertEqual(response["tool_choice"] as? String,"none");XCTAssertEqual((response["metadata"] as? [String:String])?["checkmate_turn"],"12")
        XCTAssertTrue((response["instructions"] as? String)?.contains("Black moved the pawn to a6.")==true)
    }
    func testTranscriptMatchRejectsTranslationAddedWordsAndChangedSquares(){
        let script="Black moved the pawn from a7 to a6."
        XCTAssertTrue(VoiceScriptRequest.matches("Black moved the pawn from A7 to A6!",script:script))
        XCTAssertFalse(VoiceScriptRequest.matches("Hola. Black moved the pawn from a7 to a6.",script:script))
        XCTAssertFalse(VoiceScriptRequest.matches("Black moved the pawn from a7 to a5.",script:script))
        XCTAssertFalse(VoiceScriptRequest.matches("",script:""))
    }
}
