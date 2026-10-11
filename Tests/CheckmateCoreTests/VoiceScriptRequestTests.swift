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

/// A recording is checked word for word, but the way a number is written is not a mismatch.
final class TranscriptNumberTests:XCTestCase {
    func testDigitsInAnyScriptAndSpelledOutNumbersMatch(){
        XCTAssertTrue(VoiceScriptRequest.matches("Der Läufer zieht nach e4.",script:"Der Läufer zieht nach e vier.",locale:"de"))
        XCTAssertTrue(VoiceScriptRequest.matches("الملك في المربع ٤",script:"الملك في المربع 4",locale:"ar"))
        XCTAssertTrue(VoiceScriptRequest.matches("ｅ４",script:"e4",locale:"en"))
        XCTAssertTrue(VoiceScriptRequest.matches("Le pion va en e quatre.",script:"Le pion va en e4.",locale:"fr"))
    }
    func testADifferentNumberOrWordStillFails(){
        XCTAssertFalse(VoiceScriptRequest.matches("Der Läufer zieht nach e fünf.",script:"Der Läufer zieht nach e4.",locale:"de"))
        XCTAssertFalse(VoiceScriptRequest.matches("Hallo. Der Läufer zieht nach e4.",script:"Der Läufer zieht nach e4.",locale:"de"))
        XCTAssertFalse(VoiceScriptRequest.matches("الملك في المربع ٥",script:"الملك في المربع 4",locale:"ar"))
    }
}
