import Foundation
/// What a network game needs from the chess rules (D2, D5, D6). The domain cannot import CheckmateRules, so the host
/// and receivers see the rules only through this; `ChessRules` conforms in CheckmateRules (`NetworkRules.swift`).
/// Every member throws on a rules failure: a failure must never read as "no such move" or "the game goes on".
public protocol NetworkChessRules:AnyObject {
    /// The canonical FEN, all six fields: half of the position hash.
    func networkFEN()throws -> String
    func networkSideToMove()throws -> NetworkSide
    /// Plays a legal move written in UCI, a promotion naming its piece, and returns it as played. An illegal move
    /// throws `NetworkRulesError.illegalMove` and leaves the game as it was; any other error is a rules failure.
    func networkPlay(uci:String)throws -> NetworkPlayedMove
    /// An ending nobody claims: checkmate, stalemate, insufficient material, the 75-move rule or fivefold repetition.
    func networkAutomaticEnding()throws -> NetworkAutomaticEnding?
    /// A draw the side to move may claim now: `.repetition` (threefold) or `.fiftyMoves`; nil when neither holds.
    func networkClaimableDraw()throws -> NetworkTermination?
    func networkHasOnlyKing(_ side:NetworkSide)throws -> Bool
    /// The game record a snapshot carries; `networkLoad` on a fresh game replays it to this position.
    func networkPGN()throws -> String
    /// Replaces this game with the record's, only once the whole record has loaded.
    func networkLoad(pgn:String)throws
    /// The moves played since the start of the record, in UCI, in order.
    func networkMoves()throws -> [String]
    /// Replaces this game with a new one from `fen`, with no moves (mini-games plan D7): it then stands at the FEN its
    /// rules write back, the canonical start, and its record declares that start. A position the rules refuse, one
    /// whose side not to move is in check, or one failing `NetworkStart.consistent` throws
    /// `NetworkRulesError.illegalStart` and leaves the game as it was; any other error is a rules failure.
    func networkLoad(start fen:String)throws
    /// The start the loaded record declares: its FEN header, or the standard start when it has none.
    func networkStartFEN()throws -> String
}
public struct NetworkPlayedMove:Equatable {
    public let uci:String,san:String
    public init(uci:String,san:String){self.uci=uci;self.san=san}
}
public enum NetworkAutomaticEnding:Equatable {
    case checkmate(winner:NetworkSide),stalemate,insufficientMaterial,seventyFiveMoves,fivefold
    public var outcome:NetworkOutcome {
        switch self {
        case .checkmate(let winner):return NetworkOutcome(result:.win(for:winner),termination:.checkmate)
        case .stalemate:return NetworkOutcome(result:.draw,termination:.stalemate)
        case .insufficientMaterial:return NetworkOutcome(result:.draw,termination:.insufficientMaterial)
        case .seventyFiveMoves:return NetworkOutcome(result:.draw,termination:.seventyFiveMoves)
        case .fivefold:return NetworkOutcome(result:.draw,termination:.fivefold)
        }
    }
}
public enum NetworkRulesError:Error,Equatable {
    case illegalMove
    /// A start no game could have reached (D7); see `networkLoad(start:)`.
    case illegalStart
    case unexpected(String)
}
/// Makes fresh games: the host's own network game (never `session.rules`, D9), and each scratch game a receiver
/// replays a snapshot into before trusting it.
public struct NetworkRulesFactory {
    private let make:()throws -> any NetworkChessRules
    public init(_ make:@escaping ()throws -> any NetworkChessRules){self.make=make}
    public func newGame()throws -> any NetworkChessRules {try make()}
}
/// The position hash (D2): SHA-256 of the canonical FEN and the revision. The domain imports no cryptography, so the
/// digest is injected; production passes CheckmateSupport's `reviewHash` (SHA-256, lower-case hex).
public struct NetworkHashing {
    private let digest:(Data)->String
    public init(_ digest:@escaping (Data)->String){self.digest=digest}
    public func positionHash(fen:String,revision:Int)->String {digest(Data("\(fen)\n\(revision)".utf8))}
}
