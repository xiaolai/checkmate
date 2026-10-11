import XCTest
@testable import CheckmateCore
final class LessonRemediationTests:XCTestCase {
    @MainActor func testSequentialContinuationStartsVisitedLessonButManualNavigationResumes()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openLesson(index:1);p.seek(step:5);p.openLesson(index:0)
        p.seek(step:p.current.beats.count-1);p.play();p.advance(by:p.duration)
        XCTAssertEqual(p.lessonIndex,1);XCTAssertEqual(p.step,0)
        p.seek(step:5);p.openLesson(index:0);p.openLesson(index:1);XCTAssertEqual(p.step,5);p.shutdown()
    }
    func testUnreachableBishopTargetsDrawAndRejectMoves() {
        var g=MiniGameState(kind:.bishopSweep,computer:false)
        g.snapshot.board=["c1":"wb","c8":"bb","e3":"wp","h7":"bp"]
        XCTAssertEqual(g.drawReason,"No remaining targets can be reached.")
        XCTAssertTrue(g.isFinished);XCTAssertFalse(g.play(.init(from:"c1",to:"d2")))
        XCTAssertNil(MiniGameOpponent.choose(in:g,profile:"beginner",seed:1))
    }
    func testRepetitionDrawUndoAndOldSaveCompatibility()throws {
        var g=MiniGameState(kind:.rookSweep,computer:false)
        let cycle=[MiniGameMove(from:"a1",to:"b1"),.init(from:"h8",to:"g8"),.init(from:"b1",to:"a1"),.init(from:"g8",to:"h8")]
        for _ in 0..<2{for move in cycle{XCTAssertTrue(g.play(move))}}
        XCTAssertNotNil(g.drawReason);XCTAssertTrue(g.isFinished)
        let restored=try JSONDecoder().decode(MiniGameState.self,from:JSONEncoder().encode(g));XCTAssertEqual(restored.drawReason,g.drawReason)
        g.undo();XCTAssertFalse(g.isFinished)
        XCTAssertTrue(g.play(.init(from:"g8",to:"f8")))
    }
    @MainActor func testAnimationOffAndOnEmitAllMovesOnceAcrossPauseResume()throws {
        for duration in [0,700] {
            let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
            s.state.settings.pieceDuration=duration;p.openLesson(index:2)
            p.seek(step:p.current.beats.firstIndex{$0.id=="pawn:5"}!)
            var events=0;p.onIllustration={_,_ in events+=1};p.play();p.advance(by:p.duration/2);p.pause();p.play();p.advance(by:p.duration/2-0.01)
            XCTAssertEqual(events,3,"animation duration \(duration)")
            p.pause();p.seek(step:p.step);XCTAssertEqual(events,3)
            p.play();p.advance(by:p.duration-0.01);XCTAssertEqual(events,6);p.shutdown()
        }
    }
    @MainActor func testPracticeInvitationPausesOnlyWhenPreferenceEnabled()throws {
        for pause in [false,true] {
            let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
            s.state.settings.pauseForPractice=pause;p.openLesson(index:3)
            p.seek(step:p.current.beats.count-1);p.play();p.advance(by:p.duration)
            XCTAssertEqual(p.lessonIndex,pause ? 3:4);XCTAssertEqual(p.playing,!pause)
            XCTAssertEqual(p.awaitingPractice,pause);p.shutdown()
        }
    }
    func testOldSettingsEnablePracticePause()throws {
        let settings=try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8))
        XCTAssertTrue(settings.pauseForPractice)
    }
    func testPawnFirstSingleMoveConsumesDoubleOption() {
        XCTAssertEqual(Set(CourseLibrary.pawnMoves(["h2":"wp"],from:"h2")),["h3","h4"])
        XCTAssertEqual(CourseLibrary.pawnMoves(["h3":"wp"],from:"h3"),["h4"])
    }
}

