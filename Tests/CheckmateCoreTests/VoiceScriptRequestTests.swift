import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform
import SaidGuard

final class VoiceScriptRequestTests:XCTestCase {
    func testScriptUsesIsolatedNoContextResponseAndKeepsScopeMetadata()throws {
        let event=VoiceScriptRequest.event(text:"Black moved the pawn to a6.",language:"English",metadata:["checkmate_turn":"12"]),response=event["response"] as! [String:Any]
        XCTAssertEqual(response["conversation"] as? String,"none");XCTAssertEqual((response["input"] as? [Any])?.count,0)
        XCTAssertEqual(response["tool_choice"] as? String,"none");XCTAssertEqual((response["metadata"] as? [String:String])?["checkmate_turn"],"12")
        XCTAssertTrue((response["instructions"] as? String)?.contains("Black moved the pawn to a6.")==true)
    }
    func testTranscriptMatchRejectsTranslationAddedWordsAndChangedSquares(){
        let script="Black moved the pawn from a7 to a6."
        XCTAssertTrue(saidMatches("Black moved the pawn from A7 to A6!",script,language:"en"))
        XCTAssertFalse(saidMatches("Hola. Black moved the pawn from a7 to a6.",script,language:"en"))
        XCTAssertFalse(saidMatches("Black moved the pawn from a7 to a5.",script,language:"en"))
        XCTAssertFalse(saidMatches("","",language:"en"))
    }
}

/// A recording is checked word for word, but the way a number is written is not a mismatch.
final class TranscriptNumberTests:XCTestCase {
    func testDigitsInAnyScriptAndSpelledOutNumbersMatch(){
        XCTAssertTrue(saidMatches("Der Läufer zieht nach e4.","Der Läufer zieht nach e vier.",language:"de"))
        XCTAssertTrue(saidMatches("الملك في المربع ٤","الملك في المربع 4",language:"ar"))
        XCTAssertTrue(saidMatches("ｅ４","e4",language:"en"))
        XCTAssertTrue(saidMatches("Le pion va en e quatre.","Le pion va en e4.",language:"fr"))
    }
    func testADifferentNumberOrWordStillFails(){
        XCTAssertFalse(saidMatches("Der Läufer zieht nach e fünf.","Der Läufer zieht nach e4.",language:"de"))
        XCTAssertFalse(saidMatches("Hallo. Der Läufer zieht nach e4.","Der Läufer zieht nach e4.",language:"de"))
        XCTAssertFalse(saidMatches("الملك في المربع ٥","الملك في المربع 4",language:"ar"))
    }
}
