import XCTest
@testable import CheckmateDomain

/// WI-011: forks and pins read from the board's geometry. Recognition only: whether a motif wins material is the
/// bounded search's job (TrainingTacticTests).
final class TrainingRelationshipTests:XCTestCase {
    private func board(_ placement:String)->Position {TrainingMaterial.board(fen:placement+" w - - 0 1")!}
    func testATrueForkNeedsTwoTargetsThatCount(){
        // Two defended pawns are worth less than the knight: attacking them is no fork.
        XCTAssertEqual(TrainingRelationship.forked(by:"c7",board:board("7k/1pN2p2/p3p3/8/8/8/8/4K3")),[])
        // Defended pieces worth more than the knight still count.
        XCTAssertEqual(TrainingRelationship.forked(by:"c7",board:board("7k/1pN2p2/r3q3/8/8/8/8/4K3")),["a6","e6"])
        XCTAssertEqual(TrainingRelationship.forks(by:"w",board:board("7k/1pN2p2/r3q3/8/8/8/8/4K3")),["c7"])
        // One counting target is an attack, not a fork.
        XCTAssertEqual(TrainingRelationship.forked(by:"c7",board:board("7k/2N5/r3p3/8/8/8/8/4K3")),["a6"],"the rook counts; the e6 pawn is protected by that rook along the rank, so it does not")
        XCTAssertEqual(TrainingRelationship.forks(by:"w",board:board("7k/1pN5/p3p3/8/8/8/8/4K3")),[],"only the unprotected e6 pawn counts")
        // The king among the targets always counts.
        XCTAssertEqual(TrainingRelationship.forked(by:"c7",board:board("4k3/2N5/r7/8/8/8/8/4K3")),["a6","e8"])
    }
    func testAKingForksOnlyWhatIsUnprotected(){
        XCTAssertEqual(TrainingRelationship.forked(by:"d4",board:board("7k/8/8/2n1b3/3K4/8/8/8")),["c5","e5"])
        XCTAssertEqual(TrainingRelationship.forked(by:"d4",board:board("7k/8/3p4/2n1b3/3K4/8/8/8")),[],"the pawn on d6 protects both")
    }
    func testAbsoluteAndRelativePins(){
        XCTAssertEqual(TrainingRelationship.pinned(color:"w",board:board("4k3/8/8/8/1b6/2N5/8/4K3")),["c3"],"pinned to its king")
        XCTAssertEqual(TrainingRelationship.pinned(color:"w",board:board("4r1k1/8/8/8/4N3/8/8/K3Q3")),["e4"],"pinned to the queen behind it")
        XCTAssertEqual(TrainingRelationship.pinned(color:"w",board:board("4r1k1/8/8/8/4Q3/8/8/K3N3")),[],"a queen in front of a knight is not pinned")
        XCTAssertEqual(TrainingRelationship.pinned(color:"b",board:board("4k3/8/8/8/8/8/8/K3R3")),[],"a king alone on the line is in check, not pinned")
        XCTAssertEqual(TrainingRelationship.pinned(color:"w",board:board("4k3/8/8/8/1r6/2N5/8/4K3")),[],"a rook does not pin along a diagonal")
    }
    func testRecognitionIsGeometricEvenForAPinnedPiece(){
        // The knight on c3 is pinned to its king, so it may not move; it still attacks, and it still forks on the board.
        let pinnedFork=board("8/8/8/1r1q4/1b6/2N5/8/4K2k")
        XCTAssertEqual(TrainingRelationship.pinned(color:"w",board:pinnedFork),["c3"])
        XCTAssertEqual(TrainingRelationship.forked(by:"c3",board:pinnedFork),["b5","d5"])
    }
}
