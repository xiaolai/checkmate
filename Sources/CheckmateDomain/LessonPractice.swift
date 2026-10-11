import CheckmateAssets
import Foundation
/// Complete, legal positions for trying a lesson against an opponent rather than copying a recorded line.
public struct LessonPractice:Equatable {
    public let lessonID:String,fen:String,goal:String
    public static let presets:[Self]=[
        .init(lessonID:"pawn",fen:"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",goal:"Try h2 to h3. After the computer replies, that pawn can advance only to h4."),
        .init(lessonID:"castling",fen:"4k3/pp3ppp/8/8/8/8/PPP2PPP/R3K2R w KQ - 0 1",goal:"Select the king on e1, then g1 or c1 to castle."),
        .init(lessonID:"castling-rules",fen:"4k3/pp3ppp/8/8/8/8/PPP2PPP/R3K2R w KQ - 0 1",goal:"Select the king, then its two-square destination. The rook moves automatically."),
        .init(lessonID:"promotion-en-passant",fen:"8/4P3/3q1k2/8/8/8/8/K7 w - - 0 1",goal:"Move the pawn to e8. Choosing a knight checks the king and attacks the queen.") ,
        .init(lessonID:"scholars-mate",fen:"r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4",goal:"Look for a threat against the king. The computer may defend differently."),
        .init(lessonID:"fork",fen:"r3k3/8/8/1N6/8/8/8/7K w - - 0 1",goal:"Use the knight to attack two valuable pieces at once."),
        .init(lessonID:"pin",fen:"3k4/8/8/4p3/3n4/8/4P3/3R3K w - - 0 1",goal:"Attack the pinned knight, but check which replies are legal."),
        .init(lessonID:"skewer",fen:"1q6/8/8/1k6/8/8/8/4K2R w - - 0 1",goal:"Line up the rook against the king and the piece behind it."),
        .init(lessonID:"discovered-attack",fen:"3k4/7q/8/3N4/8/8/P7/K2R4 w - - 0 1",goal:"Move the knight to reveal the rook's attack. Look for a second threat."),
        .init(lessonID:"removing-the-defender",fen:"2b1k3/8/n7/8/8/7Q/8/R6K w - - 0 1",goal:"Remove the bishop defending the knight, then consider Black's reply."),
        .init(lessonID:"two-rook-mate",fen:"8/8/8/4k3/8/8/8/1RRK4 w - - 0 1",goal:"Use the rooks to restrict the king and give checkmate."),
        .init(lessonID:"queen-mate",fen:"8/8/8/4k3/8/8/8/3QK3 w - - 0 1",goal:"Restrict the king, bring your own king closer, and avoid stalemate."),
        .init(lessonID:"rook-mate",fen:"8/8/8/3k4/2R5/3K4/8/8 w - - 0 1",goal:"Make a smaller box with the rook. Protect it with your king.")
    ]
    public static func forLesson(_ id:String)->Self? {presets.first{$0.lessonID==id}}
}
