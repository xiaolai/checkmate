import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


final class MiniGameTests:XCTestCase {
    func testPlayableSetupsMatchAuthoredLessonBoards()throws {
        let library=try CourseLibrary()
        for (kind,lesson,step) in [(MiniGameKind.pawnDuel,"pawn-duel",1),(.rookSweep,"rook-practice",1),(.rooksAndPawns,"rook-practice",9),(.bishopSweep,"bishop-practice",1),(.bishopsAndPawns,"bishop-practice",10),(.queenVsPawns,"queen-practice",1),(.knightCapture,"knight-practice",1),(.knightCorners,"knight-practice",11)] {
            let index=try XCTUnwrap(library.lessons.firstIndex{$0.id==lesson})
            XCTAssertEqual(kind.initialBoard,try library.frame(lesson:index,step:step,seconds:0).board,kind.rawValue)
        }
    }
    func testEveryCompetitiveGameHasLegalComputerReply()throws {
        for kind in MiniGameKind.allCases where !kind.solo {
            var game=MiniGameState(kind:kind)
            XCTAssertNil(game.winner,kind.rawValue)
            let white=try XCTUnwrap(MiniGameRules.moves(board:game.board,kind:kind,side:"w").first)
            XCTAssertTrue(game.play(white));XCTAssertEqual(game.turn,"b")
            let started=Date(),black=try XCTUnwrap(MiniGameOpponent.choose(in:game),kind.rawValue)
            XCTAssertTrue(game.destinations(from:black.from).contains(black.to));XCTAssertTrue(game.play(black));XCTAssertEqual(game.turn,"w")
            print("MINI-OPPONENT \(kind.rawValue) seconds=\(Date().timeIntervalSince(started))")
        }
    }
    func testOpponentStopsPromotionAndAvoidsLosingQueen()throws {
        var race=MiniGameState(kind:.rooksAndPawns);race.snapshot.board=["e8":"wp","a2":"wp","e6":"br"];race.snapshot.turn="b";race.snapshot.pendingFinish="w"
        XCTAssertEqual(MiniGameOpponent.choose(in:race),MiniGameMove(from:"e6",to:"e8"))
        var chase=MiniGameState(kind:.queenVsPawns);chase.snapshot.board=["e4":"bq","c4":"wp","d3":"wp","e5":"wp"];chase.snapshot.turn="b"
        XCTAssertNotEqual(try XCTUnwrap(MiniGameOpponent.choose(in:chase)).to,"c4")
    }
    /// Knight Capture's win is every other opposing piece, never the knight itself: taking the knight wins at once
    /// because its owner has no move, while the knight is not counted among the targets still on the board.
    func testKnightCaptureWinsByEveryOtherPiece() {
        var game=MiniGameState(kind:.knightCapture,computer:false)
        game.snapshot.board=["a1":"wn","b2":"wp","h8":"bn","b3":"bp","c5":"bp"]
        XCTAssertTrue(game.play(MiniGameMove(from:"a1",to:"b3")))
        XCTAssertNil(game.winner,"one target taken; the knight and another target remain")
        XCTAssertTrue(game.play(MiniGameMove(from:"h8",to:"f7")))
        XCTAssertTrue(game.play(MiniGameMove(from:"b3",to:"c5")))
        XCTAssertEqual(game.winner,"w","every other black piece is gone, although the black knight remains")
        var duel=MiniGameState(kind:.knightCapture,computer:false)
        duel.snapshot.board=["e4":"wn","f6":"bn","h2":"wp","h7":"bp"]
        XCTAssertTrue(duel.play(MiniGameMove(from:"e4",to:"f6")))
        XCTAssertEqual(duel.winner,"w","taking the knight wins at once; it never had to be a target")
    }
    func testFrozenPawnsAndCaptureGoals()throws {
        for kind in [MiniGameKind.rookSweep,.bishopSweep,.knightCapture] {
            let game=MiniGameState(kind:kind)
            XCTAssertTrue(MiniGameRules.moves(board:game.board,kind:kind,side:"w").allSatisfy{!game.board[$0.from]!.hasSuffix("p")})
        }
        var hunt=MiniGameState(kind:.rookSweep);hunt.snapshot.board=["a1":"wr","h2":"wp","a3":"bp","h8":"br"]
        XCTAssertTrue(hunt.play(MiniGameMove(from:"a1",to:"a3")));XCTAssertEqual(hunt.winner,"w")
        var horse=MiniGameState(kind:.knightCapture);horse.snapshot.board=["e4":"wn","f6":"bn","h2":"wp","h7":"bp"]
        XCTAssertTrue(horse.play(MiniGameMove(from:"e4",to:"f6")));XCTAssertEqual(horse.winner,"w")
    }
    func testPawnMustSurviveOpponentReplyAndPawnDuelWinsImmediately() {
        var game=MiniGameState(kind:.rooksAndPawns)
        game.snapshot.board=["e7":"wp","a2":"wp","e6":"br"]
        XCTAssertTrue(game.play(MiniGameMove(from:"e7",to:"e8")));XCTAssertNil(game.winner)
        XCTAssertTrue(game.play(MiniGameMove(from:"e6",to:"e8")));XCTAssertNil(game.winner)
        game=MiniGameState(kind:.queenVsPawns);game.snapshot.board=["e7":"wp","h2":"bp","a8":"bq"]
        XCTAssertTrue(game.play(MiniGameMove(from:"e7",to:"e8")));XCTAssertNil(game.winner)
        XCTAssertTrue(game.play(MiniGameMove(from:"h2",to:"h1")));XCTAssertEqual(game.winner,"w","Earlier finishing pawn survives even if Black also reaches its far rank")
        game=MiniGameState(kind:.pawnDuel);game.snapshot.board=["e7":"wp","h7":"bp"]
        XCTAssertTrue(game.play(MiniGameMove(from:"e7",to:"e8")));XCTAssertEqual(game.winner,"w")
    }
    func testSlidersCannotJumpAndBlockedSideLoses() {
        let board=["a1":"wr","a3":"wp","d1":"bp","h8":"br","h7":"bp"]
        let moves=MiniGameRules.moves(board:board,kind:.rooksAndPawns,side:"w").filter{$0.from=="a1"}.map(\.to)
        XCTAssertTrue(moves.contains("d1"));XCTAssertFalse(moves.contains("e1"));XCTAssertFalse(moves.contains("a4"))
        var blocked=MiniGameState(kind:.pawnDuel);blocked.snapshot.board=["a3":"wp","a4":"bp"]
        XCTAssertEqual(blocked.winner,"b")
    }
    func testKnightCornersAvoidsPawnsAndAttacksAndCompletesOrderedCorners()throws {
        var game=MiniGameState(kind:.knightCorners)
        for target in MiniGameRules.corners {
            let start=try XCTUnwrap(game.board.first{$0.value=="wn"}?.key)
            var queue=[start],visited:Set<String>=[start],parent:[String:String]=[:],index=0
            while index<queue.count,!visited.contains(target) {
                let square=queue[index];index+=1
                var board=game.board.filter{$0.value != "wn"};board[square]="wn"
                for move in MiniGameRules.moves(board:board,kind:.knightCorners,side:"w") where visited.insert(move.to).inserted {parent[move.to]=square;queue.append(move.to)}
            }
            XCTAssertTrue(visited.contains(target))
            var route=[target],cursor=target
            while cursor != start {cursor=try XCTUnwrap(parent[cursor]);route.append(cursor)}
            for to in route.reversed().dropFirst() {let from=try XCTUnwrap(game.board.first{$0.value=="wn"}?.key);XCTAssertTrue(game.play(MiniGameMove(from:from,to:to)))}
        }
        XCTAssertEqual(game.winner,"w")
    }
    @MainActor func testComputerRepliesInputLocksAndWholeTurnUndo()async throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);session.state.settings.pieceDuration=0
        player.openLesson(index:3);player.startPawnDuel();let initial=player.frame.board
        player.click("g2");player.click("g4");XCTAssertTrue(player.miniThinking)
        player.click("g7");XCTAssertTrue(player.picked.isEmpty)
        for _ in 0..<150 where player.miniThinking {try await Task.sleep(for:.milliseconds(40))}
        XCTAssertFalse(player.miniThinking);XCTAssertEqual(player.miniTurn,"w");XCTAssertEqual(player.miniGame?.history.count,2)
        player.undoMini();XCTAssertEqual(player.frame.board,initial);XCTAssertEqual(player.miniTurn,"w")
        player.click("g2");player.click("g4");player.undoMini()
        try await Task.sleep(for:.milliseconds(600));XCTAssertEqual(player.frame.board,initial);XCTAssertEqual(player.miniTurn,"w")
        player.click("g2");player.click("g4");player.leaveMini()
        let lesson=player.frame;try await Task.sleep(for:.milliseconds(600));XCTAssertEqual(player.frame,lesson);XCTAssertTrue(player.picked.isEmpty)
        player.startMini(.pawnDuel);XCTAssertEqual(player.miniTurn,"b")
        player.restartMini();let restarted=player.frame.board
        try await Task.sleep(for:.milliseconds(600));XCTAssertEqual(player.frame.board,restarted);XCTAssertEqual(player.miniTurn,"w")
        player.shutdown()
    }
    func testSavedGamesRoundTripAndOldArchivesRemainCompatible()throws {
        var state=ApplicationState(),game=MiniGameState(kind:.bishopSweep)
        let move=try XCTUnwrap(MiniGameRules.moves(board:game.board,kind:game.kind,side:"w").first);XCTAssertTrue(game.play(move))
        state.miniGames=[game.kind.rawValue:game];try StateStore.validate(state)
        let decoded=try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(state));XCTAssertEqual(decoded.miniGames,state.miniGames)
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any];object.removeValue(forKey:"miniGames")
        XCTAssertNil(try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object)).miniGames)
        state.miniGames?[game.kind.rawValue]?.snapshot.board=["z9":"wp"];XCTAssertThrowsError(try StateStore.validate(state))
    }
}
