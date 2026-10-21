import CryptoKit
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

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
        let cycle=[MiniGameMove(from:"b1",to:"a1"),.init(from:"g8",to:"h8"),.init(from:"a1",to:"b1"),.init(from:"h8",to:"g8")]
        for _ in 0..<2{for move in cycle{XCTAssertTrue(g.play(move))}}
        XCTAssertNotNil(g.drawReason);XCTAssertTrue(g.isFinished)
        let restored=try JSONDecoder().decode(MiniGameState.self,from:JSONEncoder().encode(g));XCTAssertEqual(restored.drawReason,g.drawReason)
        g.undo();XCTAssertFalse(g.isFinished)
        XCTAssertTrue(g.play(.init(from:"h8",to:"f8")))
    }
    @MainActor func testAnimationOffAndOnEmitAllMovesOnceAcrossPauseResume()throws {
        for duration in [0,700] {
            let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
            s.state.settings.pieceDuration=duration;p.openLesson(index:p.library.lessons.firstIndex{$0.id=="safe-squares"}!)
            p.seek(step:p.current.beats.firstIndex{$0.id=="safe-squares:14"}!)
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
            XCTAssertEqual(p.feedback,pause ? "Play Pawn Duel, or continue to the next lesson.":"");p.shutdown()
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
        let lessons=try CourseLibrary().lessons.filter{$0.practice != nil}
        XCTAssertEqual(lessons.count,16)
        for lesson in lessons {
            let r=try ChessRules(fen:lesson.practice!.fen)
            XCTAssertFalse(r.over,lesson.id);XCTAssertFalse(r.check,lesson.id)
            XCTAssertEqual(r.board.values.filter{$0=="wk"}.count,1);XCTAssertEqual(r.board.values.filter{$0=="bk"}.count,1)
            try GameSession.validatePracticeFork(r,side:"w")
        }
    }
    func testCueTimingScalesWithNarrationAndPreservesSlowAnimationEndpoints()throws {
        let c=try CourseLibrary(),li=c.lessons.firstIndex{$0.id=="safe-squares"}!,si=c.lessons[li].beats.firstIndex{$0.id=="safe-squares:14"}!
        let times=c.moveTimes(lesson:li,step:si,narrationSeconds:30,pieceDuration:0.7)
        XCTAssertEqual(times.count,3);XCTAssertGreaterThan(times.last!,15)
        let end=c.playbackDuration(lesson:li,step:si,narrationSeconds:30,pieceDuration:0.7)
        XCTAssertEqual(try c.frame(lesson:li,step:si,seconds:end,duration:0.7,narrationSeconds:30).board,c.referenceFrames[li][si].end.board)
    }
    func testUnderpromotionShowsTheKnightsActualReach()throws {
        let c=try CourseLibrary(),li=c.lessons.firstIndex{$0.id=="promotion-en-passant"}!
        let si=try XCTUnwrap(c.lessons[li].beats.firstIndex{$0.moves.contains(["f7","f8","wn"])})
        let end=try XCTUnwrap(c.referenceFrames[li][si].end.board)
        XCTAssertEqual(end["f8"],"wn")
        for arrow in c.referenceFrames[li][si].end.arrows {XCTAssertTrue(CourseLibrary.attacks(end,from:arrow[0],to:arrow[1]),"\(arrow)")}
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
    /// Every lesson's translation fingerprint, pinned when course edition 2 was published. A saved translation pack
    /// is rebuilt when its lesson's fingerprint changes, so an accidental edit to any lesson must fail here first.
    /// Re-pinned when The Pin's exercise board (pin:13) changed: in the old position no pin won material.
    /// Re-pinned when Chess Notation's transcript (notation:12–14) gained the "read as" / "said as" its recording speaks.
    /// Re-pinned when two recordings that kept dropping words were reworded: Playing in a Tournament (tournaments:14
    /// no longer ends on "Check the rules.") and Queen Practice (queen-practice:11 says "a square that a pawn attacks").
    /// Re-pinned when 20 lessons gained guard lines (defence drawn apart from attack arrows) and two gained
    /// sentence-timed stages; the other 19 lessons, without guards or stages, keep their fingerprints.
    /// Re-pinned when two beats answered a beginner's question: Removing the Defender (removing-the-defender:8 says
    /// the bishop on d5 can't take the pawn) and Two-Rook Checkmate (two-rook-mate:9 says nothing guards b6).
    func testCourseEditionFingerprintsArePinned()throws {
        let library=try CourseLibrary()
        let all=library.lessons.indices.map{library.lessons[$0].id+"="+LessonTranslation.source(library:library,index:$0).fingerprint}.joined(separator:" ")
        XCTAssertEqual(SHA256.hash(data:Data(all.utf8)).map{String(format:"%02x",$0)}.joined(),"1abcb1c2835091708e0bf76d77f58fdf9a22458c0ee6960ae5625f6cacb119f5")
    }
    /// Guards and stages are lesson mechanics: a translation pack is rebuilt when they change, including a new stage
    /// order or partition with the same overlays, but a lesson without them keeps its fingerprint (and its recordings).
    func testGuardsAndStagesCountOnlyWhereTheyExist()throws {
        let data=try Data(contentsOf:NativeResources.url("course.json"))
        func fingerprint(_ lesson:String,_ change:(inout [String:Any])->Void)throws -> String {
            var json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]),lessons=try XCTUnwrap(json["lessons"] as? [[String:Any]])
            let index=try XCTUnwrap(lessons.firstIndex{$0["id"] as? String==lesson})
            var beats=try XCTUnwrap(lessons[index]["beats"] as? [[String:Any]]);for i in beats.indices{change(&beats[i])};lessons[index]["beats"]=beats;json["lessons"]=lessons
            let library=try JSONDecoder().decode(CourseLibrary.self,from:JSONSerialization.data(withJSONObject:json))
            return LessonTranslation.source(library:library,index:index).fingerprint
        }
        let plain=try fingerprint("intro"){_ in}
        XCTAssertEqual(try fingerprint("intro"){$0["guards"]=[[String]]()},plain,"no guards is no change")
        XCTAssertNotEqual(try fingerprint("intro"){if $0["id"] as? String=="intro:1"{$0["guards"]=[["e1","d1"]]}},plain)
        let staged=try fingerprint("scholars-mate"){_ in}
        let stage:(inout [String:Any],([[String:Any]])->[[String:Any]])->Void={beat,edit in if beat["id"] as? String=="scholars-mate:1",let stages=beat["stages"] as? [[String:Any]]{beat["stages"]=edit(stages)}}
        XCTAssertNotEqual(try fingerprint("scholars-mate"){stage(&$0){Array($0.reversed())}},staged,"stage order")
        XCTAssertNotEqual(try fingerprint("scholars-mate"){stage(&$0){s in var a=s[0],b=s[1];a["guards"]=(a["guards"] as! [[String]])+(b["guards"] as! [[String]]);b["guards"]=[[String]]();return [a,b]}},staged,"stage partition, same overlays")
    }
    /// Grouping a practice activity under its lesson is presentation only: no lesson's translation pack is invalidated by it.
    func testPracticeGroupingLeavesEveryFingerprintAlone()throws {
        let data=try Data(contentsOf:NativeResources.url("course.json"))
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]),lessons=try XCTUnwrap(json["lessons"] as? [[String:Any]])
        XCTAssertEqual(lessons.filter{$0["practiceFor"] != nil}.count,5)
        lessons=lessons.map{$0.filter{$0.key != "practiceFor"}};json["lessons"]=lessons
        let grouped=try CourseLibrary(),ungrouped=try JSONDecoder().decode(CourseLibrary.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertTrue(ungrouped.lessons.allSatisfy{!$0.isPractice})
        for index in grouped.lessons.indices {
            XCTAssertEqual(LessonTranslation.source(library:grouped,index:index).fingerprint,LessonTranslation.source(library:ungrouped,index:index).fingerprint,grouped.lessons[index].id)
        }
    }
}

