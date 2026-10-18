import Foundation
/// The game the network place shows and takes input on (mini-games plan WI-022): board, side to move, legal moves,
/// promotion, last move, history, the position's canonical string and its ending. `NetworkGameController`, the board
/// views, MCP's display, the voice coach and the crash notice's Review read the shown game only through this, so a
/// declared start (WI-023) or a simplified mini-game with its own referee (WI-024) can stand in for chess.
/// `ChessRules` conforms in CheckmateRules (`NetworkBoard.swift`); `NetworkGameController.newBoard` makes the model.
/// The host and receivers verify the game separately, through `NetworkChessRules`.
///
/// The plain reads fall back to an empty or false value on a rules failure, for drawing. Anything sent, recorded,
/// searched or spoken as verified uses the throwing reads, so a failure never reads as an empty board or play on.
public protocol NetworkBoardModel:AnyObject {
    /// The pieces by square ("e2":"wp").
    var board:Position {get}
    var ruleset:NetworkRuleset? {get}
    /// The side to move: "w" or "b".
    var turn:String {get}
    /// The side to move is in check, so its king is marked; never true in a game without check.
    var check:Bool {get}
    /// The game ended by its own rules (checkmate or an automatic draw in chess). A claim, a resignation or a flag
    /// ends it in the record instead.
    var over:Bool {get}
    /// The position's canonical string (the FEN in chess): the piece inspector, MCP and the voice coach name it.
    var fen:String {get}
    /// The moves since the start, as written for people (SAN in chess).
    var history:[String] {get}
    /// The moves since the start with their squares; the last is the last move marked on the board.
    var records:[MoveRecord] {get}
    /// The side to move may claim a draw now (threefold repetition or fifty moves in chess).
    var drawClaimable:Bool {get}
    func piece(_ square:String)->ChessPiece?
    /// The legal moves from a square, or every legal move of the side to move when nil.
    func moves(_ square:String?)->[MoveRecord]
    /// A move from one square to the other needs its promotion piece chosen first.
    func needsPromotion(from:String,to:String)->Bool
    /// Plays a move the game applied, in UCI, and returns it as played; an illegal one throws and changes nothing.
    @discardableResult func move(uci:String)throws -> MoveRecord
    /// The game's start, with no moves.
    func loadStart()throws
    /// Replaces this game with the record's, only once the whole record has loaded: a failure leaves this game as it was.
    func restore(_ record:String)throws
    // The throwing reads.
    func currentFEN()throws -> String
    func currentTurn()throws -> String
    /// The moves since the start of the record.
    func moveHistory()throws -> [MoveRecord]
    func legalMoves(from square:String?)throws -> [MoveRecord]
    /// `over`, throwing on a rules failure rather than reading as play on.
    func endedByRules()throws -> Bool
    /// The pieces that protect, or attack, the piece on a square (the piece inspector, assistance plan A1).
    func relationships(_ square:String,mode:RelationshipMode,diagram:Position?)throws -> RelationshipInspection
}
public extension NetworkBoardModel {
    /// The mini-game ruleset the game is played by (protocol 1.3); nil for chess.
    var ruleset:NetworkRuleset? {nil}
    /// Every legal move of the side to move.
    func moves()->[MoveRecord] {moves(nil)}
}
