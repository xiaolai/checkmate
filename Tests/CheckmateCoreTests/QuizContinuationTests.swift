import XCTest
@testable import CheckmateCore
final class QuizContinuationTests:XCTestCase {
    @MainActor func testCorrectQuizContinuesWithNextNarration()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s),audio=QuizNarrationRecorder();p.audio=audio
        p.openLesson(index:0);p.seek(step:17);p.click("e1")
        XCTAssertTrue(p.passed);XCTAssertTrue(s.state.course.answered.contains("intro:17"))
        try await Task.sleep(for:.milliseconds(750))
        XCTAssertEqual(p.step,18);XCTAssertTrue(p.playing);XCTAssertEqual(audio.files.last,p.library.voices[0][18].file)
        p.shutdown()
    }
    @MainActor func testWrongAnswerWaitsAndCorrectAnswerContinuesEvenWithTranscriptAutoAdvanceOff()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero);s.state.settings.autoAdvance=false
        p.openLesson(index:0);p.seek(step:17);p.click("a1");try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(p.step,17);XCTAssertFalse(p.playing);XCTAssertFalse(p.passed)
        p.clearSelection();p.click("e1");try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(p.step,18);XCTAssertTrue(p.playing);p.shutdown()
    }
    @MainActor func testPendingContinuationCannotOverridePauseOrNavigation()async throws {
        for action in ["pause","seek","next","lesson","puzzles","mini","practice","shutdown"] {
            let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero);p.openLesson(index:0);p.seek(step:17);p.click("e1")
            switch action {case "pause":p.pause();case "seek":p.seek(step:0);case "next":p.next();case "lesson":p.openLesson(index:1);case "puzzles":p.showPuzzleLibrary();case "mini":p.startPawnDuel();case "practice":s.resumePractice();default:p.shutdown()}
            let step=p.step,index=p.lessonIndex,mode=s.mode;try await Task.sleep(for:.milliseconds(10))
            XCTAssertEqual(p.step,step,action);XCTAssertEqual(p.lessonIndex,index,action);XCTAssertEqual(s.mode,mode,action);XCTAssertFalse(p.playing,action);p.shutdown()
        }
    }
    @MainActor func testReplayCancelsPendingContinuation()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero)
        p.openLesson(index:0);p.seek(step:17);p.click("e1");p.replay()
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

    @MainActor func testPreviouslyAnsweredWhiteKingClickContinuesWithoutConfirmation()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero)
        s.state.course.answered.append("intro:17");p.openLesson(index:0);p.seek(step:17);p.click("e1")
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(p.step,18);XCTAssertTrue(p.playing);p.shutdown()
    }
    @MainActor func testEverySingleSquareExerciseChecksItsClickImmediately()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        for (index,lesson) in p.library.lessons.enumerated() {
            for step in lesson.beats.indices {
                guard let e=p.library.exercises[lesson.id+":"+String(step)],e.kind=="squares",e.answers?.count==1 else{continue}
                p.openLesson(index:index);p.seek(step:step);p.click(e.answers![0])
                XCTAssertTrue(p.passed,"\(lesson.id):\(step)");XCTAssertEqual(p.feedback,"Correct. Well done.")
                p.pause()
            }
        }
        p.shutdown()
    }
    @MainActor func testSingleSquarePuzzleKeepsExplanationAfterClick()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,answerFeedbackDelay:.zero)
        let puzzle=try XCTUnwrap(p.library.puzzles.first{$0.exercise.kind=="squares" && $0.exercise.answers?.count==1})
        p.openPuzzle(id:puzzle.id);p.click(puzzle.exercise.answers![0])
        XCTAssertTrue(p.passed);XCTAssertTrue(p.feedback.contains(puzzle.explanation))
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(p.activePuzzle?.id,puzzle.id);XCTAssertFalse(p.playing);p.shutdown()
    }
    @MainActor func testMultipleSquareExerciseWaitsForConfirmation()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        let target=try XCTUnwrap(p.library.lessons.enumerated().flatMap{index,lesson in lesson.beats.indices.compactMap{step -> (Int,Int,Exercise)? in
            guard let e=p.library.exercises[lesson.id+":"+String(step)],e.kind=="squares",(e.answers?.count ?? 0)>1 else{return nil};return (index,step,e)
        }}.first)
        p.openLesson(index:target.0);p.seek(step:target.1)
        for square in target.2.answers!{p.click(square);XCTAssertFalse(p.passed)}
        p.checkAnswer();XCTAssertTrue(p.passed);p.shutdown()
    }
}
@MainActor private final class QuizNarrationRecorder:NarrationService {
    var files:[String]=[]
    var playbackTime:Double? {0}
    func play(file:String,seconds:Double,settings:AppSettings){files.append(file)}
    func pause(){}
    func stop(){}
}
