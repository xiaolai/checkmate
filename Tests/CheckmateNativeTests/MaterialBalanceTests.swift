import XCTest
@testable import CheckmateNative
import CheckmateCore

/// The captured pieces and material lead (B-10), read from the board's placement against the game's own start.
final class MaterialBalanceTests:XCTestCase {
    private let start="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    func testTheStartingPositionHasNothingCapturedAndNoLead()throws {
        let m=try XCTUnwrap(MaterialBalance(fen:start,start:start))
        XCTAssertEqual(m.captured(by:"w"),[]);XCTAssertEqual(m.captured(by:"b"),[]);XCTAssertEqual(m.lead(for:"w"),0);XCTAssertEqual(m.lead(for:"b"),0)
        XCTAssertTrue(m.isEmpty)
    }
    func testCapturesAreListedForTheCapturingSideMostValuableFirstWithTheLead()throws {
        // White has taken a knight and a pawn; Black has taken a pawn.
        let m=try XCTUnwrap(MaterialBalance(fen:"r1bqkbnr/ppp1pppp/8/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 4",start:start))
        XCTAssertEqual(m.captured(by:"w"),["n","p"]);XCTAssertEqual(m.captured(by:"b"),["p"])
        XCTAssertEqual(m.lead(for:"w"),3);XCTAssertEqual(m.lead(for:"b"),0)
        XCTAssertFalse(m.isEmpty)
    }
    func testAPromotedPawnIsNotCountedAsCaptured()throws {
        // White promoted a pawn to a second queen: it lost no pawn to Black, and its lead counts the new queen.
        let m=try XCTUnwrap(MaterialBalance(fen:"Q3k3/8/8/8/8/8/1PPPPPPP/RNBQKBNR w K - 0 40",start:start))
        XCTAssertEqual(m.captured(by:"b"),[],"the missing pawn became the extra queen")
        XCTAssertEqual(m.captured(by:"w"),["q","r","r","b","b","n","n","p","p","p","p","p","p","p","p"])
        XCTAssertEqual(m.lead(for:"w"),47)
    }
    /// A mini-game starts without most pieces: what it never had was never captured.
    func testAMiniGameCountsCapturesFromItsOwnStart()throws {
        let duel=NetworkMiniGame(try XCTUnwrap(NetworkRuleset(.pawnDuel))),start=duel.board
        XCTAssertTrue(MaterialBalance(board:start,start:MaterialBalance.start(of:duel)).isEmpty,"nothing is captured at the start")
        for uci in ["b2b4","c7c5","b4c5"] {try duel.move(uci:uci)}
        XCTAssertEqual(MaterialBalance.start(of:duel),start,"the start is the kind's own, not the board after the moves")
        let m=MaterialBalance(board:duel.board,start:MaterialBalance.start(of:duel))
        XCTAssertEqual(m.captured(by:"w"),["p"]);XCTAssertEqual(m.captured(by:"b"),[]);XCTAssertEqual(m.lead(for:"w"),1)
    }
    /// A set-up position counts from its own placement; the lead still reads the board shown.
    func testASetUpPositionCountsCapturesFromItsOwnStart()throws {
        let setUp="7k/4P3/8/8/8/8/8/K7 w - - 0 1",m=try XCTUnwrap(MaterialBalance(fen:setUp,start:setUp))
        XCTAssertEqual(m.captured(by:"w"),[]);XCTAssertEqual(m.captured(by:"b"),[],"no full set to be missing from")
        XCTAssertEqual(m.lead(for:"w"),1)
        let rules=try ChessRules(fen:setUp);XCTAssertEqual(MaterialBalance.start(of:rules),rules.board,"no moves: the board is the start")
        try rules.move(uci:"e7e8q");XCTAssertEqual(MaterialBalance.start(of:rules),try XCTUnwrap(TrainingMaterial.board(fen:setUp)),"the start is the position before the first move")
        let promoted=MaterialBalance(board:rules.board,start:MaterialBalance.start(of:rules))
        XCTAssertEqual(promoted.captured(by:"b"),[],"the pawn became the queen; nothing was taken");XCTAssertEqual(promoted.captured(by:"w"),[]);XCTAssertEqual(promoted.lead(for:"w"),9)
    }
    /// A pawn gone from a set-up position counts as captured, whatever it may have become first.
    func testAPawnGoneFromASetUpPositionIsCaptured()throws {
        let m=try XCTUnwrap(MaterialBalance(fen:"7k/8/8/8/8/8/8/K7 w - - 0 3",start:"7k/4P3/8/8/8/8/8/K7 w - - 0 1"))
        XCTAssertEqual(m.captured(by:"b"),["p"]);XCTAssertEqual(m.lead(for:"w"),0);XCTAssertFalse(m.isEmpty)
    }
    func testTheRowsReadTopToBottomLikeTheBoard(){
        XCTAssertEqual(MaterialRow.sides(blackAtBottom:false),["b","w"],"White at the bottom: Black's captures on top")
        XCTAssertEqual(MaterialRow.sides(blackAtBottom:true),["w","b"])
    }
    func testAMalformedPlacementIsRefused(){XCTAssertNil(MaterialBalance(fen:"not a fen",start:start));XCTAssertNil(MaterialBalance(fen:start,start:"not a fen"))}
    func testTheSpokenSummaryNamesWhatWasCapturedAndTheLead()throws {
        let m=try XCTUnwrap(MaterialBalance(fen:"r1bqkbnr/ppp1pppp/8/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 4",start:start))
        XCTAssertEqual(MaterialRow.summary(m,side:"w"),"White captured 1 knight and 1 pawn, ahead by 3")
        XCTAssertEqual(MaterialRow.summary(m,side:"b"),"Black captured 1 pawn")
        XCTAssertEqual(MaterialRow.summary(try XCTUnwrap(MaterialBalance(fen:start,start:start)),side:"b"),"Black captured nothing")
    }
}

