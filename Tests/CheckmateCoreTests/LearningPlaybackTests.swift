import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class LearningPlaybackTests:XCTestCase {
    @MainActor func testLessonAdvancesWithoutAnswerAndSeekIsDeterministic() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openLesson(index:0);p.seek(step:p.current.beats.firstIndex{$0.id=="intro:15"}!);p.play();p.advance(by:p.duration)
        XCTAssertEqual(p.key,"intro:16");XCTAssertTrue(p.playing);XCTAssertNil(p.exercise)
        p.seek(step:0);let first=p.frame;p.advance(by:1);p.seek(step:0);XCTAssertEqual(p.frame,first)
        p.shutdown()
    }
    @MainActor func testPuzzleRevealDoesNotMarkSolved() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openPuzzle(id:"extra-1");p.reveal();XCTAssertFalse(s.state.puzzles["extra-1"]!.solved);XCTAssertTrue(s.state.puzzles["extra-1"]!.review)
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
    /// A staged step read while paused shows every stage. Play starts at the first stage and reveals the next with the
    /// narration; pausing freezes what is shown, even before the first tick; going to the step again reads it again.
    @MainActor func testStagesArePlayedOnlyWhilePlaying() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        let li=try XCTUnwrap(p.library.lessons.firstIndex{$0.id=="scholars-mate"});p.openLesson(index:li,resume:false)
        let step=try XCTUnwrap(p.current.beats.firstIndex{$0.id=="scholars-mate:1"}),both=[["e8","f7"],["e1","f2"]]
        p.seek(step:step);XCTAssertEqual(p.frame.guards,both,"read: every stage")
        p.play();XCTAssertEqual(p.frame.guards,[["e8","f7"]],"played: the first stage")
        p.pause();XCTAssertEqual(p.frame.guards,[["e8","f7"]],"paused at once: frozen, not read")
        p.seek(step:step);XCTAssertEqual(p.frame.guards,both,"going to the step reads it again")
        let cue=try XCTUnwrap(p.beat.stageCues?.first)*p.library.voices[li][step].seconds
        p.play();p.advance(by:cue+0.01);XCTAssertEqual(p.frame.guards,both,"the second stage with its sentence")
        p.pause();XCTAssertEqual(p.frame.guards,both)
        p.shutdown()
    }
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
    /// Every lesson, a practice activity included, continues to the next main lesson from its first transcript.
    @MainActor func testEveryLessonBoundaryContinuesAlongTheMainPath() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.autoAdvance=true;session.state.settings.pauseForPractice=false
        for index in player.library.lessons.indices {
            player.openLesson(index:index)
            let finalStep=player.current.beats.count-1
            session.state.course.answered.append(player.current.id+":"+String(finalStep))
            player.seek(step:finalStep)
            let exercise=player.invitationStep==finalStep
            player.play();player.advance(by:player.duration)
            // An exercise step is an interaction boundary: narration ending there never leaves the lesson.
            if exercise {
                XCTAssertEqual(player.lessonIndex,index,player.current.id);XCTAssertEqual(player.step,finalStep);XCTAssertFalse(player.playing)
                XCTAssertEqual(player.feedback,"Your turn: make your move on the board, or continue to the next lesson.")
            } else if let next=player.library.nextMainLesson(after:index) {
                XCTAssertFalse(player.library.lessons[next].isPractice)
                XCTAssertEqual(player.lessonIndex,next,player.library.lessons[index].id)
                XCTAssertEqual(player.step,0);XCTAssertTrue(player.playing)
            } else {XCTAssertFalse(player.playing)}
            player.pause()
        }
        XCTAssertEqual(Set(session.state.course.completed).count,player.library.lessons.count)
    }
    /// Uninterrupted playback from the first lesson walks only the main path: no practice activity is completed or
    /// given a reading position, and the bookmark ends on the last lesson.
    @MainActor func testUninterruptedPlaybackSkipsPracticeActivities() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.autoAdvance=true;session.state.settings.pauseForPractice=false
        let main=player.library.lessons.filter{!$0.isPractice}.map(\.id),practice=player.library.lessons.filter(\.isPractice).map(\.id)
        XCTAssertEqual(main.count,34);XCTAssertEqual(practice.count,5)
        player.openLesson(index:0,resume:false);player.play()
        var visited:[String]=[],guardSteps=0
        // Every beat plays to its end in turn, as uninterrupted listening does; nothing seeks.
        while player.playing,guardSteps<5000 {
            if visited.last != player.current.id{visited.append(player.current.id)}
            player.advance(by:player.duration);guardSteps+=1
            // Playback waits on an exercise; the learner's Continue goes on along the main path.
            if !player.playing,player.attemptStep,let next=player.library.nextMainLesson(after:player.lessonIndex){player.openLesson(index:next,resume:false);player.play()}
        }
        XCTAssertEqual(visited,main)
        XCTAssertEqual(session.state.course.completed,main)
        XCTAssertTrue(practice.allSatisfy{session.state.course.positions?[$0]==nil},"a skipped activity keeps no reading position")
        XCTAssertEqual(session.state.course.lessonID,main.last)
    }
    /// The end of The Rook and of its activity, under each Continue automatically × Pause for practice setting.
    @MainActor func testPlaybackSettingsAtAParentAndItsActivity() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        func index(_ id:String)throws -> Int {try XCTUnwrap(player.library.lessons.firstIndex{$0.id==id})}
        let rook=try index("rook"),practice=try index("rook-practice"),bishop=try index("bishop")
        // (autoAdvance, pauseForPractice, start) -> where playback is afterwards, whether it plays, and the message.
        let cases:[(Bool,Bool,Int,Int,Bool,String)]=[
            (false,false,rook,rook,false,"Lesson explored! You can replay it whenever you like."),
            (false,true,rook,rook,false,"Lesson explored! You can replay it whenever you like."),
            (true,true,rook,rook,false,"Try Rook Practice, or continue to the next lesson."),
            (true,false,rook,bishop,true,""),
            (false,false,practice,practice,false,"Lesson explored! You can replay it whenever you like."),
            (false,true,practice,practice,false,"Lesson explored! You can replay it whenever you like."),
            (true,true,practice,practice,false,"Play Rook Sweep, or continue to the next lesson."),
            (true,false,practice,bishop,true,""),
        ]
        for (auto,pauseFor,start,end,playing,message) in cases {
            let label="autoAdvance \(auto), pauseForPractice \(pauseFor), from \(player.library.lessons[start].id)"
            session.state.settings.autoAdvance=auto;session.state.settings.pauseForPractice=pauseFor
            player.openLesson(index:start,resume:false);player.seek(step:player.current.beats.count-1);player.play();player.advance(by:player.duration)
            XCTAssertEqual(player.lessonIndex,end,label);XCTAssertEqual(player.playing,playing,label)
            if !playing{XCTAssertEqual(player.feedback,message,label)}
            player.pause()
        }
    }
    /// With Pause for practice on, a lesson with a practice activity stops at its end and names the activity; Continue
    /// would then go to the next main lesson. A lesson without practice continues.
    @MainActor func testPauseForPracticeOffersTheActivity() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.autoAdvance=true;session.state.settings.pauseForPractice=true
        let knight=try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="knight"}),horses=try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="knight-practice"})
        player.openLesson(index:knight);player.seek(step:player.current.beats.count-1);player.play();player.advance(by:player.duration)
        XCTAssertEqual(player.lessonIndex,knight);XCTAssertFalse(player.playing)
        XCTAssertEqual(player.feedback,"Try Knight Practice, or continue to the next lesson.")
        XCTAssertEqual(player.library.practice(for:knight),[horses])
        // The King has no practice activity, so it continues to Safe Squares, which is a main lesson again.
        let king=try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="king"})
        player.openLesson(index:king);player.seek(step:player.current.beats.count-1);player.play();player.advance(by:player.duration)
        XCTAssertEqual(player.current.id,"safe-squares");XCTAssertTrue(player.playing);player.pause()
        // Completing again is idempotent.
        player.openLesson(index:knight);player.complete();player.complete()
        XCTAssertEqual(session.state.course.completed.filter{$0=="knight"}.count,1)
    }
}
