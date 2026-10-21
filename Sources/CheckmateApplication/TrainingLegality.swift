import CheckmateDomain
import CheckmateRules
/// The four-way classification with explicit precedence: checkmate, stalemate, check, neither. "Neither" means none of
/// those three, not that no other draw rule could apply.
public enum TrainingStatus:String,Codable,CaseIterable {
    case checkmate,stalemate,check,neither
    public var label:String {switch self{case .checkmate:return "Checkmate";case .stalemate:return "Stalemate";case .check:return "Check";case .neither:return "Neither"}}
    public static let choices=allCases.map(\.label)
}
/// How a raw move attempt in Escape Check is graded (plan rule 3): before legal-move filtering and without exposing
/// legal destinations. A rule error is a wrong submission; nothing moves either way.
public enum TrainingMoveGrade:Equatable {
    /// A legal move; in check, every legal move is an evasion.
    case legal(MoveOutcome)
    /// A syntactically valid attempt with the learner's own piece that breaks a chess rule, with the reason.
    case ruleError(String)
    /// Not an attempt at all (an empty square, the other side's piece, the same square): a selection correction.
    case selection(String)
    /// A promotion that needs the learner's choice of piece before it can be graded.
    case needsPromotion
}
/// One isolated rules instance per active exercise, on the main actor and separate from the real game (plan rule 7).
/// Every query throws on a runtime failure, so a fault can never look like an empty answer or a wrong one.
@MainActor public final class TrainingLegality {
    private let rules:ChessRules
    /// The presented position, after any context moves.
    public private(set) var fen:String
    private var cachedOutcomes:[MoveOutcome]?
    /// Validates a complete FEN (one king each, the side not to move not in check, consistent castling rights), then
    /// replays the context moves, any of which may fail.
    public init(fen:String,prelude:[String]=[],runtimeFactory:(() throws -> any ChessScriptRuntime)?=nil)throws {
        _ = try PGNImporter.validateFEN(fen)
        rules=try runtimeFactory.map{try ChessRules(fen:fen,runtimeFactory:$0)} ?? ChessRules(fen:fen)
        for uci in prelude{guard ChessNotation.validUCI(uci) else{throw CheckmateError.invalid("Invalid context move.")};_ = try rules.move(uci:uci)}
        self.fen=try rules.currentFEN()
    }
    public func turn()throws -> String {try rules.currentTurn()}
    /// An automatic draw other than stalemate (insufficient material, 75 moves, fivefold repetition), or nil.
    public func automaticDraw()throws -> String? {try rules.automaticDrawReason()}
    /// A draw the side to move may claim (threefold repetition, the 50-move rule), or nil.
    public func claimableDraw()throws -> String? {try rules.claimableDrawReason()}
    /// Board, side to move, castling and en-passant fields: what a teaching node is identified by.
    public func fingerprint()throws -> String {Self.fingerprint(try rules.currentFEN())}
    public static func fingerprint(_ fen:String)->String {fen.split(separator:" ").prefix(4).joined(separator:" ")}
    public func board()throws -> Position {try rules.currentBoard()}
    public func status()throws -> TrainingStatus {
        if try rules.isCheckmate(){return .checkmate};if try rules.isStalemate(){return .stalemate};return try rules.isCheck() ? .check:.neither
    }
    public func outcomes()throws -> [MoveOutcome] {if let cachedOutcomes{return cachedOutcomes};let value=try rules.moveOutcomes();cachedOutcomes=value;return value}
    /// Every legal checkmating move, promotion-aware: each promotion piece that mates is its own accepted answer.
    public func matingMoves()throws -> Set<String> {Set(try outcomes().filter(\.checkmate).map(\.uci))}
    /// The squares the side to move's king can legally reach (castling excluded by the scenarios that ask this).
    public func kingDestinations()throws -> Set<String> {
        let turn=try turn();guard let king=try board().first(where:{$0.value==turn+"k"})?.key else{throw CheckmateError.invalid("No king to move.")}
        return Set(try outcomes().filter{$0.from==king && !$0.flags.contains("k") && !$0.flags.contains("q")}.map(\.to))
    }
    /// The legal move for exactly this attempt, if there is one.
    public func legalOutcome(from:String,to:String,promotion:String?)throws -> MoveOutcome? {
        try outcomes().first{$0.from==from && $0.to==to && $0.promotion==promotion}
    }
    /// Grades a raw attempt without consulting legal destinations first.
    /// With `castling`, moving the king onto its own rook is graded as a castling rule error: king-to-rook is not
    /// accepted as castling.
    public func grade(from:String,to:String,promotion:String?,castling:Bool=false)throws -> TrainingMoveGrade {
        guard ChessNotation.validSquare(from),ChessNotation.validSquare(to),from != to else{return .selection("Choose a piece, then a different square.")}
        let board=try board(),turn=try turn()
        guard let piece=board[from],piece.hasPrefix(turn) else{return .selection("Select one of your own pieces.")}
        if castling,piece==turn+"k",board[to]==turn+"r",from.last==to.last{return .ruleError("To castle, move the king two squares towards the rook; the rook then jumps over the king.")}
        if board[to]?.hasPrefix(turn)==true{return .selection("That square holds your own piece.")}
        let candidates=try outcomes().filter{$0.from==from && $0.to==to}
        if !candidates.isEmpty {
            let promotes=candidates.contains{$0.promotion != nil}
            if promotes && promotion==nil{return .needsPromotion}
            if let legal=candidates.first(where:{$0.promotion==promotion}){return .legal(legal)}
            return .ruleError(promotes ? "A pawn can promote only to a queen, rook, bishop or knight.":"Only a pawn reaching the last rank promotes; this move takes no promotion piece.")
        }
        return .ruleError(try reason(piece:piece,from:from,to:to,board:board))
    }
    /// Why a geometric or legal rule refuses an attempt, in words a beginner can act on; typed moves give the same reasons.
    private func reason(piece:String,from:String,to:String,board:Position)throws -> String {
        TypedMove.refusal(piece:piece,from:from,to:to,board:board,enPassant:fen.split(separator:" ").dropFirst(3).first.map(String.init),inCheck:try rules.isCheck())
    }
}
