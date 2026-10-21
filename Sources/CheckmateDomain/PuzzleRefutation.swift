import CheckmateAssets
import Foundation
/// Why a wrong puzzle answer fails, in one plain sentence (L-7). A board puzzle's line comes from the position: what
/// refutes the move, or what the chosen square lacks. A choice puzzle's line is authored with the puzzle. The lines are
/// text only and never recorded, so feedback that carries one stays silent, as L-10's text-only units do.
public enum PuzzleRefutation {
    static let values:[String:Int]=["p":1,"n":3,"b":3,"r":5,"q":9,"k":100]
    /// The line for `answer` (a choice, a move as from and to, or the chosen squares); nil for a right answer or a
    /// puzzle without a board or claim. `notes` holds the claims and authored lines.
    public static func line(_ puzzle:Puzzle,answer:[String],notes:PuzzleNotes)->String? {
        let e=puzzle.exercise,note=notes[puzzle.id]
        switch e.kind {
        case "choice":return answer.count==1 ? note?.why?[answer[0]]:nil
        case "move":guard let board=puzzle.board,let claim=note?.claim,answer.count==2,!e.matches(answer) else{return nil};return move(board,from:answer[0],to:answer[1],claim:claim)
        case "squares":guard let board=puzzle.board,let claim=note?.claim,!e.matches(answer) else{return nil};return squares(board,picked:answer,answers:e.answers ?? [],claim:claim)
        default:return nil
        }
    }
    /// A king step onto an attacked square: the piece that attacks it.
    public static func unsafeStep(_ board:Position,from:String,to:String)->String? {
        guard let king=board[from],let side=king.first else{return nil}
        var next=board;next[from]=nil;next[to]=king
        guard let attacker=cheapest(TrainingGeometry.attackers(of:to,color:other(side),board:next),next) else{return nil}
        return String(localized:"\(kind(next[attacker]!,.opening)) on \(attacker) attacks \(to).",bundle:.checkmate)
    }