/// A silent narration service whose "sounding" state stands in for a real player: like NativeAudio it starts nothing
/// when narration is off, muted or failing, and stops on pause and stop. `playbackTime` exists only while sounding.
@MainActor private final class SoundingNarrationFake:NarrationService {
    var sounding=false,failure:String?,started=0
    var playbackTime:Double? {sounding ? 0:nil}
    var narrationFailure:String? {failure}
    func play(file:String,seconds:Double,settings:AppSettings){started+=1;sounding=failure==nil && settings.narration && settings.volume>0}
    func play(localURL:URL,seconds:Double,settings:AppSettings){play(file:localURL.path,seconds:seconds,settings:settings)}
    func pause(){sounding=false}
    func stop(){sounding=false}
}
extension LessonRemediationTests {
    /// Opens the first lesson, starts it, and republishes the projection without moving time.
    @MainActor private func playingLesson(_ audio:SoundingNarrationFake?,configure:(inout AppSettings)->Void={_ in})throws->(GameSession,LearningPlayer) {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);p.audio=audio
        // The app loads the lesson-language selection when it installs the pack store; without it the first settings change reads as a language change.
        p.reloadLocalizedPacks()
        configure(&s.state.settings);p.openLesson(index:0);p.play();XCTAssertTrue(p.playing,"precondition: the lesson plays");p.advance(by:0)
        return (s,p)
    }
    @MainActor func testNarrationActiveFollowsActualPlayback()throws {
        let audio=SoundingNarrationFake();let (s,p)=try playingLesson(audio)
        XCTAssertEqual(audio.started,1);XCTAssertEqual(s.lesson?.narrationActive,true)
        audio.stop();p.advance(by:0);XCTAssertEqual(s.lesson?.narrationActive,false,"A stopped player is not narrating while the lesson still plays")
        XCTAssertTrue(p.playing);p.shutdown()
    }
    @MainActor func testMutedNarrationIsNotActive()throws {
        let audio=SoundingNarrationFake();let (s,p)=try playingLesson(audio){$0.volume=0}
        XCTAssertEqual(s.lesson?.narrationActive,false)
        s.state.settings.volume=0.8;p.settingsChanged();XCTAssertEqual(s.lesson?.narrationActive,true,"Unmuting restarts narration")
        s.state.settings.volume=0;p.settingsChanged();XCTAssertEqual(s.lesson?.narrationActive,false,"Muting mid-clip stops reporting narration")
        p.shutdown()
    }
    @MainActor func testFailedNarrationIsNotActive()throws {
        let audio=SoundingNarrationFake();audio.failure="Narration could not play.";let (s,p)=try playingLesson(audio)
        XCTAssertEqual(audio.started,1);XCTAssertEqual(s.lesson?.narrationActive,false);p.shutdown()
    }
    @MainActor func testMissingNarrationServiceIsNotActive()throws {
        let (s,p)=try playingLesson(nil);XCTAssertEqual(s.lesson?.narrationActive,false);p.shutdown()
    }
    @MainActor func testPausedLessonReportsNoNarration()throws {
        let audio=SoundingNarrationFake();let (s,p)=try playingLesson(audio);XCTAssertEqual(s.lesson?.narrationActive,true)
        p.pause();XCTAssertFalse(audio.sounding);XCTAssertEqual(s.lesson?.narrationActive,false);p.shutdown()
    }
}