extension LessonRemediationTests {
    @MainActor func testPracticePresetsAreLegalNonterminalAndContainBothKings()throws {
        XCTAssertEqual(LessonPractice.presets.count,13)
        for preset in LessonPractice.presets {
            let r=try ChessRules(fen:preset.fen)
            XCTAssertFalse(r.over,preset.lessonID);XCTAssertFalse(r.check,preset.lessonID)
            XCTAssertEqual(r.board.values.filter{$0=="wk"}.count,1);XCTAssertEqual(r.board.values.filter{$0=="bk"}.count,1)
            try GameSession.validatePracticeFork(r,side:"w")
        }
    }
    @MainActor func testLessonPracticePreservesPreviousGameAndProgress()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        try s.rules.move("e2","e4");try s.rules.move("e7","e5");let old=s.rules.pgn
        p.openLesson(index:29);p.seek(step:5);let progress=s.state.course.segmentID
        try s.installPracticeFork(ChessRules(fen:LessonPractice.forLesson("fork")!.fen),side:"w")
        XCTAssertEqual(s.state.practice.previousGame,old);XCTAssertEqual(s.state.course.segmentID,progress);XCTAssertEqual(s.mode,.practice)
        try s.restorePrevious();XCTAssertEqual(s.rules.pgn,old);p.shutdown()
    }
    func testCueTimingScalesWithNarrationAndPreservesSlowAnimationEndpoints()throws {
        let c=try CourseLibrary(),li=c.lessons.firstIndex{$0.id=="famous-game"}!,si=c.lessons[li].beats.firstIndex{$0.id=="famous-game:9"}!
        let times=c.moveTimes(lesson:li,step:si,narrationSeconds:30,pieceDuration:0.7)
        XCTAssertEqual(times.count,3);XCTAssertGreaterThan(times.last!,15)
        let end=c.playbackDuration(lesson:li,step:si,narrationSeconds:30,pieceDuration:0.7)
        XCTAssertEqual(try c.frame(lesson:li,step:si,seconds:end,duration:0.7,narrationSeconds:30).board,c.referenceFrames[li][si].end.board)
    }
    func testNewPawnExampleAndUnderpromotionShowActualRule()throws {
        let c=try CourseLibrary(),pawn=c.lessons.first{$0.id=="pawn"}!
        XCTAssertTrue(pawn.beats.contains{$0.set==["h2":"wp"] && $0.moves==[["h2","h3"]]})
        XCTAssertTrue(pawn.beats.contains{$0.set==["h3":"wp"] && $0.say.contains("not h5")})
        let promo=c.lessons.first{$0.id=="promotion-en-passant"}!.beats.first{$0.moves.contains(["e7","e8","wn"])}!
        XCTAssertNotNil(promo.set);XCTAssertTrue(CourseLibrary.attacks(["e8":"wn"],from:"e8",to:"f6"));XCTAssertTrue(CourseLibrary.attacks(["e8":"wn"],from:"e8",to:"d6"))
    }
    func testPinnedKnightStillForbidsKingDestination()throws {
        let r=try ChessRules(fen:"4r3/8/8/6k1/8/8/4N3/4K3 b - - 0 1")
        XCTAssertFalse(r.moves("g5").contains{$0.to=="f4"})
        XCTAssertTrue(CourseLibrary.attacks(r.board,from:"e2",to:"f4"))
    }
}
extension LessonRemediationTests {
    func testMalformedCueMetadataIsRejected()throws {
        for cues in ["[0.2]","[0.8,0.2]","[-0.1,0.5]","[0.2,1.1]"] {
            let json="{\"id\":\"sample:0\",\"say\":\"Watch\",\"moves\":[[\"a1\",\"a2\"],[\"a2\",\"a3\"]],\"moveCues\":"+cues+"}"
            XCTAssertThrowsError(try JSONDecoder().decode(CourseBeat.self,from:Data(json.utf8)))
        }
    }
}

extension LessonRemediationTests {
    func testUnchangedLessonKeepsPublishedPackFingerprint()throws {
        let library=try CourseLibrary()
        XCTAssertEqual(LessonTranslation.source(library:library,index:0).fingerprint,"f7e08d39a736162c32b70c7d7a1ddf524702c6e9cbf9e09109aebd8f365bdda9")
    }
}
