import CheckmateTestSupport
import XCTest
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// The practice drawer's heading says what the game shown is doing (whose move, Stockfish thinking, or its result),
/// as a heading without a closing period.
@MainActor final class PracticeHeadingTests:XCTestCase {
    func testTheHeadingFollowsTheGame(){
        XCTAssertEqual(DetailContent.practiceHeading(result:nil,learner:"w",thinking:false,learnerToMove:true),"Your move")
        XCTAssertEqual(DetailContent.practiceHeading(result:nil,learner:"w",thinking:true,learnerToMove:false),"Stockfish is thinking")
        XCTAssertEqual(DetailContent.practiceHeading(result:nil,learner:"b",thinking:false,learnerToMove:false),"Opponent's move")
        XCTAssertEqual(DetailContent.practiceHeading(result:"1-0",learner:"w",thinking:false,learnerToMove:false),"You won")
        XCTAssertEqual(DetailContent.practiceHeading(result:"1-0",learner:"b",thinking:false,learnerToMove:true),"You lost")
        XCTAssertEqual(DetailContent.practiceHeading(result:"0-1",learner:"b",thinking:false,learnerToMove:false),"You won")
        XCTAssertEqual(DetailContent.practiceHeading(result:"1/2-1/2",learner:"w",thinking:false,learnerToMove:true),"Drawn game")
        XCTAssertEqual(DetailContent.practiceHeading(result:"*",learner:"w",thinking:false,learnerToMove:true),"Game over")
    }
    /// The training game's status is a heading too, written like practice's: no closing period.
    func testTheTrainingGameStatusIsAHeading(){
        XCTAssertEqual(TrainingPanel.gameStatus(finished:false,paused:false,thinking:false),"Your move")
        XCTAssertEqual(TrainingPanel.gameStatus(finished:false,paused:false,thinking:true),"The defender is thinking")
        XCTAssertEqual(TrainingPanel.gameStatus(finished:false,paused:true,thinking:true),"Game paused")
        XCTAssertEqual(TrainingPanel.gameStatus(finished:true,paused:true,thinking:true),"Game over")
    }
    func testTheHeadingReadsTheSession()throws {
        let s=try GameSession(engine:nil)
        XCTAssertEqual(DetailContent.practiceHeading(s),"Your move","a new game as White starts on the learner's move")
        try s.playWhite(from:"e2",to:"e4");s.resign()
        XCTAssertTrue(s.finished);XCTAssertEqual(DetailContent.practiceHeading(s),"You lost","a resigned game shows its result")
    }
}
