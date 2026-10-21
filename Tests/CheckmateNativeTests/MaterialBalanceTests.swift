import XCTest
@testable import CheckmateNative
import CheckmateCore

/// The captured pieces and material lead (B-10), read from the board's placement alone.
final class MaterialBalanceTests:XCTestCase {
    private let start="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    func testTheStartingPositionHasNothingCapturedAndNoLead()throws {
        let m=try XCTUnwrap(MaterialBalance(fen:start))
        XCTAssertEqual(m.captured(by:"w"),[]);XCTAssertEqual(m.captured(by:"b"),[]);XCTAssertEqual(m.lead(for:"w"),0);XCTAssertEqual(m.lead(for:"b"),0)
        XCTAssertTrue(m.isEmpty)
    }
    func testCapturesAreListedForTheCapturingSideMostValuableFirstWithTheLead()throws {
        // White has taken a knight and a pawn; Black has taken a pawn.
        let m=try XCTUnwrap(MaterialBalance(fen:"r1bqkbnr/ppp1pppp/8/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 4"))
        XCTAssertEqual(m.captured(by:"w"),["n","p"]);XCTAssertEqual(m.captured(by:"b"),["p"])
        XCTAssertEqual(m.lead(for:"w"),3);XCTAssertEqual(m.lead(for:"b"),0)
        XCTAssertFalse(m.isEmpty)
    }
    func testAPromotedPawnIsNotCountedAsCaptured()throws {
        // White promoted a pawn to a second queen: it lost no pawn to Black, and its lead counts the new queen.
        let m=try XCTUnwrap(MaterialBalance(fen:"Q3k3/8/8/8/8/8/1PPPPPPP/RNBQKBNR w K - 0 40"))
        XCTAssertEqual(m.captured(by:"b"),[],"the missing pawn became the extra queen")
        XCTAssertEqual(m.captured(by:"w"),["q","r","r","b","b","n","n","p","p","p","p","p","p","p","p"])
        XCTAssertEqual(m.lead(for:"w"),47)
    }
    func testTheRowsReadTopToBottomLikeTheBoard(){
        XCTAssertEqual(MaterialRow.sides(blackAtBottom:false),["b","w"],"White at the bottom: Black's captures on top")
        XCTAssertEqual(MaterialRow.sides(blackAtBottom:true),["w","b"])
    }
    func testAMalformedPlacementIsRefused(){XCTAssertNil(MaterialBalance(fen:"not a fen"))}
    func testTheSpokenSummaryNamesWhatWasCapturedAndTheLead()throws {
        let m=try XCTUnwrap(MaterialBalance(fen:"r1bqkbnr/ppp1pppp/8/8/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 4"))
        XCTAssertEqual(MaterialRow.summary(m,side:"w"),"White captured 1 knight and 1 pawn, ahead by 3")
        XCTAssertEqual(MaterialRow.summary(m,side:"b"),"Black captured 1 pawn")
        XCTAssertEqual(MaterialRow.summary(try XCTUnwrap(MaterialBalance(fen:start)),side:"b"),"Black captured nothing")
    }
}
