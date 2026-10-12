import XCTest
@testable import CheckmateDomain

/// WI-009: material values and the deterministic defence-method tags. Tags explain technique only; whether a move
/// actually saves the piece is the bounded search's job (TrainingDefenseTests).
final class TrainingMaterialTests:XCTestCase {
    private func moved(_ board:Position,_ from:String,_ to:String,removing captured:String?=nil)->Position {
        var after=board;let piece=after.removeValue(forKey:from);if let captured{after.removeValue(forKey:captured)};after[to]=piece;return after
    }
    private func tags(_ board:Position,_ from:String,_ to:String,target:String,removing:String?=nil)->Set<TrainingMaterial.DefenseMethod> {
        TrainingMaterial.defenseTags(before:board,after:moved(board,from,to,removing:removing),from:from,to:to,target:target,learner:"w")
    }
    func testValuesAndFENBoards(){
        XCTAssertEqual(["p","n","b","r","q","k"].map{TrainingMaterial.value("w"+$0)},[1,3,3,5,9,0])
        let board:Position=["e1":"wk","e8":"bk","d1":"wq","a8":"br","b7":"bp","c3":"wn"]
        XCTAssertEqual(TrainingMaterial.board(fen:"r3k3/1p6/8/8/8/2N5/8/3QK3 w - - 0 1"),board)
        XCTAssertNil(TrainingMaterial.board(fen:"r3k3/1p6/8/8/8/2N5/8 w - - 0 1"),"seven ranks is malformed")
        XCTAssertNil(TrainingMaterial.board(fen:"r3k4/8/8/8/8/8/8/4K3 w - - 0 1"),"nine files is malformed")
        XCTAssertEqual(TrainingMaterial.between("a1","a5"),["a2","a3","a4"]);XCTAssertEqual(TrainingMaterial.between("c1","f4"),["d2","e3"]);XCTAssertNil(TrainingMaterial.between("a1","b3"))
    }
    func testEachMethodAndTheOtherTag(){
        // The knight on c3 is attacked by the pawn on d4.
        let pawn:Position=["e1":"wk","e8":"bk","c3":"wn","d4":"bp","d1":"wr","f2":"wb","h2":"wp"]
        XCTAssertEqual(tags(pawn,"c3","e2",target:"c3"),[.moveAway])
        XCTAssertEqual(tags(pawn,"d1","d4",target:"c3",removing:"d4"),[.captureAttacker])
        XCTAssertEqual(tags(pawn,"f2","d4",target:"c3",removing:"d4"),[.captureAttacker,.protect],"the bishop on d4 also guards c3")
        XCTAssertEqual(tags(pawn,"h2","h3",target:"c3"),[.other],"a move unrelated to the threat")
        // The rook on a1 is attacked down the file by the rook on a8: a bishop can block.
        let file:Position=["e1":"wk","h8":"bk","a1":"wr","a8":"br","c2":"wb"]
        XCTAssertEqual(tags(file,"c2","a4",target:"a1"),[.block])
        // The knight on e5 is attacked by the enemy king; a pawn move protects it.
        let king:Position=["e1":"wk","f6":"bk","e5":"wn","d2":"wp"]
        XCTAssertEqual(tags(king,"d2","d4",target:"e5"),[.protect])
    }
    func testDoubleTagsAndTrackingThePieces(){
        // The threatened rook takes its attacker: it moved away and captured the attacker.
        let rooks:Position=["e1":"wk","h8":"bk","a5":"wr","a8":"br","h4":"wr"]
        XCTAssertEqual(tags(rooks,"a5","a8",target:"a5",removing:"a8"),[.moveAway,.captureAttacker])
        // A rook interposing on the file also defends the rook behind it.
        let block:Position=["e1":"wk","h8":"bk","a1":"wr","a8":"br","h4":"wr"]
        XCTAssertEqual(tags(block,"h4","a4",target:"a1"),[.block,.protect])
        // The same defender relocating along its line is not a new defender.
        let guarded:Position=["e2":"wk","h8":"bk","a1":"wr","a8":"br","h1":"wr"]
        XCTAssertEqual(tags(guarded,"h1","g1",target:"a1"),[.other])
        // En passant removes the attacking pawn from a square the capturing pawn never lands on.
        let passant:Position=["e1":"wk","e8":"bk","e4":"wn","d5":"bp","e5":"wp"]
        XCTAssertEqual(tags(passant,"e5","d6",target:"e4",removing:"d5"),[.captureAttacker])
    }
    func testForksCountOnlyRealTargets(){
        // A knight forking king and rook; a knight attacking two defended pawns is no fork.
        let fork:Position=["e1":"wk","e8":"bk","c7":"wn","a8":"br","g7":"bp","f6":"bp","d5":"wn"]
        XCTAssertEqual(TrainingRelationship.forked(by:"c7",board:fork),["e8","a8"])
        XCTAssertEqual(TrainingRelationship.forks(by:"w",board:fork),["c7"],"d5 hits only the defended pawn on f6")
        // A queen attacking two undefended pieces of lower value still forks; two defended ones do not.
        let queen:Position=["a1":"wk","h8":"bk","d4":"wq","b6":"bn","f6":"bb"]
        XCTAssertEqual(TrainingRelationship.forks(by:"w",board:queen),["d4"])
        var guarded=queen;guarded["c7"]="bp";guarded["g7"]="bp"
        XCTAssertEqual(TrainingRelationship.forks(by:"w",board:guarded),[],"defended pieces worth less than the queen are not forked")
        // A king forks only undefended pieces.
        let king:Position=["e4":"wk","h8":"bk","d5":"bn","f5":"bb","a1":"wr"]
        XCTAssertEqual(TrainingRelationship.forks(by:"w",board:king),["e4"])
    }
    func testPinsToTheKingAndToMoreValuablePieces(){
        // Absolute: the knight on e5 stands between the rook on e1 and its king on e8.
        let absolute:Position=["e1":"wr","g1":"wk","e5":"bn","e8":"bk"]
        XCTAssertEqual(TrainingRelationship.pinned(color:"b",board:absolute),["e5"])
        // Relative: a knight in front of its queen on a bishop's diagonal; a knight in front of a pawn is not pinned.
        let relative:Position=["b2":"wb","g1":"wk","d4":"bn","f6":"bq","h8":"bk","a5":"wr","c5":"bn","d5":"bp"]
        XCTAssertEqual(TrainingRelationship.pinned(color:"b",board:relative),["d4"])
        // Two pieces in front of the king: neither is pinned. The king itself is never pinned.
        let screened:Position=["e1":"wr","g1":"wk","e4":"bn","e6":"bp","e8":"bk"]
        XCTAssertEqual(TrainingRelationship.pinned(color:"b",board:screened),[])
        XCTAssertEqual(TrainingRelationship.pinned(color:"w",board:absolute),[],"no black sliders")
    }
}
