import CheckmateTestSupport
import XCTest
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// Guided practice gives hints step by step: nothing is shown until asked, the first request marks the piece to move,
/// the second shows the move itself, and the hint stays on the board until the learner moves.
final class StepHintTests:XCTestCase {
    @MainActor private func settle(_ done:()->Bool) async throws {for _ in 0..<200 where !done(){try await Task.sleep(nanoseconds:5_000_000)};XCTAssertTrue(done())}
    @MainActor func testGuidedPracticeShowsNoHintUntilAsked() async throws {
        let engine=StepHintEngine(),s=try GameSession(engine:engine);XCTAssertEqual(s.state.settings.coachingMode,"guided","Guided stays the default")
        try s.playWhite(from:"e2",to:"e4");try await settle{s.rules.history.count==2};try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertTrue(s.arrows.isEmpty,"No best-move arrow after the reply");XCTAssertTrue(s.highlights.isEmpty);XCTAssertNil(s.coaching.recommendation);XCTAssertEqual(engine.hintSearches,0)
    }
    @MainActor func testFirstHintMarksThePieceAndTheSecondShowsTheMove() async throws {
        let engine=StepHintEngine(),s=try GameSession(engine:engine);XCTAssertEqual(s.hintStep,0)
        s.hint();try await settle{s.hintStep==1}
        XCTAssertEqual(s.highlights.map(\.sq),["g1"],"The first hint marks the piece to move");XCTAssertTrue(s.arrows.isEmpty,"The first hint does not show the move")
        XCTAssertFalse(s.message.contains("f3"),"The first hint does not name the destination: \(s.message)");XCTAssertEqual(s.state.practice.hints,1)
        XCTAssertNil(s.annotationLifetime,"A hint stays until the learner moves")
        s.hint();XCTAssertEqual(s.hintStep,2);XCTAssertEqual(s.arrows,[["g1","f3"]],"The second hint shows the move");XCTAssertTrue(s.message.contains("f3"))
        XCTAssertEqual(engine.hintSearches,1,"The second step reuses the first search");XCTAssertEqual(s.state.practice.hints,2);XCTAssertNil(s.annotationLifetime)
        s.hint();XCTAssertEqual(s.state.practice.hints,2,"Nothing more to show, nothing more counted")
        try s.playWhite(from:"g1",to:"f3");XCTAssertEqual(s.hintStep,0,"Moving ends the hint");XCTAssertTrue(s.arrows.isEmpty);XCTAssertTrue(s.highlights.isEmpty)
    }
    @MainActor func testHintCountIsSavedAndBelongsToItsGame() throws {
        let s=try GameSession(engine:nil);s.state.practice.hints=3;try s.rules.move(uci:"e2e4");s.newGame()
        XCTAssertEqual(s.state.practice.hints,0,"A new game starts unhelped");XCTAssertEqual(s.state.practice.previousHints,3)
        try s.restorePrevious();XCTAssertEqual(s.state.practice.hints,3,"Restoring a game restores its hint count")
        let saved=try JSONDecoder().decode(PracticeState.self,from:try JSONEncoder().encode(s.state.practice));XCTAssertEqual(saved.hints,3)
        let old=try JSONDecoder().decode(PracticeState.self,from:Data(#"{"pgn":"","fen":""}"#.utf8));XCTAssertEqual(old.hints,0,"Older saves load with no hints");XCTAssertEqual(old.previousHints,0)
        let bad=try JSONDecoder().decode(PracticeState.self,from:Data(#"{"hints":-4}"#.utf8));XCTAssertEqual(bad.hints,0)
    }
}
@MainActor private final class StepHintEngine:TestEngineService {
    var hintSearches=0
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws->EngineAnalysis {let white=fen.split(separator:" ")[1]=="w";if white{hintSearches+=1};return EngineAnalysis(bestMove:white ? "g1f3":"e7e5")}
}
