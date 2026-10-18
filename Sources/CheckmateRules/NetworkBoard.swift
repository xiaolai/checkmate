import CheckmateDomain
import Foundation
/// Chess as the network place's board model (mini-games plan WI-022): every member but these four is `ChessRules`' own.
extension ChessRules:NetworkBoardModel {
    /// The standard start: a game shown before its record arrives, and the lobby's empty board.
    static let networkStart="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    public var drawClaimable:Bool {threefoldRepetition || fiftyMoveClaim}
    public func needsPromotion(from:String,to:String)->Bool {moves(from).contains{$0.to==to && $0.promotion != nil}}
    public func loadStart()throws {try load(Self.networkStart)}
    /// Checkmate, stalemate or an automatic draw (insufficient material, the 75-move rule, fivefold repetition).
    public func endedByRules()throws -> Bool {try isCheckmate() || isStalemate() || automaticDrawReason() != nil}
}
