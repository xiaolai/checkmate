import CheckmateAssets
import CheckmateDomain
/// Why castling to one side is or is not allowed (plan: Special Moves). The reasons form a set; curated questions
/// have exactly one, and a question offers every label.
public enum TrainingCastleReason:String,CaseIterable {
    case allowed,moved,blocked,check,transit,destination
    public var label:String {switch self {
        case .allowed:return String(localized:"Yes, castling is allowed",bundle:.checkmate)
        case .moved:return String(localized:"No: the king or that rook has already moved",bundle:.checkmate)
        case .blocked:return String(localized:"No: a piece is in the way",bundle:.checkmate)
        case .check:return String(localized:"No: the king is in check",bundle:.checkmate)
        case .transit:return String(localized:"No: the king would cross an attacked square",bundle:.checkmate)
        case .destination:return String(localized:"No: the king would land on an attacked square",bundle:.checkmate)
    }}
    public static let choices=allCases.map(\.label)
}
/// Whether a pawn can be captured en passant now, and if not, why. History decides timing, so the context moves
/// must show how the pawn arrived.
public enum TrainingPassantReason:String,CaseIterable {
    case allowed,notDouble,expired,exposesKing,notBeside
    public var label:String {switch self {
        case .allowed:return String(localized:"Yes, en passant is allowed",bundle:.checkmate)
        case .notDouble:return String(localized:"No: that pawn did not just move two squares",bundle:.checkmate)
        case .expired:return String(localized:"No: the chance has passed",bundle:.checkmate)
        case .exposesKing:return String(localized:"No: it would leave your king in check",bundle:.checkmate)
        case .notBeside:return String(localized:"No: none of your pawns stands beside it",bundle:.checkmate)
    }}
    public static let choices=allCases.map(\.label)
}
@MainActor public enum TrainingSpecialRules {
    /// Every legal castling move for the side to move.
    public static func castlingMoves(_ legality:TrainingLegality)throws -> Set<String> {Set(try legality.outcomes().filter{$0.flags.contains("k") || $0.flags.contains("q")}.map(\.uci))}
    public static func promotions(_ legality:TrainingLegality)throws -> Set<String> {Set(try legality.outcomes().filter{$0.promotion != nil}.map(\.uci))}
    public static func enPassantMoves(_ legality:TrainingLegality)throws -> Set<String> {Set(try legality.outcomes().filter{$0.flags.contains("e")}.map(\.uci))}
    /// The reasons for castling towards `destination` (the king's castled square) for the side to move.
    public static func castleReasons(_ legality:TrainingLegality,destination:String)throws -> Set<TrainingCastleReason> {
        let turn=try legality.turn(),rank=turn=="w" ? "1":"8",opponent:Character=turn=="w" ? "b":"w"
        guard ["c"+rank,"g"+rank].contains(destination) else{throw CheckmateError.invalid(String(localized:"The castling square must be c or g on the side to move's back rank.",bundle:.checkmate))}
        let kingside=destination.first=="g",home="e"+rank,board=try legality.board()
        if try castlingMoves(legality).contains(home+destination){return [.allowed]}
        let right:Character=kingside ? (turn=="w" ? "K":"k"):(turn=="w" ? "Q":"q")
        let rights=legality.fen.split(separator:" ")[2],between=(kingside ? ["f","g"]:["b","c","d"]).map{$0+rank}
        let attacked={(square:String) in !TrainingGeometry.attackers(of:square,color:opponent,board:board).isEmpty}
        // A king away from home has moved, yet a blocked path and check still count, so a curated question has
        // exactly one reason. The squares it would cross matter only from home; the displaced king never blocks.
        let atHome=board[home]==turn+"k";var reasons=Set<TrainingCastleReason>()
        if !atHome || !rights.contains(right){reasons.insert(.moved)}
        if between.contains(where:{board[$0] != nil && board[$0] != turn+"k"}){reasons.insert(.blocked)}
        // A checkmated king is in check too: castling is refused for the same reason.
        let status=try legality.status();if status == .check || status == .checkmate{reasons.insert(.check)}
        if atHome,attacked((kingside ? "f":"d")+rank){reasons.insert(.transit)}
        if atHome,attacked(destination){reasons.insert(.destination)}
        return reasons
    }
    /// The reasons the enemy pawn on `target` can or cannot be captured en passant by the side to move, judged from
    /// the context moves that brought it there. Throws when the history does not show how it arrived.
    public static func passantReasons(_ legality:TrainingLegality,target:String,prelude:[String])throws -> Set<TrainingPassantReason> {
        let turn=try legality.turn(),board=try legality.board(),enemy=turn=="w" ? "b":"w"
        guard board[target]==enemy+"p",let (file,rank)=TrainingGeometry.coordinates(target),rank==(turn=="w" ? 4:3) else{throw CheckmateError.invalid(String(localized:"The marked square must hold an enemy pawn on the en-passant rank.",bundle:.checkmate))}
        guard let index=prelude.lastIndex(where:{$0.dropFirst(2).prefix(2)==target}) else{throw CheckmateError.invalid(String(localized:"The context moves must show how the pawn arrived.",bundle:.checkmate))}
        let arrival=prelude[index],from=String(arrival.prefix(2)),double=from==TrainingGeometry.square(file,rank+(turn=="w" ? 2:-2))
        let behind=TrainingGeometry.square(file,rank+(turn=="w" ? 1:-1))!
        let beside=[file-1,file+1].compactMap{TrainingGeometry.square($0,rank)}.contains{board[$0]==turn+"p"}
        if try enPassantMoves(legality).contains(where:{$0.hasSuffix(behind)}){return [.allowed]}
        var reasons=Set<TrainingPassantReason>()
        if !beside{reasons.insert(.notBeside)}
        if !double{reasons.insert(.notDouble)}
        else if index != prelude.count-1{reasons.insert(.expired)}
        else if beside{reasons.insert(.exposesKing)}
        return reasons
    }
}
