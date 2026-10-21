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
        let topics=["Pins","Forks"],levels=["Beginner","Developing"]
        let old=LearningPlayer.restored(["query":"fork","topic":"All topics","level":"All levels","status":"To review"],topics:topics,levels:levels)
        XCTAssertEqual(old.0,"fork");XCTAssertNil(old.1,"an older save's every-topic word shows every topic");XCTAssertNil(old.2);XCTAssertEqual(old.3,.review)
        let current=LearningPlayer.restored(["topic":"Pins","level":"Beginner","status":"unsolved"],topics:topics,levels:levels)
        XCTAssertEqual(current.1,"Pins");XCTAssertEqual(current.2,"Beginner");XCTAssertEqual(current.3,.unsolved)
        let retired=LearningPlayer.restored(["topic":"Skewers","level":"Expert"],topics:topics,levels:levels)
        XCTAssertNil(retired.1,"a topic the course no longer offers shows every puzzle");XCTAssertNil(retired.2);XCTAssertEqual(retired.3,.all)
    }
    /// The MCP projection still carries the same words, now from typed states.
    func testSessionStatesKeepTheirWireWords() {
        XCTAssertEqual([CoachingStatus.idle,.thinking,.ready,.error].map(\.rawValue),["idle","thinking","ready","error"])
        XCTAssertEqual([PreviewStatus.choosing,.analyzing,.ready,.error].map(\.rawValue),["choosing","analyzing","ready","error"])
        XCTAssertEqual([BusyReason.opponent,.analysis].map(\.rawValue),["opponent","analysis"])
    }
    func testAnIdleVoiceCoachIsATypedStateNotAWord()throws {
        let coach=try VoiceCoach(session:try GameSession(engine:nil))
        XCTAssertEqual(coach.connection,.disconnected,"idle is a state to compare, not shown text");XCTAssertEqual(coach.status,"Disconnected")
    }
    /// Counted text comes from the catalog's plural variations; without the shipped catalog every count reads "1 moves".
    func testPluralFormsAndListsAreWholeStrings() {
        func moves(_ n:Int)->String {String(localized:"\(n) moves",bundle:.checkmate)}
        XCTAssertEqual(moves(1),"1 move");XCTAssertEqual(moves(3),"3 moves");XCTAssertEqual(moves(0),"0 moves")
        XCTAssertEqual(String(localized:"\("Draw") · \(1) moves",bundle:.checkmate),"Draw · 1 move","a count after another value")
        XCTAssertEqual(String(localized:"Removed \(1) outdated files (\("2 KB")).",bundle:.checkmate),"Removed 1 outdated file (2 KB).")
        XCTAssertEqual(String(localized:"Move \(12): you had a forced win in \(1) moves here.",bundle:.checkmate),"Move 12: you had a forced win in 1 move here.","the plural follows the second number, not the first")
        XCTAssertEqual(String(localized:"Move \(1): you had a forced win in \(2) moves here.",bundle:.checkmate),"Move 1: you had a forced win in 2 moves here.")
        XCTAssertEqual(String(localized:"There are \(1) to find.",bundle:.checkmate),"There is 1 to find.")
        XCTAssertEqual(Plural.list(["Forks"]),"Forks");XCTAssertEqual(Plural.list(["Forks","Pins"]),"Forks and Pins");XCTAssertEqual(Plural.list(["Forks","Pins","Skewers"]),"Forks, Pins, and Skewers")
    }
}
