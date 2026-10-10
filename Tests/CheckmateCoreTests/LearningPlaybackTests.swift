import XCTest
@testable import CheckmateCore
final class LearningPlaybackTests:XCTestCase {
    @MainActor func testLessonAdvancesWithoutAnswerAndSeekIsDeterministic() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openLesson(index:0);p.seek(step:p.current.beats.firstIndex{$0.id=="intro:18"}!);p.play();p.advance(by:p.duration)
        XCTAssertEqual(p.key,"intro:20");XCTAssertTrue(p.playing);XCTAssertNil(p.exercise)
        p.seek(step:0);let first=p.frame;p.advance(by:1);p.seek(step:0);XCTAssertEqual(p.frame,first)
        p.shutdown()
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

extension LearningPlaybackTests {
    @MainActor func testFinishedNarrationStartsNextLessonAndOpensDetails() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.autoAdvance=true
        var opened=0;player.onLessonOpened={opened+=1}
        player.openLesson(index:0);let completedID=player.current.id
        player.seek(step:player.current.beats.count-1)
        XCTAssertNil(player.exercise)
        player.play();player.advance(by:player.duration)
        XCTAssertTrue(session.state.course.completed.contains(completedID))
        XCTAssertEqual(player.lessonIndex,1);XCTAssertEqual(player.step,0)
        XCTAssertEqual(player.seconds,0);XCTAssertTrue(player.playing)
        XCTAssertEqual(session.state.course.lessonID,player.current.id)
        XCTAssertEqual(session.state.course.step,0);XCTAssertEqual(opened,2)
        player.pause()
    }
    @MainActor func testDisabledAutomaticPlaybackStopsAtLessonEnd() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.autoAdvance=false
        player.openLesson(index:0);player.seek(step:player.current.beats.count-1)
        player.play();player.advance(by:player.duration)
        XCTAssertEqual(player.lessonIndex,0);XCTAssertFalse(player.playing)
        XCTAssertTrue(session.state.course.completed.contains(player.current.id))
    }
    @MainActor func testFinalLessonStopsWithoutLoopingOrDuplicateCompletion() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.autoAdvance=true
        let last=player.library.lessons.count-1
        player.openLesson(index:last);player.seek(step:player.current.beats.count-1)
        XCTAssertNil(player.exercise)
        player.play();player.advance(by:player.duration);player.advance(by:100)
        XCTAssertEqual(player.lessonIndex,last);XCTAssertFalse(player.playing)
        XCTAssertEqual(session.state.course.completed.filter{$0==player.current.id}.count,1)
    }
    @MainActor func testManualNextAtLessonEndDoesNotStartNextLesson() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.autoAdvance=true
        player.openLesson(index:0);player.seek(step:player.current.beats.count-1);player.next()
        XCTAssertEqual(player.lessonIndex,0);XCTAssertFalse(player.playing)
    }
    @MainActor func testTranscriptNavigationDoesNotRequestDrawerReopen() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        var opened=0;player.onLessonOpened={opened+=1}
        player.openLesson(index:0);player.seek(step:1);player.play();player.pause()
        XCTAssertEqual(opened,1)
        player.openLesson(index:0);XCTAssertEqual(opened,2)
    }
}

extension LearningPlaybackTests {
    @MainActor func testEveryLessonBoundaryContinuesFromFirstTranscript() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.autoAdvance=true
        for index in player.library.lessons.indices {
            player.openLesson(index:index)
            let finalStep=player.current.beats.count-1
            session.state.course.answered.append(player.current.id+":"+String(finalStep))
            player.seek(step:finalStep)
            player.play();player.advance(by:player.duration)
            if index+1<player.library.lessons.count {
                XCTAssertEqual(player.lessonIndex,index+1)
                XCTAssertEqual(player.step,0);XCTAssertTrue(player.playing)
            } else {XCTAssertFalse(player.playing)}
            player.pause()
        }
        XCTAssertEqual(Set(session.state.course.completed).count,player.library.lessons.count)
    }
}
