import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// Saved state and logic use stable identifiers, never the words shown; older saves that stored those words still load (D-12),
/// and sentences are whole format strings with plural-aware counts (D-13).
@MainActor final class StableIdentifierTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    func testReviewProvenanceDecodesIdentifiersAndOlderWords()throws {
        func decode(_ value:String)throws->ReviewProvenance {try JSONDecoder().decode(ReviewProvenance.self,from:JSONEncoder().encode(value))}
        for provenance in ReviewProvenance.allCases {XCTAssertEqual(try decode(provenance.rawValue),provenance)}
        XCTAssertEqual(try decode("Current game"),.currentGame);XCTAssertEqual(try decode("Previous game"),.previousGame);XCTAssertEqual(try decode("Collection game"),.collectionGame)
        XCTAssertEqual(try decode("Something a user typed"),.imported)
        XCTAssertEqual(String(decoding:try JSONEncoder().encode(ReviewProvenance.currentGame),as:UTF8.self),"\"current-game\"")
    }
    func testPuzzleFiltersRestoreIdentifiersAndOlderTitles() {
        XCTAssertEqual(PuzzleStatusFilter(stored:"review"),.review);XCTAssertEqual(PuzzleStatusFilter(stored:"To review"),.review)
        XCTAssertEqual(PuzzleStatusFilter(stored:"Unsolved"),.unsolved);XCTAssertEqual(PuzzleStatusFilter(stored:nil),.all);XCTAssertEqual(PuzzleStatusFilter(stored:"All"),.all)
        let old=LearningPlayer.restored(["query":"fork","topic":"All topics","level":"All levels","status":"To review"])
        XCTAssertEqual(old.0,"fork");XCTAssertNil(old.1);XCTAssertNil(old.2);XCTAssertEqual(old.3,.review)
        let current=LearningPlayer.restored(["topic":"Pins","level":"Beginner","status":"unsolved"])
        XCTAssertEqual(current.1,"Pins");XCTAssertEqual(current.2,"Beginner");XCTAssertEqual(current.3,.unsolved)
    }
    /// The MCP projection still carries the same words, now from typed states.
    func testSessionStatesKeepTheirWireWords() {
        XCTAssertEqual([CoachingStatus.idle,.thinking,.ready,.error].map(\.rawValue),["idle","thinking","ready","error"])
        XCTAssertEqual([PreviewStatus.choosing,.analyzing,.ready,.error].map(\.rawValue),["choosing","analyzing","ready","error"])
        XCTAssertEqual([BusyReason.opponent,.analysis].map(\.rawValue),["opponent","analysis"])
    }
    func testAnIdleVoiceCoachHasNoStatusMessage()throws {
        let coach=try VoiceCoach(session:try GameSession(engine:nil))
        XCTAssertNil(coach.statusMessage,"idle is the absence of a message, not a word to compare");XCTAssertEqual(coach.status,"Disconnected")
    }
    func testPluralFormsAndListsAreWholeStrings() {
        XCTAssertEqual(Plural.count(1,one:"%d move",other:"%d moves"),"1 move");XCTAssertEqual(Plural.count(3,one:"%d move",other:"%d moves"),"3 moves")
        XCTAssertEqual(Plural.count(2,one:"Idea from Position %2$d · %1$d Move",other:"Idea from Position %2$d · %1$d Moves",5),"Idea from Position 5 · 2 Moves")
        XCTAssertEqual(Plural.count(1,one:"Removed %1$d file (%2$@).",other:"Removed %1$d files (%2$@).","2 KB"),"Removed 1 file (2 KB).")
        XCTAssertEqual(Plural.list(["Forks"]),"Forks");XCTAssertEqual(Plural.list(["Forks","Pins"]),"Forks and Pins");XCTAssertEqual(Plural.list(["Forks","Pins","Skewers"]),"Forks, Pins, and Skewers")
    }
}
