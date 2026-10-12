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
        let li=try XCTUnwrap(course.lessons.firstIndex{$0.id=="intro"}),si=try XCTUnwrap(course.lessons[li].beats.firstIndex{$0.id=="intro:8"})
        let narration=course.voices[li][si].seconds,duration=CourseTiming.standard.pieceDuration
        let landed=try XCTUnwrap(course.moveTimes(lesson:li,step:si,narrationSeconds:narration,pieceDuration:duration).last)+duration
        for seconds in [0,landed-duration/2,landed-0.01] {
            let frame=try course.frame(lesson:li,step:si,seconds:seconds)
            XCTAssertTrue(frame.arrows.isEmpty,"no arrow before the rook lands (\(seconds)s)")
            XCTAssertFalse(frame.hl.contains{$0.kind=="check"},"no check before the rook lands (\(seconds)s)")
        }
        let after=try course.frame(lesson:li,step:si,seconds:landed)
        XCTAssertEqual(after.board?["a8"],"wr")
        XCTAssertEqual(after.arrows,[["a8","g8"]],"the attack arrow ends on the king it attacks")
        XCTAssertEqual(after.hl,[Highlight(sq:"g8",kind:"check")])
    }
    /// An arrow that previews the beat's own move, or that the previous beat already showed, stays up during the move.
    func testMovePreviewsAndCarriedOverlaysStayDuringTheMove() throws {
        let course=try CourseLibrary()
        func frame(_ id:String)throws -> CourseFrame {
            let li=try XCTUnwrap(course.lessons.firstIndex{$0.beats.contains{$0.id==id}}),si=try XCTUnwrap(course.lessons[li].beats.firstIndex{$0.id==id})
            return try course.frame(lesson:li,step:si,seconds:0)
        }
        XCTAssertEqual(try frame("rook-mate:16").arrows,[["f7","g7"]],"a preview of the coming move")
        XCTAssertEqual(try frame("scholars-mate:7").arrows,[["c4","f7"]],"carried over from the previous beat")
        XCTAssertEqual(try frame("scholars-mate:8").arrows,[["c4","f7"]],"the queen's new arrow waits for the queen")
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
        let pairs=["pawn":"pawn-duel","rook":"rook-practice","bishop":"bishop-practice","queen":"queen-practice","knight":"knight-practice","king":"safe-squares"]
        XCTAssertEqual(Set(course.lessons.filter(\.isPractice).map(\.id)),Set(pairs.values))
        for (parent,child) in pairs {
            XCTAssertEqual(course.practice(for:try index(parent)),[try index(child)],parent)
            XCTAssertEqual(course.practice(for:try index(child)),[],"an activity has no practice of its own")
        }
        for (from,to) in [("pawn","rook"),("pawn-duel","rook"),("king","check-and-checkmate"),("safe-squares","check-and-checkmate"),("board","pawn")] {
            XCTAssertEqual(course.nextMainLesson(after:try index(from)),try index(to),from)
        }
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
        let li=try XCTUnwrap(course.lessons.firstIndex{$0.id=="knight"})
        let si=try XCTUnwrap(course.lessons[li].beats.firstIndex{$0.id=="knight:16"})
        let start=try XCTUnwrap(course.frame(lesson:li,step:si,seconds:0).board)
        let end=try XCTUnwrap(course.frame(lesson:li,step:si,seconds:course.voices[li][si].duration).board)
        let rules=try ChessRules()
        XCTAssertEqual(start,rules.board)
        XCTAssertEqual(Set(rules.moves("g1").map(\.to)),Set(["f3","h3"]))
        XCTAssertThrowsError(try rules.move("g1","e2"))
        try rules.move("g1","f3")
        XCTAssertEqual(end,rules.board)
        for file in "abcdefgh" {
            XCTAssertEqual(end[String(file)+"2"],"wp")
            XCTAssertEqual(end[String(file)+"7"],"bp")
        }
    }
}
