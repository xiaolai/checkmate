import Foundation
/// A simplified mini-game as a network game (mini-games plan WI-024, `docs/network-protocol-1.3.md`): the host's and
/// each receiver's verification (`NetworkChessRules`) and the shown game (`NetworkBoardModel`), both on the referee
/// (`MiniGameState.play`, `victory`, `draw`). Every move goes through `play`, so nothing reaches the board that the
/// referee did not allow, and a record is replayed from the kind's start, so the repetition and no-progress history
/// is this Mac's own. The state keeps the referee's evicting history; `played` keeps every move for the record.
public final class NetworkMiniGame:NetworkChessRules,NetworkBoardModel {
    public let ruleset:NetworkRuleset?
    private let rules:NetworkRuleset
    public private(set) var state:MiniGameState
    private var played:[MiniGameMove]=[],made:[MoveRecord]=[]
    public init(_ ruleset:NetworkRuleset){rules=ruleset;self.ruleset=ruleset;state=Self.start(ruleset)}
    /// The kind's own start, White to move, no history; `run` unseeded, so a review of it is tied to the game alone.
    private static func start(_ ruleset:NetworkRuleset)->MiniGameState {var state=MiniGameState(kind:ruleset.kind,computer:false);state.opponentSeed=nil;return state}

    // MARK: The canonical state (the position hash)
    /// "mini-state-v1|<descriptor>|<board>|<turn>|<pending>|<history>|<count>": everything the referee rules on. The
    /// history is every earlier position with the current material and pawns, which are exactly the positions since
    /// the last capture or pawn move: a capture removes a piece and pawns only move forward, so no earlier position can
    /// recur, and the 80-ply rule counts these same positions. The last move is no input of any ruling.
    public func networkFEN()throws -> String {
        let pawns=state.board.filter{$0.value.hasSuffix("p")}
        let since=state.history.reversed().prefix{$0.board.count==state.board.count && $0.board.filter{$0.value.hasSuffix("p")}==pawns}.reversed()
        // The referee keeps 256 positions and draws after 80 without progress, so the stretch is never cut short.
        guard since.count<MiniGameState.maximumHistory else{throw NetworkRulesError.unexpected("The mini-game's history was cut short.")}
        func position(_ s:MiniGameSnapshot)->String {Self.squares(s.board)+";"+s.turn+";"+(s.pendingFinish ?? "-")}
        return ["mini-state-v1",rules.descriptor,Self.squares(state.board),state.turn,state.snapshot.pendingFinish ?? "-",since.map(position).joined(separator:"/"),String(since.count)].joined(separator:"|")
    }
    private static func squares(_ board:Position)->String {board.keys.sorted().map{$0+"="+board[$0]!}.joined(separator:",")}

    // MARK: NetworkChessRules
    public func networkSideToMove()throws -> NetworkSide {state.turn=="w" ? .white:.black}
    /// A move is four characters, from-square then to-square, that the referee allows here; a promotion suffix is
    /// illegal (pawns stay pawns), and so is any move once the game is over.
    public func networkPlay(uci:String)throws -> NetworkPlayedMove {let record=try play(uci);return NetworkPlayedMove(uci:record.uci,san:record.san)}
    public func networkAutomaticEnding()throws -> NetworkAutomaticEnding? {NetworkRuleset.ending(state)}
    /// Nothing is claimed in a mini-game: its draws are automatic.
    public func networkClaimableDraw()throws -> NetworkTermination? {nil}
    /// No mini-game has kings, so a flag always loses (D6's lone-king draw never applies).
    public func networkHasOnlyKing(_ side:NetworkSide)throws -> Bool {false}
    public func networkPGN()throws -> String {rules.record(played)}
    /// Reads the record strictly (`NetworkRuleset.moves(of:)`), replays every move on a fresh start through the referee,
    /// and only then replaces this game; any failure leaves it as it was.
    public func networkLoad(pgn record:String)throws {
        let moves=try rules.moves(of:record)
        let fresh=NetworkMiniGame(rules)
        for move in moves {guard (try? fresh.play(move.from+move.to)) != nil else{throw NetworkRulesError.badRecord}}
        state=fresh.state;played=fresh.played;made=fresh.made
    }
    public func networkMoves()throws -> [String] {played.map{$0.from+$0.to}}
    /// A ruleset game has its kind's start and no other.
    public func networkLoad(start fen:String)throws {throw NetworkRulesError.illegalStart}
    /// The start the record names: the ruleset's descriptor (`NetworkPublicGame.start`).
    public func networkStartFEN()throws -> String {rules.descriptor}

