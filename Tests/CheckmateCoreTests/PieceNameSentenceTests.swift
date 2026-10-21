import XCTest
@testable import CheckmateApplication
@testable import CheckmateDomain
import CheckmateRules

/// A sentence names a piece with its article or possessive as one catalog phrase for each use, so a language can make the
/// article agree with the piece. The English reads exactly as it did when the article was a word of the sentence.
final class PieceNameSentenceTests:XCTestCase {
    func testEachUseKeepsItsEnglish() {
        let english:[(PieceName.Use,String?,String)]=[(.subject,"n","the knight"),(.opening,"q","The queen"),(.object,"p","the pawn"),(.anyOpening,"b","A bishop"),(.anyObject,"r","a rook"),(.became,"q","a queen"),(.promotedTo,"N","a knight"),(.yoursSubject,"k","your king"),(.yoursObject,"r","your rook"),(.noneOwned,"q","no queen"),(.noneOpening,"n","No knight"),(.moveOpening,"p","Pawn"),(.played,"b","bishop"),(.object,nil,"the piece"),(.moveOpening,"x","Piece")]
        for (use,letter,text) in english {XCTAssertEqual(PieceName.phrase(letter,use),text,"\(use) \(letter ?? "nil")")}
        let nouns=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
        for (letter,noun) in nouns {
            XCTAssertEqual(PieceName.phrase(letter,.subject),"the "+noun);XCTAssertEqual(PieceName.phrase(letter,.object),"the "+noun);XCTAssertEqual(PieceName.phrase(letter,.played),noun)
            XCTAssertEqual(PieceName.phrase(letter,.moveOpening),noun.prefix(1).uppercased()+noun.dropFirst());XCTAssertEqual(PieceName.phrase(letter,.anyObject),"a "+noun)
            XCTAssertEqual(PieceName.bracketed("w",letter),"the white "+noun);XCTAssertEqual(PieceName.bracketed("b",letter),"the black "+noun)
        }
        XCTAssertEqual(PieceName.bracketed("b",nil),"the black piece")
    }

    func testTypedMoveRefusalsKeepTheirEnglish()throws {
        func refusal(_ text:String,_ fen:String?=nil)throws -> String {
            let rules=try ChessRules(fen:fen)
            guard case .refused(let reason)=TypedMove.resolve(text,moves:rules.moves(),board:rules.board,turn:rules.turn,enPassant:rules.enPassantTarget,inCheck:rules.check,squaresAsTyped:false) else{XCTFail("\(text) was not refused");return ""}
            return reason
        }
        XCTAssertEqual(try refusal("g8f6"),"The knight on g8 is Black's, and it's White's move.")
        XCTAssertEqual(try refusal("Qad4","4k3/8/8/8/8/8/8/4K3 w - - 0 1"),"You have no queen there.")
        XCTAssertEqual(try refusal("Qd4","4k3/8/8/8/8/8/8/4K3 w - - 0 1"),"You have no queen.")
        XCTAssertEqual(try refusal("Nf6"),"No knight of yours can move to f6.")
        let board=try ChessRules().board
        XCTAssertEqual(TypedMove.refusal(piece:"wn",from:"b1",to:"b3",board:board,enPassant:nil,inCheck:false),"A knight cannot move from b1 to b3.")
        // Only the first letter of a spelled count is raised: "Twenty-one", never "Twenty-One".
        XCTAssertEqual(TypedMove.spelled(2,locale:Locale(identifier:"en")),"Two");XCTAssertEqual(TypedMove.spelled(21,locale:Locale(identifier:"en")),"Twenty-one")
        XCTAssertEqual(try refusal("Nd2","7k/8/8/8/8/5N2/8/1N2K3 w - - 0 1"),"Two knights can move to d2. Type which one, such as Nbd2 or Nfd2.")
    }