    // MARK: Moves
    private static func move(_ board:Position,from:String,to:String,claim:PuzzleNotes.Claim)->String? {
        guard let piece=board[from],let side=piece.first else{return nil}
        let enemy=other(side),ep=claim.enPassant,castle=piece.last=="k" && from.last==to.last && abs(file(from)-file(to))==2
        if claim.type=="castle" && !castle{return String(localized:"That move is not castling. To castle, move the king two squares toward a rook.",bundle:.checkmate)}
        if castle {if let refusal=castling(board,from:from,to:to,claim:claim){return refusal}}
        else if !reach(board,from:from,enPassant:ep).contains(to) {
            if let b=blocker(board,from:from,to:to){return inTheWay(board,b)}
            return String(localized:"\(kind(piece,.anyOpening)) cannot move from \(from) to \(to).",bundle:.checkmate)
        }
        let after=play(board,from:from,to:to,enPassant:ep),moved=after[to] ?? piece
        if inCheck(after,side){return inCheck(board,side) ? String(localized:"After that move, your king is still in check.",bundle:.checkmate):String(localized:"That move would put your own king in check.",bundle:.checkmate)}
        let recapture=cheapest(TrainingGeometry.attackers(of:to,color:enemy,board:after),after)
        switch claim.type {
        case "mate":guard inCheck(after,enemy) else{return String(localized:"That move does not give check, so it is not checkmate.",bundle:.checkmate)};return escape(after,side:enemy) ?? String(localized:"That move gives check, but it is not checkmate.",bundle:.checkmate)
        case "check":return inCheck(after,enemy) ? nil:String(localized:"That move does not give check.",bundle:.checkmate)
        case "safe-capture":
            guard board[to] != nil || (piece.last=="p" && to==ep) else{return String(localized:"That move does not capture anything.",bundle:.checkmate)}
            return recapture.map{String(localized:"\(kind(after[$0]!,.opening)) on \($0) can capture \(kind(moved,.yoursObject)) back.",bundle:.checkmate)}
        case "fork":
            if let r=recapture{return String(localized:"\(kind(after[r]!,.opening)) on \(r) can capture \(kind(moved,.yoursObject)) on \(to).",bundle:.checkmate)}
            let targets=TrainingGeometry.attacks(from:to,board:after).filter{after[$0]?.first==enemy && (values[String(after[$0]!.suffix(1))] ?? 0)>=3}.sorted()
            if targets.count==1{return String(localized:"From \(to), \(kind(moved,.yoursSubject)) attacks only \(kind(after[targets[0]]!,.object)) on \(targets[0]).",bundle:.checkmate)}
            return String(localized:"From \(to), \(kind(moved,.yoursSubject)) does not attack two of your opponent's pieces.",bundle:.checkmate)
        case "promote":return String(localized:"Only a pawn that reaches the last rank becomes a new piece.",bundle:.checkmate)
        default:return nil
        }
    }
    /// Why a two-square king move is not a legal castle here; nil when it is.
    private static func castling(_ board:Position,from:String,to:String,claim:PuzzleNotes.Claim)->String? {
        let side=board[from]!.first!,kingside=file(to)>file(from),right=Character(side=="w" ? (kingside ? "K":"Q"):(kingside ? "k":"q"))
        guard (claim.castling ?? "").contains(right),let rank=from.last,let rook=TrainingGeometry.square(kingside ? 7:0,Int(String(rank))!-1),board[rook]==String(side)+"r" else{return String(localized:"Castling is not allowed in this position.",bundle:.checkmate)}
        if let b=between(board,from:from,to:rook){return inTheWay(board,b)}
        let path=[from,TrainingGeometry.square((file(from)+file(to))/2,Int(String(rank))!-1)!,to]
        return path.contains{!TrainingGeometry.attackers(of:$0,color:other(side),board:board).isEmpty} ? String(localized:"The king may not castle out of check, through an attacked square or into check.",bundle:.checkmate):nil
    }
    /// How the side in check gets out: a king step first, then a capture of the checking piece, then a block.
    private static func escape(_ board:Position,side:Character,checkers given:Set<String>?=nil)->String? {
        guard let king=king(board,side) else{return nil}
        let checkers=TrainingGeometry.attackers(of:king,color:other(side),board:board)
        let replies=board.filter{$0.value.first==side}.keys.sorted().flatMap{from in reach(board,from:from,enPassant:nil).sorted().map{(from:from,to:$0)}}.filter{!inCheck(play(board,from:$0.from,to:$0.to,enPassant:nil),side)}
        if let step=replies.first(where:{$0.from==king}){return String(localized:"The king can escape to \(step.to).",bundle:.checkmate)}
        if let take=replies.first(where:{checkers.contains($0.to)}){return String(localized:"\(kind(board[take.from]!,.opening)) on \(take.from) can capture \(kind(board[take.to]!,.yoursObject)).",bundle:.checkmate)}
        return replies.first.map{String(localized:"\(PieceName.side(String(side))) can block the check on \($0.to).",bundle:.checkmate)}
    }

