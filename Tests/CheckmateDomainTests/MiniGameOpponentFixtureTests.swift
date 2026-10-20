import XCTest
@testable import CheckmateDomain

/// Rule 9: the mini-game opponent's move choice is frozen. Its choices for seeded positions (35 positions, three
/// profiles each, time limit off) were recorded before the proof search (WI-018) existed; any change to
/// `MiniGameOpponent.choose` that alters one fails here.
final class MiniGameOpponentFixtureTests:XCTestCase {
    /// Positions reached by a seeded random walk from each competitive kind's start, Black to move where possible.
    static func positions(_ kind:MiniGameKind,count:Int=5)->[MiniGameState] {
        var random=UInt64(kind.rawValue.utf8.reduce(7){$0 &* 31 &+ UInt64($1)}),result:[MiniGameState]=[]
        func next(_ n:Int)->Int {random=random &* 6364136223846793005 &+ 1442695040888963407;return Int((random >> 33) % UInt64(n))}
        for index in 0..<count {
            var game=MiniGameState(kind:kind,computer:false);game.opponentSeed=nil
            for _ in 0..<(1+2*index) {
                let moves=MiniGameRules.moves(board:game.board,kind:kind,side:game.turn)
                guard !game.isFinished,!moves.isEmpty else{break}
                var trial=game;trial.play(moves[next(moves.count)])
                if trial.isFinished{break};game=trial
            }
            result.append(game)
        }
        return result
    }
    static func recordedChoices()->String {
        var lines:[String]=[]
        for kind in MiniGameKind.allCases where !kind.solo {
            for (index,game) in positions(kind).enumerated() {
                for profile in ["beginner","standard","challenging"] {
                    let move=MiniGameOpponent.choose(in:game,profile:profile,seed:UInt64(index+1),timeLimited:false)
                    lines.append("\(kind.rawValue) \(index) \(profile) "+(move.map{$0.from+$0.to} ?? "-"))
                }
            }
        }
        return lines.joined(separator:"\n")
    }
    func testOpponentChoicesMatchTheRecording()throws {
        let actual=Self.recordedChoices()
        if let path=ProcessInfo.processInfo.environment["CHECKMATE_RECORD_MINI_OPPONENT"]{try actual.write(toFile:path,atomically:true,encoding:.utf8)}
        let expected=Self.recording.split(separator:"\n").map(String.init),lines=actual.split(separator:"\n").map(String.init)
        XCTAssertEqual(lines.count,expected.count)
        for (line,want) in zip(lines,expected) {XCTAssertEqual(line,want)}
    }
    static let recording="""
pawn-duel 0 beginner f7f5
pawn-duel 0 standard d7d5
pawn-duel 0 challenging d7d5
pawn-duel 1 beginner c7c5
pawn-duel 1 standard c7c5
pawn-duel 1 challenging c7c6
pawn-duel 2 beginner d7e6
pawn-duel 2 standard d7e6
pawn-duel 2 challenging d7e6
pawn-duel 3 beginner c7c5
pawn-duel 3 standard c7c5
pawn-duel 3 challenging c7c5
pawn-duel 4 beginner c7c5
pawn-duel 4 standard g7g5
pawn-duel 4 challenging g7g5
rook-sweep 0 beginner g8g3
rook-sweep 0 standard g8h8
rook-sweep 0 challenging g8h8
rook-sweep 1 beginner c8b8
rook-sweep 1 standard c8c6
rook-sweep 1 challenging c8c6
rook-sweep 2 beginner h8h6
rook-sweep 2 standard h8h7
rook-sweep 2 challenging h8h6
rook-sweep 3 beginner a6a4
rook-sweep 3 standard a6a5
rook-sweep 3 challenging a6a5
rook-sweep 4 beginner f2f5
rook-sweep 4 standard f2f4
rook-sweep 4 challenging f2f5
rooks-and-pawns 0 beginner d8d1
rooks-and-pawns 0 standard e8e4
rooks-and-pawns 0 challenging e8e4
rooks-and-pawns 1 beginner d8d7
rooks-and-pawns 1 standard d8d7
rooks-and-pawns 1 challenging d8d7
rooks-and-pawns 2 beginner d8d2
rooks-and-pawns 2 standard d8d2
rooks-and-pawns 2 challenging d8d2
rooks-and-pawns 3 beginner e4e1
rooks-and-pawns 3 standard e4h4
rooks-and-pawns 3 challenging e4h4
rooks-and-pawns 4 beginner d8d2
rooks-and-pawns 4 standard d8d2
rooks-and-pawns 4 challenging d8d2
bishop-sweep 0 beginner d7e6
bishop-sweep 0 standard g7f8
bishop-sweep 0 challenging g7f8
bishop-sweep 1 beginner f6g5
bishop-sweep 1 standard f6g5
bishop-sweep 1 challenging f6g5
bishop-sweep 2 beginner f5e4
bishop-sweep 2 standard f5e4
bishop-sweep 2 challenging f5e4
bishop-sweep 3 beginner f7e6
bishop-sweep 3 standard g7f8
bishop-sweep 3 challenging g7f8
bishop-sweep 4 beginner d7e6
bishop-sweep 4 standard d7e6
bishop-sweep 4 challenging d7e6
bishops-and-pawns 0 beginner g7g5
bishops-and-pawns 0 standard d8f6
bishops-and-pawns 0 challenging d8f6
bishops-and-pawns 1 beginner d8h4
bishops-and-pawns 1 standard d8h4
bishops-and-pawns 1 challenging d8h4
bishops-and-pawns 2 beginner g7g5
bishops-and-pawns 2 standard d8e7
bishops-and-pawns 2 challenging d8e7
bishops-and-pawns 3 beginner e8c6
bishops-and-pawns 3 standard e8c6
bishops-and-pawns 3 challenging e8c6
bishops-and-pawns 4 beginner f6h4
bishops-and-pawns 4 standard c7c6
bishops-and-pawns 4 challenging c7c6
queen-vs-pawns 0 beginner e8e2
queen-vs-pawns 0 standard e8e2
queen-vs-pawns 0 challenging e8e2
queen-vs-pawns 1 beginner c6f3
queen-vs-pawns 1 standard c6c2
queen-vs-pawns 1 challenging c6c2
queen-vs-pawns 2 beginner b7b2
queen-vs-pawns 2 standard b7b2
queen-vs-pawns 2 challenging b7b2
queen-vs-pawns 3 beginner c6c2
queen-vs-pawns 3 standard c6c2
queen-vs-pawns 3 challenging c6c2
queen-vs-pawns 4 beginner c4b5
queen-vs-pawns 4 standard c4e2
queen-vs-pawns 4 challenging c4e2
knight-capture 0 beginner g8f6
knight-capture 0 standard g8f6
knight-capture 0 challenging g8f6
knight-capture 1 beginner f6d7
knight-capture 1 standard f6e4
knight-capture 1 challenging f6e4
knight-capture 2 beginner e8f6
knight-capture 2 standard e8g7
knight-capture 2 challenging e8g7
knight-capture 3 beginner f6e4
knight-capture 3 standard f6e4
knight-capture 3 challenging f6e4
knight-capture 4 beginner g6e7
knight-capture 4 standard g6e7
knight-capture 4 challenging g6e7
"""
}
