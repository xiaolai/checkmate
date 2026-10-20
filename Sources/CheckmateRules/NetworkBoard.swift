import CheckmateDomain
import Foundation
/// Chess as the network place's board model (mini-games plan WI-022): every member but these four is `ChessRules`' own.
extension ChessRules:NetworkBoardModel {
    public var drawClaimable:Bool {threefoldRepetition || fiftyMoveClaim}
    public func needsPromotion(from:String,to:String)->Bool {moves(from).contains{$0.to==to && $0.promotion != nil}}
    /// The standard start: a game shown before its record arrives, and the lobby's empty board.
    public func loadStart()throws {try load(NetworkStart.standard)}
    /// Checkmate, stalemate or an automatic draw (insufficient material, the 75-move rule, fivefold repetition).
    public func endedByRules()throws -> Bool {try isCheckmate() || isStalemate() || automaticDrawReason() != nil}
}