    // MARK: Squares
    private static func squares(_ board:Position,picked:[String],answers:[String],claim:PuzzleNotes.Claim)->String? {
        if let s=picked.first(where:{!answers.contains($0)}){return square(board,s,answers:answers,claim:claim)}
        let missing=Set(answers).subtracting(picked).count
        return missing>0 ? String(localized:"\(missing) more squares are still missing.",bundle:.checkmate):nil
    }
    private static func square(_ board:Position,_ s:String,answers:[String],claim:PuzzleNotes.Claim)->String? {
        let here=board[s]
        switch claim.type {
        case "locate":
            if answers.count==1{return String(localized:"That square is \(s), not \(answers[0]).",bundle:.checkmate)}
            return claim.piece.map{String(localized:"That is not where \(PieceName.the(String($0.prefix(1)),String($0.suffix(1)))) stands.",bundle:.checkmate)}
        case "destinations","attacks":
            guard let from=claim.square,let piece=board[from] else{return nil}
            if claim.type=="destinations",let here,here.first==piece.first{return String(localized:"\(kind(piece,.opening)) on \(from) cannot land on \(s), where a piece of its own side stands.",bundle:.checkmate)}
            if let b=blocker(board,from:from,to:s){return inTheWay(board,b)}
            if claim.type=="attacks"{return String(localized:"\(kind(piece,.opening)) on \(from) does not attack \(s).",bundle:.checkmate)}
            return reach(board,from:from,enPassant:claim.enPassant).contains(s) ? String(localized:"Moving there would put \(PieceName.the(String(piece.prefix(1)),"k")) in check.",bundle:.checkmate):String(localized:"\(kind(piece,.anyOpening)) cannot move from \(from) to \(s).",bundle:.checkmate)
        case "attackers":
            guard let target=claim.square,let c=claim.colour?.first else{return nil}
            guard let here else{return empty(s)}
            if here.first != c{return belongs(here,s)}
            if let b=blocker(board,from:s,to:target){return inTheWay(board,b)}
            return String(localized:"\(kind(here,.opening)) on \(s) does not attack \(target).",bundle:.checkmate)
        case "attacked-pieces":
            guard let c=claim.colour?.first else{return nil}
            guard let here else{return empty(s)}
            if here.first==c{return belongs(here,s)}
            return String(localized:"\(PieceName.side(String(c))) does not attack \(kind(here,.object)) on \(s).",bundle:.checkmate)
        case "undefended":
            guard let c=claim.colour?.first else{return nil}
            guard let here else{return empty(s)}
            if here.first != c{return belongs(here,s)}
            if here.last=="k"{return String(localized:"The king never counts here: it can never be captured.",bundle:.checkmate)}
            return cheapest(TrainingGeometry.defenders(of:s,board:board),board).map{String(localized:"\(kind(board[$0]!,.opening)) on \($0) defends \(kind(here,.object)) on \(s).",bundle:.checkmate)}
        default:return nil
        }
    }

