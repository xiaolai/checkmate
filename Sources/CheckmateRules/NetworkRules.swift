import CheckmateAssets
import CheckmateDomain
import Foundation
/// The network game's view of `ChessRules` (D2, D5, D6), built only on the throwing queries: a runtime failure is an
/// error, never "illegal", "no draw" or "not over".
extension ChessRules:NetworkChessRules {
    public func networkFEN()throws -> String {
        let fen=try currentFEN()
        guard fen.split(separator:" ",omittingEmptySubsequences:false).count==6 else{throw NetworkRulesError.unexpected(String(localized:"The position has no six-field FEN.",bundle:.checkmate))}
        return fen
    }
    public func networkSideToMove()throws -> NetworkSide {try currentTurn()=="w" ? .white:.black}
    /// Legality comes from the legal-move list, so a move that is not on it is illegal and a failure while playing a
    /// listed move is a rules failure. A promotion must name its piece; a suffix on any other move is illegal.
    public func networkPlay(uci:String)throws -> NetworkPlayedMove {
        guard ChessNotation.validUCI(uci),let legal=try legalMoves().first(where:{$0.uci==uci}) else{throw NetworkRulesError.illegalMove}
        let played=try move(legal.from,legal.to,legal.promotion ?? "q")
        guard played.uci==uci else{throw NetworkRulesError.unexpected(String(localized:"The rules played another move.",bundle:.checkmate))}
        return NetworkPlayedMove(uci:played.uci,san:played.san)
    }
    public func networkAutomaticEnding()throws -> NetworkAutomaticEnding? {
        if try isCheckmate() {return .checkmate(winner:try networkSideToMove().opponent)}
        if try isStalemate() {return .stalemate}
        // The rules name the draw by kind, never by its translated wording. A claimable kind here throws rather than
        // reading as play on.
        switch try automaticDrawKind() {
        case nil:return nil
        case .insufficientMaterial?:return .insufficientMaterial
        case .seventyFiveMoves?:return .seventyFiveMoves
        case .fivefold?:return .fivefold
        case let other?:throw NetworkRulesError.unexpected(String(localized:"Unknown automatic draw: \(other.reason).",bundle:.checkmate))
        }
    }
    public func networkClaimableDraw()throws -> NetworkTermination? {
        switch try claimableDrawKind() {
        case nil:return nil
        case .threefold?:return .repetition
        case .fiftyMoves?:return .fiftyMoves
        case let other?:throw NetworkRulesError.unexpected(String(localized:"Unknown claimable draw: \(other.reason).",bundle:.checkmate))
        }
    }
    public func networkHasOnlyKing(_ side:NetworkSide)throws -> Bool {try currentBoard().values.filter{$0.hasPrefix(side.rawValue)}==[side.rawValue+"k"]}
    /// `pgn` is a convenience read that is empty only on a runtime failure (a record always ends in a result token),
    /// so an empty one is that failure.
    public func networkPGN()throws -> String {let record=pgn;guard !record.isEmpty else{throw NetworkRulesError.unexpected(String(localized:"The game record could not be read.",bundle:.checkmate))};return record}
    public func networkLoad(pgn:String)throws {try restore(pgn)}
    public func networkMoves()throws -> [String] {try moveHistory().map(\.uci)}
    /// Loads the position, then loads the FEN chess.js wrote back for it, so the game and its record's FEN header are
    /// the canonical start. A refusal puts the previous game back.
    public func networkLoad(start fen:String)throws {
        let before=try networkPGN()
        do{try load(fen)}catch{throw NetworkRulesError.illegalStart}
        func refuse()throws -> Never {try restore(before);throw NetworkRulesError.illegalStart}
        let canonical=try networkFEN()
        try load(canonical)
        guard try networkFEN()==canonical,try setUpFEN() ?? NetworkStart.standard==canonical,NetworkStart.consistent(canonical) else{try refuse()}
        // chess.js does not check that the side not to move is out of check: a position where it is cannot arise.
        let mover=try currentTurn(),waiting=mover=="w" ? "b":"w"
        guard let king=try currentBoard().first(where:{$0.value==waiting+"k"})?.key,try attackersOf(king,color:mover).isEmpty else{try refuse()}
    }
    public func networkStartFEN()throws -> String {try setUpFEN() ?? NetworkStart.standard}
}
