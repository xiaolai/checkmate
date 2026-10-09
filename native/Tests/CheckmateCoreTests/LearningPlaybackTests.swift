import XCTest
@testable import CheckmateCore
final class LearningPlaybackTests:XCTestCase {
    @MainActor func testUnansweredQuizDoesNotAdvanceAndSeekIsDeterministic() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openLesson(index:0);p.seek(step:17);p.play();p.advance(by:100)
        XCTAssertEqual(p.step,17);XCTAssertFalse(p.playing);XCTAssertFalse(p.passed)
        p.click("e1");p.checkAnswer();XCTAssertTrue(p.passed)
        p.seek(step:0);let first=p.frame;p.advance(by:1);p.seek(step:0);XCTAssertEqual(p.frame,first)
    }
    @MainActor func testPuzzleRevealDoesNotMarkSolved() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openPuzzle(id:"rook");p.reveal();XCTAssertFalse(s.state.puzzles["rook"]!.solved);XCTAssertTrue(s.state.puzzles["rook"]!.review)
    }
    func testPawnDuelAndKingPathRules() {
        let board=["d5":"wp","e6":"bp"]
        XCTAssertTrue(CourseLibrary.pawnMoves(board,from:"d5").contains("e6"))
        XCTAssertFalse(CourseLibrary.pawnMoves(board,from:"d5").contains("e5"))
        XCTAssertFalse(CourseLibrary.safeKingStep(["b1":"wk","b8":"br"],from:"b1",to:"b2"))
    }
    func testAudioPolicyAlwaysMutesAutomationWithoutPersisting() {
        XCTAssertFalse(AudioPolicy(automation:true).mayPlay(enabled:true,volume:1))
        XCTAssertTrue(AudioPolicy(automation:false).mayPlay(enabled:true,volume:1))
    }
}
extension LearningPlaybackTests {
    @MainActor func testNarrationClockOwnsLessonTimingWhileAudioPlays()throws {let s=try GameSession(engine:nil),p=try LearningPlayer(session:s),audio=MockNarrationClock();p.audio=audio;p.openLesson(index:0);p.play();audio.time=0.5;p.tick(wallDelta:2);XCTAssertEqual(p.seconds,0.5,accuracy:0.001);audio.time=nil;p.tick(wallDelta:0.25);XCTAssertEqual(p.seconds,0.75,accuracy:0.001);p.pause()}
}
@MainActor private final class MockNarrationClock:NarrationService {var time:Double?;var playbackTime:Double?{time};func play(file:String,seconds:Double,settings:AppSettings){};func pause(){};func stop(){}}
