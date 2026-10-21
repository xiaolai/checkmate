import XCTest
@testable import CheckmateDomain
/// Each wrong puzzle answer says why it fails (L-7): on a board, from the position (what refutes it); for a choice,
/// from a line authored with the puzzle.
final class PuzzleRefutationTests:XCTestCase {
    private let library=try! CourseLibrary(),notes=try! PuzzleNotes()
    private func puzzle(_ id:String)throws -> Puzzle {try XCTUnwrap(library.puzzles.first{$0.id==id},id)}
    private func line(_ id:String,_ answer:[String])throws -> String? {PuzzleRefutation.line(try puzzle(id),answer:answer,notes:notes)}
    func testAWrongMoveSaysWhatRefutesIt()throws {
        XCTAssertEqual(try line("extra-1",["f3","e5"]),"The pawn on d6 can capture your knight back.")
        XCTAssertEqual(try line("extra-1",["f3","g5"]),"That move does not capture anything.")
        XCTAssertEqual(try line("extra-1",["f3","f5"]),"A knight cannot move from f3 to f5.")
        XCTAssertEqual(try line("extra-2",["h3","h4"]),"From h4, your pawn does not attack two of your opponent's pieces.")
        XCTAssertEqual(try line("extra-3",["g5","e6"]),"That move does not give check, so it is not checkmate.")
        XCTAssertEqual(try line("course:check-and-checkmate:2",["g1","f1"]),"After that move, your king is still in check.")
        XCTAssertEqual(try line("course:promotion-en-passant:1",["b6","b7"]),"Only a pawn that reaches the last rank becomes a new piece.")
        XCTAssertEqual(try line("course:rules-review:2",["e5","e6"]),"That move does not give check.")
        XCTAssertEqual(try line("course:castling:1",["e1","f1"]),"That move is not castling. To castle, move the king two squares toward a rook.")
        XCTAssertEqual(try line("course:opening:1",["e1","c1"]),"The queen on d1 is in the way.","a castle the other way is blocked by the pieces between king and rook")
    }
    /// A check that is not mate names the way out.
    func testACheckThatIsNotMateNamesTheEscape()throws {
        let json=#"{"id":"t","title":"t","topic":"t","lesson":"t","level":"Foundation","exercise":{"kind":"move","prompt":"p","from":"a1","to":"a7","claim":{"type":"mate","side":"w"}},"board":{"e1":"wk","a1":"wr","e8":"bk"},"highlights":[],"context":"","explanation":"e"}"#
        let p=try JSONDecoder().decode(Puzzle.self,from:Data(json.utf8)),own=try JSONDecoder().decode(PuzzleNotes.self,from:Data((#"{"puzzles":["#+json+"]}").utf8))
        XCTAssertEqual(PuzzleRefutation.line(p,answer:["a1","a8"],notes:own),"The king can escape to d7.")
    }
    func testAWrongSquareSaysWhyItIsNotOne()throws {
        XCTAssertEqual(try line("extra-4",["a7"]),"The knight on c6 defends the pawn on a7.")
        XCTAssertEqual(try line("extra-4",["d1"]),"The rook on d1 belongs to White.")
        XCTAssertEqual(try line("extra-4",["g8"]),"The king never counts here: it can never be captured.")
        XCTAssertEqual(try line("extra-4",["e4"]),"There is no piece on e4.")
        XCTAssertEqual(try line("extra-4",["b7"]),"1 more square is still missing.")
        XCTAssertEqual(try line("extra-4",[]),"2 more squares are still missing.")
        XCTAssertEqual(try line("course:intro:2",["c1"]),"The bishop on c1 does not attack e8.")
        XCTAssertEqual(try line("course:intro:2",["h7"]),"The pawn on h7 belongs to Black.")
        XCTAssertEqual(try line("course:board:1",["c6"]),"That square is c6, not f6.")
        XCTAssertEqual(try line("course:setting-up:2",["a8"]),"That is not where the black knight stands.")
        XCTAssertEqual(try line("course:knight-practice:2",["d6"]),"The pawn on e5 does not attack d6.")
    }
    /// Every wrong answer a learner can give gets its own line: every move from a piece of the side to move, every
    /// square, every missing square and every authored wrong choice.
    func testEveryWrongAnswerHasALine()throws {
        let squares:[String]=(0..<64).compactMap{TrainingGeometry.square($0%8,$0/8)}
        func check(_ p:Puzzle,_ answer:[String]){
            guard let text=PuzzleRefutation.line(p,answer:answer,notes:notes) else{return XCTFail("\(p.id) \(answer): no line")}
            XCTAssertTrue(text.hasSuffix("."),"\(p.id) \(answer): \(text)");XCTAssertFalse(text.contains("nil") || text.contains("Optional") || text.contains("  "),"\(p.id): \(text)")
        }
        var counted=(choice:0,move:0,squares:0)
        for p in library.puzzles {
            let e=p.exercise
            switch e.kind {
            case "choice":
                let wrong=(e.choices ?? []).filter{$0 != e.answer};XCTAssertEqual(Set(notes[p.id]?.why?.keys.map{$0} ?? []),Set(wrong),"\(p.id): one authored line per wrong choice")
                for choice in wrong {check(p,[choice]);XCTAssertEqual(PuzzleRefutation.line(p,answer:[choice],notes:notes),notes[p.id]?.why?[choice])};counted.choice+=wrong.count
            case "move":
                let board=try XCTUnwrap(p.board),side=board[try XCTUnwrap(e.from)]!.first!
                for from in squares where board[from]?.first==side {for to in squares where to != from && board[to]?.first != side && !e.matches([from,to]) {check(p,[from,to]);counted.move+=1}}
            case "squares":
                let answers=e.answers ?? []
                for s in squares where !answers.contains(s) {check(p,[s]);counted.squares+=1}
                for s in answers {check(p,answers.filter{$0 != s})}
            default:break
            }
        }
        XCTAssertGreaterThan(counted.choice,30);XCTAssertGreaterThan(counted.move,1000);XCTAssertGreaterThan(counted.squares,1000)
    }
}