    func testReviewFactsKeepTheirEnglish()throws {
        func facts(_ pgn:String)throws -> [String:String] {
            let document=try PGNImporter.parse(Data(pgn.utf8))[0]
            return Dictionary(try ReviewExplanation.make(document:document,node:document.mainline.last!).facts.map{($0.kind,$0.text)},uniquingKeysWith:{a,_ in a})
        }
        let capture=try facts("1. e4 d5 2. exd5 *")
        XCTAssertEqual(capture["move"],"White moved the pawn from e4 to d5.");XCTAssertEqual(capture["capture"],"This captures the pawn on d5.")
        let knight=try facts("1. e4 d5 2. Nc3 *")
        XCTAssertEqual(knight["move"],"White moved the knight from b1 to c3.");XCTAssertEqual(knight["coverage"],"The knight on c3 covers d5. Check pins and legal replies before treating coverage as a capture.")
        let centre=try XCTUnwrap(try facts("1. Nf3 *")["centre"])
        XCTAssertTrue(centre.hasPrefix("From f3, the knight controls ") && centre.hasSuffix(" in the center."),centre)
        let promotion=try facts("[SetUp \"1\"]\n[FEN \"7k/P7/8/8/8/8/8/7K w - - 0 1\"]\n1. a8=Q *")
        XCTAssertEqual(promotion["promotion"],"The pawn became a queen.")
    }

    @MainActor func testMoveDescriptionsAndHintsKeepTheirEnglish()throws {
        let session=try GameSession(engine:nil)
        func described(_ fen:String?,_ uci:String)throws -> MoveFacts {try session.moveFacts(try ChessRules(fen:fen),uci:uci)}
        let knight=try described(nil,"g1f3")
        XCTAssertEqual(knight.description,"Knight g1 to f3.");XCTAssertEqual(GameSession.pieceHint(knight),"Try moving your knight on g1. Ask for another hint to see the move.")
        XCTAssertEqual(try described("4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1","e4d5").description,"Pawn e4 to d5, capturing the pawn on d5.")
        XCTAssertEqual(try described("8/P7/8/8/8/8/8/K6k w - - 0 1","a7a8r").description,"Pawn a7 to a8. Promotes to a rook.")
    }

    func testRecaptureExplanationsKeepTheirEnglish() {
        func explained(_ canRecapture:Bool)->String {PieceRelationship(square:"e5",piece:"p",color:"b",status:"",coverage:true,enPassant:false,responses:[CaptureReply(attackerSquare:"f3",attackerPiece:"n",captureSAN:"Nxe5",destination:"e5",canRecapture:canRecapture,recaptures:[])]).explanation(mode:.protected,legalContext:true,king:false)}
        XCTAssertEqual(explained(true),"Can recapture on e5 after the knight on f3 plays Nxe5.")
        XCTAssertEqual(explained(false),"Cannot recapture after the knight on f3 plays Nxe5; that recapture would leave its own king in check.")
    }

    func testNetworkMovesAreWholeSentences()throws {
        let ben=NetworkWording.Players(white:"Ben",black:"Ana",learner:.black)
        func said(_ moves:[String],from fen:String?=nil)throws -> String {
            let rules=try ChessRules(fen:fen);var last:MoveRecord?
            for move in moves{last=try rules.move(uci:move)}
            return NetworkWording.move(try XCTUnwrap(last),players:ben)
        }
        XCTAssertEqual(try said(["e1g1"],from:"5k2/8/8/8/8/8/8/4K2R w K - 0 1"),"Ben castled kingside, check")
        XCTAssertEqual(try said(["e8c8"],from:"r3k3/8/8/8/8/8/8/3K4 b q - 0 1"),"You castled queenside, check")
        XCTAssertEqual(try said(["d1d8"],from:"3rk3/8/8/8/8/8/8/3QK3 w - - 0 1"),"Ben played queen to d8, capturing a rook, check")
        XCTAssertEqual(try said(["b7b8q"],from:"7k/1P6/8/8/8/8/8/4K3 w - - 0 1"),"Ben played pawn to b8, promoting to a queen, check")
        XCTAssertEqual(try said(["b7a8q"],from:"r6k/1P6/8/8/8/8/8/4K3 w - - 0 1"),"Ben played pawn to a8, capturing a rook, promoting to a queen, check")
        XCTAssertEqual(try said(["e5d6"],from:"4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"),"Ben played pawn to d6, capturing a pawn en passant")
        XCTAssertEqual(NetworkWording.miniGame(.pawnDuel),"Pawn Duel: "+MiniGameKind.pawnDuel.rules)
    }
}
