import XCTest
@testable import CheckmateCore
final class QuizContinuationTests:XCTestCase {
    @MainActor func testCorrectQuizContinuesWithNextNarration()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s),audio=QuizNarrationRecorder();p.audio=audio
        p.openLesson(index:0);p.seek(step:17);p.click("e1");p.checkAnswer()
        XCTAssertTrue(p.passed);XCTAssertTrue(s.state.course.answered.contains("intro:17"))
        try await Task.sleep(for:.milliseconds(750))
        XCTAssertEqual(p.step,18);XCTAssertTrue(p.playing);XCTAssertEqual(audio.files.last,p.library.voices[0][18].file)
        p.shutdown()
    }
    @MainActor func testWrongAnswerWaitsAndCorrectAnswerContinuesEvenWithTranscriptAutoAdvanceOff()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero);s.state.settings.autoAdvance=false
        p.openLesson(index:0);p.seek(step:17);p.click("a1");p.checkAnswer();try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(p.step,17);XCTAssertFalse(p.playing);XCTAssertFalse(p.passed)
        p.clearSelection();p.click("e1");p.checkAnswer();try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(p.step,18);XCTAssertTrue(p.playing);p.shutdown()
    }
    @MainActor func testPendingContinuationCannotOverridePauseOrNavigation()async throws {
        for action in ["pause","seek","next","lesson","puzzles","mini","practice","shutdown"] {
            let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero);p.openLesson(index:0);p.seek(step:17);p.click("e1");p.checkAnswer()
            switch action {case "pause":p.pause();case "seek":p.seek(step:0);case "next":p.next();case "lesson":p.openLesson(index:1);case "puzzles":p.showPuzzleLibrary();case "mini":p.startPawnDuel();case "practice":s.resumePractice();default:p.shutdown()}
            let step=p.step,index=p.lessonIndex,mode=s.mode;try await Task.sleep(for:.milliseconds(10))
            XCTAssertEqual(p.step,step,action);XCTAssertEqual(p.lessonIndex,index,action);XCTAssertEqual(s.mode,mode,action);XCTAssertFalse(p.playing,action);p.shutdown()
        }
    }
    @MainActor func testReplayCancelsPendingContinuation()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero)
        p.openLesson(index:0);p.seek(step:17);p.click("e1");p.checkAnswer();p.replay()
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(p.step,17);XCTAssertTrue(p.playing);p.shutdown()
    }
    @MainActor func testReplayingPreviouslyAnsweredQuizCanAdvance()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);s.state.course.answered.append("intro:17");p.openLesson(index:0);p.seek(step:17);p.play();p.advance(by:p.duration)
        XCTAssertEqual(p.step,18);XCTAssertTrue(p.playing);p.shutdown()
    }
    @MainActor func testStandalonePuzzleKeepsItsExplanationAfterCorrectAnswer()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero);p.openPuzzle(id:"rook");p.click("d2");p.click("d5");let explanation=p.feedback;try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(p.activePuzzle?.id,"rook");XCTAssertTrue(p.passed);XCTAssertEqual(p.feedback,explanation);XCTAssertFalse(p.playing);p.shutdown()
    }

}
@MainActor private final class QuizNarrationRecorder:NarrationService {
    var files:[String]=[]
    var playbackTime:Double? {0}
    func play(file:String,seconds:Double,settings:AppSettings){files.append(file)}
    func pause(){}
    func stop(){}
}
