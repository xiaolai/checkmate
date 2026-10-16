import CheckmateDomain
import Foundation
/// The network game's view of `ChessRules` (D2, D5, D6), built only on the throwing queries: a runtime failure is an
/// error, never "illegal", "no draw" or "not over".
extension ChessRules:NetworkChessRules {
    public func networkFEN()throws -> String {
        let fen=try currentFEN()
        guard fen.split(separator:" ",omittingEmptySubsequences:false).count==6 else{throw NetworkRulesError.unexpected("The position has no six-field FEN.")}
        return fen
    }
    public func networkSideToMove()throws -> NetworkSide {try currentTurn()=="w" ? .white:.black}
    /// Legality comes from the legal-move list, so a move that is not on it is illegal and a failure while playing a
    /// listed move is a rules failure. A promotion must name its piece; a suffix on any other move is illegal.
    public func networkPlay(uci:String)throws -> NetworkPlayedMove {
        guard ChessNotation.validUCI(uci),let legal=try legalMoves().first(where:{$0.uci==uci}) else{throw NetworkRulesError.illegalMove}
        let played=try move(legal.from,legal.to,legal.promotion ?? "q")
        guard played.uci==uci else{throw NetworkRulesError.unexpected("The rules played another move.")}
        return NetworkPlayedMove(uci:played.uci,san:played.san)
    }
    public func networkAutomaticEnding()throws -> NetworkAutomaticEnding? {
        if try isCheckmate() {return .checkmate(winner:try networkSideToMove().opponent)}
        if try isStalemate() {return .stalemate}
        // `automaticDrawReason` names insufficient material, then the 75-move rule, then fivefold repetition. A wording
        // this does not know throws rather than reading as play on.
        switch try automaticDrawReason() {
        case nil:return nil
        case "neither side has enough material to checkmate"?:return .insufficientMaterial
        case "the 75-move rule"?:return .seventyFiveMoves
        case "fivefold repetition"?:return .fivefold
        case let other?:throw NetworkRulesError.unexpected("Unknown automatic draw: \(other).")
        }
    }
    public func networkClaimableDraw()throws -> NetworkTermination? {
        switch try claimableDrawReason() {
        case nil:return nil
        case "threefold repetition"?:return .repetition
        case "the 50-move rule"?:return .fiftyMoves
        case let other?:throw NetworkRulesError.unexpected("Unknown claimable draw: \(other).")
        }
    }
    public func networkHasOnlyKing(_ side:NetworkSide)throws -> Bool {try currentBoard().values.filter{$0.hasPrefix(side.rawValue)}==[side.rawValue+"k"]}
    /// `pgn` is a convenience read that is empty only on a runtime failure (a record always ends in a result token),
    /// so an empty one is that failure.
    public func networkPGN()throws -> String {let record=pgn;guard !record.isEmpty else{throw NetworkRulesError.unexpected("The game record could not be read.")};return record}
    public func networkLoad(pgn:String)throws {try restore(pgn)}
}
