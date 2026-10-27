import CheckmateRules

public extension ChessRules {
    /// The rules at the position `moves` reach from `fen` (the standard start when nil).
    static func reached(_ fen:String?,_ moves:[String])throws -> ChessRules {let rules=try ChessRules(fen:fen);for move in moves{try rules.move(uci:move)};return rules}
}
