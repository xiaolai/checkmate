import CheckmateAssets
import CheckmateDomain
import Foundation
public final class ChessRules {
    private let runtime:any ChessScriptRuntime
    private let runtimeFactory:() throws -> any ChessScriptRuntime
    public convenience init(fen:String?=nil) throws {try self.init(fen:fen,runtimeFactory:{try JavaScriptCoreChessRuntime()})}
    public init(fen:String?=nil,runtimeFactory:@escaping () throws -> any ChessScriptRuntime) throws {
        self.runtimeFactory=runtimeFactory;runtime=try runtimeFactory()
        if let fen=fen {try load(fen)}
    }
    private func literal(_ object:Any) throws -> String {String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.fragmentsAllowed,.sortedKeys]),as:UTF8.self)}
    private func raw(_ expression:String) throws -> Any {
        let value=try runtime.evaluate("(()=>{try{return JSON.stringify({ok:true,value:\(expression)})}catch(e){return JSON.stringify({ok:false})}})()");guard let data=value.data(using:.utf8),let result=try JSONSerialization.jsonObject(with:data) as? [String:Any],result["ok"] as? Bool == true else {throw CheckmateError.invalid("Invalid chess operation.")}
        return result["value"] ?? NSNull()
    }
    private func decoded<T:Decodable>(_ expression:String,_ type:T.Type) throws -> T {let value=try raw(expression);return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed))}
    private func flag(_ expression:String)throws -> Bool {guard let value=try raw(expression) as? Bool else{throw CheckmateError.invalid("Invalid chess operation.")};return value}
    private func text(_ expression:String)throws -> String {guard let value=try raw(expression) as? String else{throw CheckmateError.invalid("Invalid chess operation.")};return value}
    // Convenience reads: each falls back to an empty or false value on a runtime failure. The throwing queries below
    // are the one implementation; anything that grades or copies a game uses those.
    public var fen:String {(try? currentFEN()) ?? ""}
    public var pgn:String {(try? text("game.pgn()")) ?? ""}
    public var turn:String {(try? currentTurn()) ?? "w"}
    public var history:[String] {(try? decoded("game.history()",[String].self)) ?? []}
    public var records:[MoveRecord] {(try? decoded("game.history({verbose:true})",[MoveRecord].self)) ?? []}
    public var over:Bool {checkmate || draw}
    public var check:Bool {(try? isCheck()) ?? false}
    public var checkmate:Bool {(try? isCheckmate()) ?? false}
    public var stalemate:Bool {(try? isStalemate()) ?? false}
    public var insufficientMaterial:Bool {(try? isInsufficientMaterial()) ?? false}
    /// Claimable draws do not terminate play until claimed; fivefold/75 moves are automatic.
    public var automaticDraw:Bool {(try? ruleDrawReason()) != nil}
    public var draw:Bool {stalemate || insufficientMaterial || automaticDraw}
    /// Claimable, not automatic: threefold repetition, or 50 moves by each side without a capture or pawn move.
    public var threefoldRepetition:Bool {((try? positionRepetitions()) ?? 0)>=3}
    public var fiftyMoveClaim:Bool {(try? fiftyMoveRuleReached()) ?? false}
    /// How the game ended by the rules, or nil while it continues.
    public var ending:(result:String,reason:String)? {try? rulesEnding()}
    public var status:String {checkmate ? "Checkmate" : draw ? "Draw" : (turn == "w" ? "White to move" : "Black to move") + (check ? " · Check" : "")}
    public func piece(_ square:String)->ChessPiece? {guard Self.validSquare(square) else{return nil};return try? pieceAt(square)}
    public var board:[String:String] {(try? currentBoard()) ?? [:]}
    public func moves(_ square:String?=nil)->[MoveRecord] {(try? legalMoves(from:square)) ?? []}
    @discardableResult public func move(_ from:String,_ to:String,_ promotion:String="q") throws -> MoveRecord {
        guard Self.validSquare(from),Self.validSquare(to),["q","r","b","n"].contains(promotion) else{throw CheckmateError.invalid("INVALID_MOVE")}
        return try decoded("game.move(\(literal(["from":from,"to":to,"promotion":promotion])))",MoveRecord.self)
    }
    @discardableResult public func move(uci:String) throws -> MoveRecord {
        guard Self.validUCI(uci) else{throw CheckmateError.invalid("INVALID_MOVE")}
        return try move(String(uci.prefix(2)),String(uci.dropFirst(2).prefix(2)),uci.count==5 ? String(uci.suffix(1)):"q")
    }
    /// PGN of this game whose Result names an automatic terminal outcome; otherwise *.
    /// chess.js always writes its Result header (default *), so a finished game needs it set explicitly.
    public func recordPGN(result override:String?=nil)throws -> String {
        let result=try override ?? rulesEnding()?.result ?? "*"
        guard let value=try raw("(()=>{const g=new exports.Chess();g.loadPgn(game.pgn());g.setHeader('Result',\(literal(result)));return g.pgn()})()") as? String else{throw CheckmateError.invalid("The game record could not be written.")}
        return value
    }
    public func load(_ fen:String) throws {_ = try raw("game.load(\(literal(fen)))")}
    /// The FEN header chess.js keeps for a game set up from a position (`load`, or a record's SetUp/FEN), or nil for
    /// a game from the initial position.
    public func setUpFEN()throws -> String? {let value=try raw("game.getHeaders().FEN ?? null");if value is NSNull{return nil};guard let fen=value as? String else{throw CheckmateError.invalid("Invalid chess operation.")};return fen}
    /// The record loads into a fresh game that replaces this one only once it has loaded: a failure leaves this game as it was.
    public func restore(_ pgn:String) throws {_ = try raw("(()=>{const g=new exports.Chess();g.loadPgn(\(literal(pgn)));game=g;return true})()")}
    /// A runtime failure throws: the caller must not record a new game or a take-back that did not happen.
    public func reset()throws {_ = try raw("game.reset()")}
    public func undo()throws {_ = try raw("game.undo()")}
    /// A copy with the same position and history; a failed read throws rather than copying an empty game.
    /// The fresh copy is disposable, so the record loads into it directly: a failure discards it, not this game.
    public func copy() throws -> ChessRules {let pgn=try text("game.pgn()"),next=try ChessRules(runtimeFactory:runtimeFactory);_ = try next.raw("game.loadPgn(\(next.literal(pgn)))");return next}
    public func attackers(_ square:String,_ color:String)->[String] {(try? attackersOf(square,color:color)) ?? []}
    /// A runtime failure throws rather than reading as a missing piece, an empty attack map or an empty square.
    public func inspect(_ sq:String) throws -> PieceInspection {
        guard Self.validSquare(sq),let p=try pieceAt(sq) else{throw CheckmateError.invalid("NO_PIECE")}
        let attacks=try Self.squares.filter{try attackersOf($0,color:p.color).contains(sq)},legal=try p.color==currentTurn()
        var destinations=try legal ? Array(Set(legalMoves(from:sq).map(\.to))).sorted() : attacks.filter {let target=try pieceAt($0);return p.type == "p" ? target != nil && target!.color != p.color && target!.type != "k" : target == nil || (target!.color != p.color && target!.type != "k")}
        if !legal,p.type=="p",let rank=Int(sq.suffix(1)) {
            let d=p.color=="w" ? 1 : -1,one=String(sq.prefix(1))+String(rank+d),two=String(sq.prefix(1))+String(rank+d*2)
            if (1...8).contains(rank+d),try pieceAt(one)==nil {destinations.append(one);if rank==(d==1 ? 2:7),try pieceAt(two)==nil{destinations.append(two)}}
        }
        return PieceInspection(square:sq,piece:p.type,color:p.color,attacks:attacks,destinations:destinations,legalNow:legal,note:legal ? "Dots show legal moves. Rings show attacks or defended squares.":"Dots show potential movement with current blockers. It is not this side’s turn; checks and pins may restrict these moves. Rings show attacks or defended squares.")
    }
    /// The relationships evaluator (`relationships.js`), read once from the bundled resources. A missing or unreadable
    /// resource fails every relationships call with this error; there is no inline fallback copy.
    private static let relationshipsScript=Result<String,Error>{
        do{return try String(contentsOf:NativeResources.url("relationships.js"),encoding:.utf8)}
        catch{throw CheckmateError.unavailable("Chess relationships resource is missing or unreadable: \(error.localizedDescription)")}
    }
    /// Evaluates a displayed position without mutating the live game or its history.
    /// An authored partial diagram intentionally supplies geometry only.
    public func relationships(_ square:String,mode:RelationshipMode,diagram:Position?=nil) throws -> RelationshipInspection {
        guard Self.validSquare(square) else{throw CheckmateError.invalid("INVALID_SQUARE")}
        let input:[String:Any]=["square":square,"mode":mode.rawValue,"diagram":diagram as Any? ?? NSNull()]
        let script=try Self.relationshipsScript.get()
        return try decoded("(()=>{\n\(script)\nreturn relationships(\(try literal(input)),game)})()",RelationshipInspection.self)
    }
    // Throwing queries (plan rule 4). The convenience properties above fall back to empty or false values; training must
    // never grade on those, so a runtime failure here is an error, not "no legal moves" or "not in check".
    public func currentFEN()throws -> String {try text("game.fen()")}
    /// The moves played since the start of the record, as `records` but throwing on a runtime failure.
    public func moveHistory()throws -> [MoveRecord] {try decoded("game.history({verbose:true})",[MoveRecord].self)}
    public func currentTurn()throws -> String {let value=try text("game.turn()");guard ["w","b"].contains(value) else{throw CheckmateError.invalid("Invalid chess operation.")};return value}
    public func isCheck()throws -> Bool {try flag("game.isCheck()")}
    public func isCheckmate()throws -> Bool {try flag("game.isCheckmate()")}
    public func isStalemate()throws -> Bool {try flag("game.isStalemate()")}
    public func isInsufficientMaterial()throws -> Bool {try flag("game.isInsufficientMaterial()")}
    /// How the game ended by the rules, or nil while it continues; a runtime failure throws rather than reading as play on.
    private func rulesEnding()throws -> (result:String,reason:String)? {
        if try isCheckmate(){let white=try currentTurn()=="b";return (white ? "1-0":"0-1",(white ? "White":"Black")+" wins by checkmate.")}
        if try isStalemate(){return ("1/2-1/2","Draw by stalemate.")}
        if try isInsufficientMaterial(){return ("1/2-1/2","Draw: neither side has enough material to checkmate.")}
        return try ruleDrawReason().map{(result:"1/2-1/2",reason:"Draw by \($0).")}
    }
    /// The 75-move rule or fivefold repetition, whichever ends the game now; nil while neither does.
    private func ruleDrawReason()throws -> String? {
        if try flag("Number(game.fen().split(' ')[4])>=150&&!game.isCheckmate()"){return "the 75-move rule"}
        return try positionRepetitions()>=5 ? "fivefold repetition":nil
    }
    /// How often the current position has stood in this game, this time included. Positions are the same when their
    /// placement, side to move, castling rights and en passant square are: `fen()` names an en passant square only when
    /// the capture is legal, so a pawn pinned to its king cannot make two positions differ. chess.js's own repetition
    /// count hashes the square whenever an enemy pawn stands beside it, pinned or not, so it is not used.
    private func positionRepetitions()throws -> Int {
        guard let count=Int(try text("(()=>{const h=game.history({verbose:true}),key=fen=>fen.split(' ').slice(0,4).join(' '),current=key(game.fen()),positions=[h.length?h[0].before:game.fen(),...h.map(m=>m.after)];return String(positions.filter(fen=>key(fen)===current).length)})()")) else{throw CheckmateError.invalid("Invalid chess operation.")}
        return count
    }
    /// Automatic draws other than stalemate: insufficient material, the 75-move rule or fivefold repetition.
    public func automaticDrawReason()throws -> String? {
        if try isInsufficientMaterial(){return "neither side has enough material to checkmate"}
        return try ruleDrawReason()
    }
    /// Claimable, not automatic: threefold repetition, or 50 moves by each side without a capture or pawn move.
    public func claimableDrawReason()throws -> String? {
        if try positionRepetitions()>=3{return "threefold repetition"}
        return try fiftyMoveRuleReached() ? "the 50-move rule":nil
    }
    /// 100 plies (50 moves by each side) without a capture or pawn move: claimable, not automatic.
    private func fiftyMoveRuleReached()throws -> Bool {(Int(try currentFEN().split(separator:" ").dropFirst(4).first ?? "0") ?? 0)>=100}
    /// The piece on a square, or nil when it is empty; a runtime failure throws rather than reading as an empty square.
    private func pieceAt(_ square:String)throws -> ChessPiece? {try decoded("game.get(\(literal(square)))",ChessPiece?.self)}
    public func legalMoves(from square:String?=nil)throws -> [MoveRecord] {
        guard square.map(Self.validSquare) ?? true else{throw CheckmateError.invalid("INVALID_SQUARE")}
        let args:[String:Any]=square.map{["verbose":true,"square":$0]} ?? ["verbose":true]
        return try decoded("game.moves(\(literal(args)))",[MoveRecord].self)
    }
    /// The whole board in one evaluation.
    public func currentBoard()throws -> Position {try decoded("Object.fromEntries(game.board().flat().filter(p=>p).map(p=>[p.square,p.color+p.type]))",Position.self)}
    /// Squares of `color`'s pieces attacking `square` in the current game (legal-position context, pins ignored).
    public func attackersOf(_ square:String,color:String)throws -> [String] {guard Self.validSquare(square),["w","b"].contains(color) else{throw CheckmateError.invalid("INVALID_SQUARE")};return try decoded("game.attackers(\(literal(square)),\(literal(color)))",[String].self).sorted()}
    /// Every legal move and the position it leads to, in one evaluation of a copy: this game never changes, so an
    /// exception part-way cannot leave a move made (no make/undo pair to unwind).
    public func moveOutcomes()throws -> [MoveOutcome] {
        try decoded("(()=>{const g=new exports.Chess(game.fen());return g.moves({verbose:true}).map(m=>{const h=new exports.Chess(m.after);return {from:m.from,to:m.to,piece:m.piece,color:m.color,san:m.san,flags:m.flags,captured:m.captured??null,promotion:m.promotion??null,after:m.after,check:h.isCheck(),checkmate:h.isCheckmate(),stalemate:h.isStalemate()}})})()",[MoveOutcome].self)
    }
    public static let squares=ChessNotation.squares
    public static func validSquare(_ s:String)->Bool {ChessNotation.validSquare(s)}
    public static func validUCI(_ s:String)->Bool {ChessNotation.validUCI(s)}
}