    // MARK: NetworkBoardModel
    public var board:Position {state.board}
    public var turn:String {state.turn}
    public var check:Bool {false}
    public var over:Bool {state.isFinished}
    /// For people and tools: the descriptor, the board's placement as a FEN writes it, and the side to move.
    public var fen:String {"\(rules.descriptor) \(Self.placement(state.board)) \(state.turn)"}
    public var history:[String] {made.map(\.san)}
    public var records:[MoveRecord] {made}
    public var drawClaimable:Bool {false}
    public func piece(_ square:String)->ChessPiece? {state.board[square].map{ChessPiece(type:String($0.suffix(1)),color:String($0.prefix(1)),square:square)}}
    public func moves(_ square:String?)->[MoveRecord] {
        guard !state.isFinished else{return []}
        return MiniGameRules.moves(board:state.board,kind:rules.kind,side:state.turn).filter{square==nil || $0.from==square}.map{record($0,after:nil)}
    }
    public func needsPromotion(from:String,to:String)->Bool {false}
    @discardableResult public func move(uci:String)throws -> MoveRecord {try play(uci)}
    public func loadStart()throws {state=Self.start(rules);played=[];made=[]}
    public func restore(_ record:String)throws {try networkLoad(pgn:record)}
    public func currentFEN()throws -> String {fen}
    public func currentTurn()throws -> String {state.turn}
    public func moveHistory()throws -> [MoveRecord] {made}
    public func legalMoves(from square:String?)throws -> [MoveRecord] {moves(square)}
    public func endedByRules()throws -> Bool {state.isFinished}
    /// The piece inspector is chess's: a mini-game has no assistance, so it is never offered (protocol 1.3).
    public func relationships(_ square:String,mode:RelationshipMode,diagram:Position?)throws -> RelationshipInspection {throw CheckmateError.unavailable("The piece inspector is not available in a mini-game.")}

    // MARK: Moves
    private func play(_ uci:String)throws -> MoveRecord {
        let text=Array(uci.utf8)
        guard text.count==4 else{throw NetworkRulesError.illegalMove}
        let move=MiniGameMove(from:String(uci.prefix(2)),to:String(uci.suffix(2)))
        guard ChessNotation.validSquare(move.from),ChessNotation.validSquare(move.to) else{throw NetworkRulesError.illegalMove}
        var next=state
        guard next.play(move) else{throw NetworkRulesError.illegalMove}
        let made=record(move,after:next)
        state=next;played.append(move);self.made.append(made)
        return made
    }
    /// A move as people read it: "b2-b4", "c4xd5", "Rb1xb7" (no SAN: there are no checks or promotions).
    private func record(_ move:MiniGameMove,after:MiniGameState?)->MoveRecord {
        let piece=state.board[move.from] ?? "w?",captured=state.board[move.to].map{String($0.suffix(1))},type=String(piece.suffix(1))
        let written=(type=="p" ? "":type.uppercased())+move.from+(captured==nil ? "-":"x")+move.to
        let afterFEN=after.map{"\(rules.descriptor) \(Self.placement($0.board)) \($0.turn)"} ?? ""
        return MoveRecord(color:String(piece.prefix(1)),from:move.from,to:move.to,piece:type,flags:captured==nil ? "n":"c",san:written,before:fen,after:afterFEN,captured:captured,promotion:nil)
    }
    /// The board as a FEN's first field.
    static func placement(_ board:Position)->String {
        (1...8).reversed().map{rank in
            var text="",empty=0
            for file in "abcdefgh" {
                if let piece=board["\(file)\(rank)"] {if empty>0{text+=String(empty);empty=0};let type=String(piece.suffix(1));text+=piece.hasPrefix("w") ? type.uppercased():type}else{empty+=1}
            }
            return empty>0 ? text+String(empty):text
        }.joined(separator:"/")
    }
}