/// The material row runs top to bottom in the order the board shows the sides, after Flip Board too.
@MainActor final class MaterialOrientationTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}

    func testTheRowFollowsFlipBoardInPracticeAndReview()async throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let orientation=model.boardOrientation
        model.practice();model.session.newGame(side:"b");model.session.cancelWork();game.refresh()
        XCTAssertTrue(game.board.blackAtBottom,"fixture: the learner plays Black");XCTAssertTrue(orientation.blackAtBottom,"practice opens from the learner's side")
        game.flipBoard();XCTAssertFalse(game.board.blackAtBottom,"fixture: the board turned")
        XCTAssertFalse(orientation.blackAtBottom,"the practice row follows Flip Board")
        XCTAssertEqual(MaterialRow.sides(blackAtBottom:orientation.blackAtBottom),["b","w"],"Black, now at the top of the board, is the top row")
        model.reviewCurrent();for _ in 0..<300 where !model.review.active{try await Task.sleep(for:.milliseconds(10))}
        game.refresh();XCTAssertTrue(game.board.blackAtBottom,"fixture: a review of the learner's game opens from Black")
        XCTAssertTrue(orientation.blackAtBottom,"the review row opens from the learner's side")
        game.flipBoard();XCTAssertFalse(game.board.blackAtBottom,"fixture: the board turned")
        XCTAssertFalse(orientation.blackAtBottom,"the review row follows Flip Board")
    }

    /// The class of the defect: a row beside the board that orders by side takes the order from the board drawn
    /// (practice and review) or from the network game's own flip, never from the learner's side.
    func testEveryMaterialRowTakesItsOrderFromTheBoard()throws {
        let sources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/CheckmateNative")
        let call=try NSRegularExpression(pattern:#"MaterialRow\(balance:.*?blackAtBottom:([\w.]+)"#)
        var found:[String]=[]
        for url in try FileManager.default.contentsOfDirectory(at:sources,includingPropertiesForKeys:nil) where url.pathExtension=="swift" {
            let text=try String(contentsOf:url,encoding:.utf8)
            for match in call.matches(in:text,range:NSRange(text.startIndex...,in:text)) {found.append(url.lastPathComponent+" "+(Range(match.range(at:1),in:text).map{String(text[$0])} ?? ""))}
        }
        XCTAssertEqual(found.count,3,"the scan sees practice, review and the network game: \(found)")
        for row in found {XCTAssertTrue(row.hasSuffix(" orientation.blackAtBottom") || row=="NetworkViews.swift game.blackAtBottom","\(row): order the row by the board shown")}
    }
}
