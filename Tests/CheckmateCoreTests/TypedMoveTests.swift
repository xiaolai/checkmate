import XCTest
@testable import CheckmateDomain
@testable import CheckmateRules

/// B-23: a typed move, in SAN or in squares, resolves against the position's moves, and a refusal says why.
final class TypedMoveTests:XCTestCase {
    private func resolve(_ text:String,_ fen:String?=nil,asTyped:Bool=false)throws -> TypedMove.Resolution {
        let rules=try ChessRules();if let fen{try rules.load(fen)}
        return TypedMove.resolve(text,moves:rules.moves(),board:rules.board,turn:rules.turn,inCheck:rules.check,squaresAsTyped:asTyped)
    }
    private func move(_ from:String,_ to:String,_ promotion:String?=nil)->TypedMove.Resolution {.move(TypedMove.Choice(from:from,to:to,promotion:promotion))}
    private func refusal(_ resolution:TypedMove.Resolution,file:StaticString=#filePath,line:UInt=#line)->String {guard case .refused(let text)=resolution else{XCTFail("expected a refusal, got \(resolution)",file:file,line:line);return ""};return text}

    func testSANAndSquaresBothResolve()throws {
        XCTAssertEqual(try resolve("e4"),move("e2","e4"))
        XCTAssertEqual(try resolve("Nf3"),move("g1","f3"))
        XCTAssertEqual(try resolve("nf3"),move("g1","f3"),"a lowercase piece letter other than b is read as the piece")
        XCTAssertEqual(try resolve("g1f3"),move("g1","f3"))
        XCTAssertEqual(try resolve("g1-f3"),move("g1","f3"))
        XCTAssertEqual(try resolve("  e4+ "),move("e2","e4"),"check marks and spaces are ignored")
    }
    func testUnreadableAndEmptyInputExplainTheForm()throws {
        XCTAssertEqual(refusal(try resolve("")),"Type a move, such as e4 or Nf3.")
        XCTAssertEqual(refusal(try resolve("hello")),"“hello” is not a move. Type a move such as e4, Nf3, O-O or e2e4.")
    }
    func testAMoveThePositionRefusesSaysWhy()throws {
        XCTAssertEqual(refusal(try resolve("e5")),"A pawn cannot move from e2 to e5.")
        XCTAssertEqual(refusal(try resolve("Ke2")),"That square holds your own piece.")
        XCTAssertEqual(refusal(try resolve("e7e5")),"The pawn on e7 is Black's, and it's White's move.")
        XCTAssertEqual(refusal(try resolve("e3e4")),"There's no piece on e3.")
        XCTAssertEqual(refusal(try resolve("Nf6")),"No knight of yours can move to f6.")
        XCTAssertEqual(refusal(try resolve("Qd4","4k3/8/8/8/8/8/8/4K3 w - - 0 1")),"You have no queen.")
    }
    func testAnAmbiguousMoveAsksWhichPiece()throws {
        let fen="7k/8/8/8/8/5N2/8/1N2K3 w - - 0 1"
        XCTAssertEqual(refusal(try resolve("Nd2",fen)),"Two knights can move to d2. Type which one, such as Nbd2 or Nfd2.")
        XCTAssertEqual(try resolve("Nbd2",fen),move("b1","d2"))
        XCTAssertEqual(try resolve("Nfd2",fen),move("f3","d2"))
    }
    func testCheckIsExplained()throws {
        let fen="4r2k/8/8/8/8/8/8/R3K3 w - - 0 1"
        XCTAssertEqual(refusal(try resolve("Ra2",fen)),"That move does not get your king out of check.")
        XCTAssertEqual(refusal(try resolve("Ke2",fen)),"Your king would be attacked on e2.")
        XCTAssertEqual(refusal(try resolve("O-O-O",fen)),"You cannot castle while your king is in check.")
        XCTAssertEqual(try resolve("Kd1",fen),move("e1","d1"))
        XCTAssertEqual(refusal(try resolve("Rb1","k3r3/8/8/8/8/8/4R3/4K3 w - - 0 1")),"A rook cannot move from e2 to b1.")
        XCTAssertEqual(refusal(try resolve("Ra2","k3r3/8/8/8/8/8/4R3/4K3 w - - 0 1")),"That move would leave your king in check.")
    }
    func testPromotionNeedsItsPiece()throws {
        let fen="4k3/P7/8/8/8/8/8/4K3 w - - 0 1"
        XCTAssertEqual(refusal(try resolve("a8",fen)),"Add the piece to promote to, such as a8=Q.")
        XCTAssertEqual(refusal(try resolve("a7a8",fen)),"Add the piece to promote to, such as a7a8q.")
        XCTAssertEqual(try resolve("a8=N",fen),move("a7","a8","n"))
        XCTAssertEqual(try resolve("a8Q",fen),move("a7","a8","q"))
        XCTAssertEqual(try resolve("a7a8q",fen),move("a7","a8","q"))
        XCTAssertEqual(refusal(try resolve("e2e4q")),"Only a pawn reaching the last rank promotes.")
    }
    func testCastlingInEitherNotation()throws {
        let fen="r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
        XCTAssertEqual(try resolve("O-O",fen),move("e1","g1"))
        XCTAssertEqual(try resolve("0-0-0",fen),move("e1","c1"))
        XCTAssertEqual(try resolve("e1g1",fen),move("e1","g1"))
        XCTAssertEqual(refusal(try resolve("O-O")),"Castling kingside is not allowed here.")
    }
    func testAPawnCaptureAndABishopShareTheLetterB()throws {
        let fen="4k3/8/8/8/8/2n5/1P1B4/4K3 w - - 0 1"
        XCTAssertEqual(try resolve("bxc3",fen),move("b2","c3"))
        XCTAssertEqual(try resolve("Bxc3",fen),move("d2","c3"))
        XCTAssertEqual(try resolve("bc3",fen),move("b2","c3"),"a lowercase b is the pawn's file first")
        XCTAssertEqual(try resolve("bc3","4k3/8/8/8/8/2n5/3B4/4K3 w - - 0 1"),move("d2","c3"),"and the bishop when no pawn can")
    }
    /// A graded exercise judges a raw attempt itself: squares go through as typed, and SAN is read from where the pieces
    /// can reach, without the legal moves.
    func testAGradedExerciseGetsTheMoveAsTyped()throws {
        XCTAssertEqual(try resolve("e2e5",asTyped:true),move("e2","e5"))
        let rules=try ChessRules(),board=rules.board
        XCTAssertEqual(TypedMove.resolve("Nf3",moves:TypedMove.reachable(board:board,turn:"w",enPassant:nil),board:board,turn:"w",inCheck:false),move("g1","f3"))
        XCTAssertEqual(TypedMove.resolve("e4",moves:TypedMove.reachable(board:board,turn:"w",enPassant:nil),board:board,turn:"w",inCheck:false),move("e2","e4"))
        let check:Position=["e1":"wk","e8":"br","h8":"bk","a1":"wr"]
        XCTAssertEqual(TypedMove.resolve("Ra2",moves:TypedMove.reachable(board:check,turn:"w",enPassant:nil),board:check,turn:"w",inCheck:true),move("a1","a2"),"reachable is not legal: the exercise grades it")
        XCTAssertEqual(TypedMove.resolve("O-O",moves:TypedMove.reachable(board:["e1":"wk","h1":"wr"],turn:"w",enPassant:nil),board:["e1":"wk","h1":"wr"],turn:"w",inCheck:false),move("e1","g1"))
    }
    /// A board with its own rules and no king (a mini-game) never blames a king that is not there.
    func testABoardWithoutAKingRefusesPlainly(){
        let board:Position=["e2":"wp","d7":"bp"]
        XCTAssertEqual(TypedMove.resolve("e2e3",moves:[],board:board,turn:"w",inCheck:false),.refused("That move is not allowed here."))
    }
}
