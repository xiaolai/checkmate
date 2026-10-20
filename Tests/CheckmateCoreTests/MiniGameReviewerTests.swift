import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication

/// WI-018: the post-game review owner. A review starts only when a game finishes, runs off the main actor, and a restart,
/// undo or navigation during it leaves no stale result.
@MainActor final class MiniGameReviewerTests:XCTestCase {
    /// White to move takes the last black pawn (a1xa7) and wins at once.
    static func almostWon()->MiniGameState {
        var game=MiniGameState(kind:.rookSweep);game.snapshot.board=["a1":"wr","h2":"wp","e5":"br","a7":"bp"];return game
    }
    func player()throws->(GameSession,LearningPlayer) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.pieceDuration=0;session.state.miniGames=[MiniGameKind.rookSweep.rawValue:Self.almostWon()]
        player.openLesson(index:try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="rook-practice"}));player.startMini(.rookSweep)
        XCTAssertEqual(player.miniGame?.board,Self.almostWon().board)
        return (session,player)
    }
    func waitFor(_ condition:@escaping ()->Bool)async throws {for _ in 0..<200 {if condition(){return};try await Task.sleep(for:.milliseconds(20))}}
    /// Holds the review at its first clock reading until released; it still notices its own cancellation.
    final class Gate:@unchecked Sendable {private let lock=NSLock();private var open=false
        func release(){lock.lock();open=true;lock.unlock()}
        var released:Bool {lock.lock();defer{lock.unlock()};return open}
        var clock:@Sendable ()->Double {{[self] in while !released && !Task.isCancelled{Thread.sleep(forTimeInterval:0.002)};return 0}}
    }

    func testFinishingAGameShowsItsProvedFacts()async throws {
        let (_,player)=try player()
        XCTAssertEqual(player.miniReview.status,.idle,"nothing is reviewed during play")
        player.click("a1");player.click("a7");XCTAssertEqual(player.miniGame?.winner,"w")
        try await waitFor{player.miniReview.review != nil}
        let review=try XCTUnwrap(player.miniReview.review)
        XCTAssertTrue(player.miniReview.sheetOpen);XCTAssertTrue(review.consistent);XCTAssertTrue(review.complete)
        XCTAssertEqual(review.facts.map(\.text),["Move 1: you had a forced win in 1 move here."])
        XCTAssertEqual(player.miniReview.identity,MiniGameReviewer.Identity(try XCTUnwrap(player.miniGame)))
        player.miniReview.dismissSheet();XCTAssertFalse(player.miniReview.sheetOpen);player.miniReview.showSheet();XCTAssertTrue(player.miniReview.sheetOpen)
        player.restartMini();XCTAssertEqual(player.miniReview.status,.idle);XCTAssertFalse(player.miniReview.sheetOpen)
        player.shutdown()
    }
    func testRestartUndoAndNavigationDuringAnalysisLeaveNoStaleResult()async throws {
        for interruption in ["restart","undo","leave","lesson","opponent"] {
            let (_,player)=try player(),gate=Gate();player.miniReview.cpuSeconds=gate.clock
            player.click("a1");player.click("a7");XCTAssertEqual(player.miniReview.status,.running,interruption)
            switch interruption {
            case "restart":player.restartMini()
            case "undo":player.undoMini()
            case "leave":player.leaveMini()
            case "lesson":player.openLesson(index:0)
            default:player.setMiniComputer(false)
            }
            XCTAssertEqual(player.miniReview.status,.idle,interruption);gate.release()
            try await Task.sleep(for:.milliseconds(150))
            XCTAssertEqual(player.miniReview.status,.idle,interruption);XCTAssertFalse(player.miniReview.sheetOpen,interruption)
            player.shutdown()
        }
    }
    func testAResultForAnotherGameIsNeverShown()async throws {
        let reviewer=MiniGameReviewer(),gate=Gate();reviewer.cpuSeconds=gate.clock
        var finished=Self.almostWon();XCTAssertTrue(finished.play(MiniGameMove(from:"a1",to:"a7")))
        var shown=finished;reviewer.current={shown}
        reviewer.start(Self.almostWon());XCTAssertEqual(reviewer.status,.idle,"an unfinished game is not reviewed")
        reviewer.start(finished);XCTAssertEqual(reviewer.status,.running)
        shown.opponentSeed="another run";gate.release()
        try await Task.sleep(for:.milliseconds(300))
        XCTAssertEqual(reviewer.status,.idle);XCTAssertNil(reviewer.identity)
        shown=finished;let fresh=Gate();reviewer.cpuSeconds=fresh.clock;reviewer.start(finished);fresh.release()
        try await waitFor{reviewer.review != nil};XCTAssertEqual(reviewer.review?.run,finished.opponentSeed)
    }
    func testNarrationIsOnlyTheProvedFactsExactText()throws {
        var game=MiniGameState(kind:.rookSweep);game.snapshot.board=["a1":"wr","h2":"wp","e5":"br","a7":"bp"]
        for move in [("a1","b1"),("e5","h5"),("b1","b2"),("h5","h2")] {XCTAssertTrue(game.play(MiniGameMove(from:move.0,to:move.1)))}
        let review=MiniGameReview.run(game,cpuSeconds:{0},stop:{false});XCTAssertEqual(review.facts.count,2)
        let segments=try JSONDecoder().decode([SpeechSegment].self,from:JSONSerialization.data(withJSONObject:MiniGameReviewVoiceScript.segments(review)))
        XCTAssertEqual(segments.map(\.text),review.facts.map(\.text))
        XCTAssertNoThrow(try MiniGameReviewVoiceScript.validate(segments,review:review))
        func segment(_ text:String,_ squares:[String])throws->[SpeechSegment] {try JSONDecoder().decode([SpeechSegment].self,from:JSONSerialization.data(withJSONObject:[["text":text,"squares":squares,"kind":"focus"]]))}
        XCTAssertThrowsError(try MiniGameReviewVoiceScript.validate(try segment(review.facts[0].text+" Well played!",review.facts[0].squares),review:review))
        XCTAssertThrowsError(try MiniGameReviewVoiceScript.validate(try segment(review.facts[0].text,["h8"]),review:review))
        XCTAssertThrowsError(try MiniGameReviewVoiceScript.validate(try segment("White was winning all along.",[]),review:review))
    }
}
