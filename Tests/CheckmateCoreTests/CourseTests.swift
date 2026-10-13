import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class CourseTests:XCTestCase {
    func testAllTimelineEndpointsMatchReference() throws {
        let course=try CourseLibrary()
        for (li,l) in course.lessons.enumerated() {for step in l.beats.indices {
            let expected=course.referenceFrames[li][step]
            XCTAssertEqual(try course.frame(lesson:li,step:step,seconds:0),expected.start,"\(l.id):\(step) start")
            XCTAssertEqual(try course.frame(lesson:li,step:step,seconds:course.voices[li][step].duration),expected.end,"\(l.id):\(step) end")
        }}
    }
    /// A beat's overlays describe the position its moves produce: the rook lands first, then its arrow and the check.
    func testOverlaysWaitForTheMovesTheyDescribe() throws {
        let course=try CourseLibrary()
        let li=try XCTUnwrap(course.lessons.firstIndex{$0.id=="check-and-checkmate"}),si=try XCTUnwrap(course.lessons[li].beats.firstIndex{$0.id=="check-and-checkmate:15"})
        let narration=course.voices[li][si].seconds,duration=CourseTiming.standard.pieceDuration
        let landed=try XCTUnwrap(course.moveTimes(lesson:li,step:si,narrationSeconds:narration,pieceDuration:duration).last)+duration
        for seconds in [0,landed-duration/2,landed-0.01] {
            let frame=try course.frame(lesson:li,step:si,seconds:seconds)
            XCTAssertTrue(frame.arrows.isEmpty,"no arrow before the rook lands (\(seconds)s)")
            XCTAssertFalse(frame.hl.contains{$0.kind=="check"},"no check before the rook lands (\(seconds)s)")
        }
        let after=try course.frame(lesson:li,step:si,seconds:landed)
        XCTAssertEqual(after.board?["h8"],"wr")
        XCTAssertEqual(after.arrows,[["h8","c8"]],"the attack arrow ends on the king it attacks")
        XCTAssertEqual(after.hl,[Highlight(sq:"c8",kind:"check")])
    }
    /// An arrow that previews the beat's own move, or that the previous beat already showed, stays up during the move.
    func testMovePreviewsAndCarriedOverlaysStayDuringTheMove() throws {
        let course=try CourseLibrary()
        func frame(_ id:String)throws -> CourseFrame {
            let li=try XCTUnwrap(course.lessons.firstIndex{$0.beats.contains{$0.id==id}}),si=try XCTUnwrap(course.lessons[li].beats.firstIndex{$0.id==id})
            return try course.frame(lesson:li,step:si,seconds:0)
        }
        XCTAssertEqual(try frame("notation:5").arrows,[["g8","f6"]],"a preview of the coming move")
        XCTAssertEqual(try frame("scholars-mate:4").arrows,[["c4","f7"]],"carried over from the previous beat; the queen's new arrow waits for the queen")
    }
    private func locate(_ course:CourseLibrary,_ id:String)throws -> (Int,Int) {
        let li=try XCTUnwrap(course.lessons.firstIndex{$0.beats.contains{$0.id==id}});return (li,try XCTUnwrap(course.lessons[li].beats.firstIndex{$0.id==id}))
    }
    /// A guard appears once it is true and stays true: the d-pawn's guard of e4 when the pawn lands on d3, before Black's
    /// knight moves; the king's guard of the queen when she lands beside him, not while her square is empty.
    func testGuardsAppearWhenTheyBecomeTrue() throws {
        let course=try CourseLibrary(),duration=CourseTiming.standard.pieceDuration
        for (id,guardLine,landing) in [("scholars-mate:14",["d3","e4"],0),("check-and-checkmate:13",["e6","e7"],0)] {
            let (li,si)=try locate(course,id)
            let landed=course.moveTimes(lesson:li,step:si,narrationSeconds:course.voices[li][si].seconds,pieceDuration:duration)[landing]+duration
            XCTAssertFalse(try course.frame(lesson:li,step:si,seconds:0).guards.contains(guardLine),"\(id): not before its piece lands")
            XCTAssertFalse(try course.frame(lesson:li,step:si,seconds:landed-0.01).guards.contains(guardLine),"\(id): not in flight")
            XCTAssertTrue(try course.frame(lesson:li,step:si,seconds:landed).guards.contains(guardLine),"\(id): from the landing")
            XCTAssertTrue(try course.frame(lesson:li,step:si,seconds:course.voices[li][si].duration).guards.contains(guardLine),"\(id): to the end")
        }
    }
    /// Every guard shown, at every moment sampled (the start, mid-flight, each landing, the removals, the end), holds on
    /// the board shown with it: its piece reaches the square, which is empty or holds a piece of its own side.
    func testEveryGuardShownHoldsOnItsBoard() throws {
        let course=try CourseLibrary(),duration=CourseTiming.standard.pieceDuration
        var checked=0
        for (li,l) in course.lessons.enumerated() {for step in l.beats.indices {
            let times=course.moveTimes(lesson:li,step:step,narrationSeconds:course.voices[li][step].seconds,pieceDuration:duration)
            let flights:[Double]=times.flatMap{(t:Double)->[Double] in [t+duration/2,t+duration]}
            let moments:[Double]=[0,course.voices[li][step].duration]+flights+(times.last.map{[$0+duration+course.lessonTiming.removalDelay]} ?? [])
            for seconds in moments {
                let frame=try course.frame(lesson:li,step:step,seconds:seconds)
                for guardLine in frame.guards {
                    checked+=1
                    XCTAssertTrue(CourseLibrary.guardHolds(frame.board ?? [:],guardLine),"\(l.beats[step].id ?? ""): \(guardLine) at \(seconds)s")
                    XCTAssertFalse(frame.arrows.contains(guardLine),"\(l.beats[step].id ?? ""): a guard is not also an arrow")
                }
            }
        }}
        XCTAssertGreaterThan(checked,40,"the course draws guards")
    }
    /// "Both White knights could jump to d2": the knight that could also have moved is shown before the move, beside the
    /// move's own preview.
    func testAnotherPieceThatCouldMakeTheMoveIsPreviewed() throws {
        let course=try CourseLibrary()
        for (id,alternative) in [("notation:19",["f3","d2"]),("notation:20",["a5","a3"])] {
            let (li,si)=try locate(course,id)
            XCTAssertTrue(try course.frame(lesson:li,step:si,seconds:0).arrows.contains(alternative),id)
        }
        XCTAssertEqual(CourseLibrary.movePreviews(["b1":"wn","f3":"wn","b8":"bn"],moves:[["b8","d7"]],arrows:[["f3","d2"]]),[["b8","d7"]],"another side's piece is no alternative")
    }
    /// A staged beat shows its first stage, then the next when its anchor phrase is spoken. Without English cues (a
    /// translation) the stages spread evenly over the narration. Read rather than played, it shows every stage.
    func testStagesRevealWithTheNarration() throws {
        let course=try CourseLibrary(),(li,si)=try locate(course,"scholars-mate:1"),beat=course.lessons[li].beats[si]
        let narration=course.voices[li][si].seconds,cue=try XCTUnwrap(beat.stageCues?.first)*narration
        let f7=Highlight(sq:"f7",kind:"focus"),f2=Highlight(sq:"f2",kind:"focus")
        func frame(_ seconds:Double,useCues:Bool=true,staged:Bool=true)throws -> CourseFrame {try course.frame(lesson:li,step:si,seconds:seconds,useCues:useCues,staged:staged)}
        XCTAssertEqual(try frame(0).guards,[["e8","f7"]]);XCTAssertEqual(try frame(0).hl,[f7])
        XCTAssertEqual(try frame(cue-0.01).guards,[["e8","f7"]])
        XCTAssertEqual(try frame(cue).guards,[["e8","f7"],["e1","f2"]]);XCTAssertEqual(try frame(cue).hl,[f7,f2])
        XCTAssertEqual(try frame(narration/2-0.01,useCues:false).guards,[["e8","f7"]])
        XCTAssertEqual(try frame(narration/2,useCues:false).guards,[["e8","f7"],["e1","f2"]])
        XCTAssertEqual(try frame(0,staged:false).guards,[["e8","f7"],["e1","f2"]],"read, not played: every stage")
        XCTAssertGreaterThan(cue,narration*0.3,"the second sentence starts well into the clip");XCTAssertLessThan(cue,narration*0.8)
    }
    /// Every arrow and check mark agrees with the board it is drawn on. A sliding piece's arrow may cross a piece to show
    /// a pin, skewer or blocked line, but it ends on a piece: it never runs past what it attacks onto an empty square.
    func testEveryOverlayAgreesWithItsBoard() throws {
        let course=try CourseLibrary()
        for (li,l) in course.lessons.enumerated() {for step in l.beats.indices {
            let frame=try course.frame(lesson:li,step:step,seconds:course.voices[li][step].duration),id=l.beats[step].id ?? "\(l.id):\(step)"
            guard let board=frame.board else{continue}
            for arrow in frame.arrows {
                guard let piece=board[arrow[0]],"rbq".contains(piece.suffix(1)) else{continue}
                let (x0,y0)=(Int(arrow[0].utf8.first!),Int(arrow[0].suffix(1))!),(x1,y1)=(Int(arrow[1].utf8.first!),Int(arrow[1].suffix(1))!)
                let (dx,dy)=(x1-x0,y1-y0)
                guard dx==0 || dy==0 || abs(dx)==abs(dy) else{continue}
                let (sx,sy)=(dx.signum(),dy.signum())
                let crossed=(1..<max(abs(dx),abs(dy))).contains{board[String(UnicodeScalar(UInt8(x0+$0*sx)))+String(y0+$0*sy)] != nil}
                XCTAssertFalse(crossed && board[arrow[1]]==nil,"\(id): \(arrow) runs past the piece it attacks onto an empty square")
            }
            for mark in frame.hl where mark.kind=="check" {
                let king=board[mark.sq]
                XCTAssertEqual(king?.suffix(1),"k","\(id): a check mark is on a king")
                guard let colour=king?.prefix(1) else{continue}
                XCTAssertTrue(board.contains{$0.value.prefix(1) != colour && CourseLibrary.attacks(board,from:$0.key,to:mark.sq)},"\(id): the marked king is attacked")
            }
        }}
    }
    /// Each practice activity belongs to the piece lesson just before it; the main path runs past it.
    func testPracticeActivitiesBelongToTheirPieceLesson() throws {
        let course=try CourseLibrary()
        func index(_ id:String)throws -> Int {try XCTUnwrap(course.lessons.firstIndex{$0.id==id},id)}
        let pairs=["pawn":"pawn-duel","rook":"rook-practice","bishop":"bishop-practice","queen":"queen-practice","knight":"knight-practice"]
        XCTAssertEqual(Set(course.lessons.filter(\.isPractice).map(\.id)),Set(pairs.values))
        for (parent,child) in pairs {
            XCTAssertEqual(course.practice(for:try index(parent)),[try index(child)],parent)
            XCTAssertEqual(course.practice(for:try index(child)),[],"an activity has no practice of its own")
        }
        for (from,to) in [("pawn","rook"),("pawn-duel","rook"),("knight","king"),("knight-practice","king"),("king","safe-squares"),("safe-squares","check-and-checkmate"),("board","pawn")] {
            XCTAssertEqual(course.nextMainLesson(after:try index(from)),try index(to),from)
        }
        for (from,to) in [("rook","pawn"),("pawn-duel","pawn"),("rook-practice","rook"),("check-and-checkmate","safe-squares"),("safe-squares","king"),("pawn","board")] {
            XCTAssertEqual(course.previousMainLesson(before:try index(from)),try index(to),from)
        }
        XCTAssertNil(course.previousMainLesson(before:0))
        XCTAssertNil(course.previousMainLesson(before:course.lessons.count))
        XCTAssertNil(course.nextMainLesson(after:course.lessons.count-1))
        XCTAssertNil(course.nextMainLesson(after:course.lessons.count))
        XCTAssertEqual(course.practice(for:-1),[])
    }
    func testEveryExerciseAcceptsAuthoredAnswerAndRejectsWrongAnswer() throws {
        let c=try CourseLibrary()
        for (id,e) in c.exercises where e.kind != "path" {
            XCTAssertTrue(e.matches(e.referenceAnswer),id)
            XCTAssertFalse(e.matches(["invalid"]),id)
        }
    }

    func testKnightJumpsOverUnmovedFriendlyPawnsInLesson() throws {
        let course=try CourseLibrary()
        let li=try XCTUnwrap(course.lessons.firstIndex{$0.id=="opening"})
        let si=try XCTUnwrap(course.lessons[li].beats.firstIndex{$0.id=="opening:5"})
        let start=try XCTUnwrap(course.frame(lesson:li,step:si,seconds:0).board)
        let end=try XCTUnwrap(course.frame(lesson:li,step:si,seconds:course.voices[li][si].duration).board)
        let rules=try ChessRules()
        try rules.move("d2","d4");try rules.move("d7","d5")
        XCTAssertEqual(start,rules.board)
        XCTAssertEqual(Set(rules.moves("g1").map(\.to)),Set(["f3","h3"]))
        XCTAssertThrowsError(try rules.move("g1","e2"))
        try rules.move("g1","f3")
        XCTAssertEqual(end,rules.board)
        for file in "abcefgh" {
            XCTAssertEqual(end[String(file)+"2"],"wp")
            XCTAssertEqual(end[String(file)+"7"],"bp")
        }
    }
}