    // MARK: Board
    /// A board piece ("wn") named by its kind as one phrase for `use`, so the article agrees with the piece in any language.
    private static func kind(_ piece:String,_ use:PieceName.Use)->String {PieceName.phrase(String(piece.suffix(1)),use)}
    private static func inTheWay(_ board:Position,_ square:String)->String {String(localized:"\(kind(board[square]!,.opening)) on \(square) is in the way.",bundle:.checkmate)}
    private static func empty(_ square:String)->String {String(localized:"There is no piece on \(square).",bundle:.checkmate)}
    private static func belongs(_ piece:String,_ square:String)->String {String(localized:"\(kind(piece,.opening)) on \(square) belongs to \(PieceName.side(String(piece.prefix(1)))).",bundle:.checkmate)}
    private static func other(_ side:Character)->Character {side=="w" ? "b":"w"}
    private static func file(_ square:String)->Int {TrainingGeometry.coordinates(square)?.file ?? 0}
    private static func king(_ board:Position,_ side:Character)->String? {board.first{$0.value==String(side)+"k"}?.key}
    private static func inCheck(_ board:Position,_ side:Character)->Bool {king(board,side).map{!TrainingGeometry.attackers(of:$0,color:other(side),board:board).isEmpty} ?? false}
    /// The least valuable of `squares`' pieces, then the first square: the capture a learner should notice first.
    private static func cheapest(_ squares:Set<String>,_ board:Position)->String? {squares.min{(values[String(board[$0]?.suffix(1) ?? "")] ?? 0,$0)<(values[String(board[$1]?.suffix(1) ?? "")] ?? 0,$1)}}
    /// Where the piece on `from` can go, ignoring check: own pieces block; a pawn steps forward and captures diagonally,
    /// or en passant onto `enPassant`.
    private static func reach(_ board:Position,from:String,enPassant:String?)->Set<String> {
        guard let piece=board[from] else{return []}
        if piece.last=="p"{var result=Set(CourseLibrary.pawnMoves(board,from:from));if let ep=enPassant,board[ep]==nil,TrainingGeometry.attacks(from:from,board:board).contains(ep){result.insert(ep)};return result}
        return TrainingGeometry.attacks(from:from,board:board).filter{board[$0]?.first != piece.first}
    }
    /// The first piece standing between a sliding piece on `from` and `to` on one of its lines; nil off its lines.
    private static func blocker(_ board:Position,from:String,to:String)->String? {
        guard let piece=board[from],"brq".contains(piece.suffix(1)),let a=TrainingGeometry.coordinates(from),let b=TrainingGeometry.coordinates(to) else{return nil}
        let dx=b.file-a.file,dy=b.rank-a.rank,straight=dx==0 || dy==0,diagonal=abs(dx)==abs(dy)
        guard dx != 0 || dy != 0,(piece.hasSuffix("r") && straight) || (piece.hasSuffix("b") && diagonal) || (piece.hasSuffix("q") && (straight || diagonal)) else{return nil}
        return between(board,from:from,to:to)
    }
    /// The first piece strictly between two squares on one rank, file or diagonal; nil when the line is clear.
    private static func between(_ board:Position,from:String,to:String)->String? {
        guard let a=TrainingGeometry.coordinates(from),let b=TrainingGeometry.coordinates(to) else{return nil}
        let dx=b.file-a.file,dy=b.rank-a.rank;guard dx==0 || dy==0 || abs(dx)==abs(dy) else{return nil}
        let sx=dx.signum(),sy=dy.signum();var x=a.file+sx,y=a.rank+sy
        while x != b.file || y != b.rank {if let square=TrainingGeometry.square(x,y),board[square] != nil{return square};x+=sx;y+=sy}
        return nil
    }
    /// The board after a move: a pawn reaching the last rank becomes a queen, en passant removes the passed pawn and
    /// castling brings the rook across.
    private static func play(_ board:Position,from:String,to:String,enPassant:String?)->Position {
        var next=board;guard let piece=next.removeValue(forKey:from),let a=TrainingGeometry.coordinates(from),let b=TrainingGeometry.coordinates(to) else{return board}
        if piece.last=="p",to==enPassant,board[to]==nil,let passed=TrainingGeometry.square(b.file,a.rank){next[passed]=nil}
        if piece.last=="k",abs(a.file-b.file)==2,let rook=TrainingGeometry.square(b.file>a.file ? 7:0,a.rank),let landing=TrainingGeometry.square((a.file+b.file)/2,a.rank),let r=next.removeValue(forKey:rook){next[landing]=r}
        next[to]=piece.last=="p" && (b.rank==7 || b.rank==0) ? String(piece.prefix(1))+"q":piece
        return next
    }
}
/// Each puzzle's details the refutation reads beyond the course model (L-7): what a board puzzle asks, and a choice
/// puzzle's authored lines. They are read from the course resource on their own, so the course model, one of the
/// mini-game calibration's sources, stays as it was calibrated.
public struct PuzzleNotes:Decodable {
    /// What a board puzzle asks, as `Tools/prepare-lesson-scripts.py` checks it: `square` the piece or target it is
    /// about, `colour` the side whose pieces count, `side` the side to move, `piece` the piece to find.
    public struct Claim:Decodable,Equatable {public let type:String;public let square:String?,colour:String?,side:String?,piece:String?,castling:String?,enPassant:String?}
    /// A puzzle's claim, and for a choice puzzle the line for each wrong choice.
    public struct Note:Decodable {public let claim:Claim?;public let why:[String:String]?}
    private struct Entry:Decodable {let id:String,exercise:Note}
    private enum CodingKeys:String,CodingKey {case puzzles}
    private let notes:[String:Note]
    public init(from d:Decoder)throws {notes=Dictionary(try d.container(keyedBy:CodingKeys.self).decode([Entry].self,forKey:.puzzles).map{($0.id,$0.exercise)},uniquingKeysWith:{first,_ in first})}
    public init()throws {self=try JSONDecoder().decode(Self.self,from:Data(contentsOf:NativeResources.url("course.json")))}
    public subscript(_ id:String)->Note? {notes[id]}
}
