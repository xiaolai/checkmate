import Foundation
import JavaScriptCore
public struct ChessPiece:Codable,Equatable {public let type:String;public let color:String;public let square:String?}
public struct MoveRecord:Codable,Equatable {
    public let color:String,from:String,to:String,piece:String,flags:String,san:String,before:String,after:String
    public let captured:String?,promotion:String?
    public var uci:String {from+to+(promotion ?? "")}
}
public struct PieceInspection:Codable,Equatable {
    public let square:String,piece:String,color:String,attacks:[String],destinations:[String],legalNow:Bool,note:String
}
public final class ChessRules {
    private let context:JSContext
    public init(fen:String?=nil) throws {
        guard let c=JSContext() else {throw CheckmateError.unavailable("Chess rules could not initialize.")};context=c
        c.evaluateScript("var exports={};")
        c.evaluateScript(try String(contentsOf:NativeResources.url("chess.js"),encoding:.utf8))
        guard c.exception == nil else {throw CheckmateError.unavailable("Chess rules resource is invalid.")}
        c.evaluateScript("var game=new exports.Chess();")
        if let fen=fen {try load(fen)}
    }
    private func literal(_ object:Any) throws -> String {String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.fragmentsAllowed,.sortedKeys]),as:UTF8.self)}
    private func raw(_ expression:String) throws -> Any {
        context.exception=nil
        guard let value=context.evaluateScript("(()=>{try{return JSON.stringify({ok:true,value:\(expression)})}catch(e){return JSON.stringify({ok:false})}})()"),let data=value.toString()?.data(using:.utf8),let result=try JSONSerialization.jsonObject(with:data) as? [String:Any],result["ok"] as? Bool == true else {throw CheckmateError.invalid("Invalid chess operation.")}
        return result["value"] ?? NSNull()
    }
    private func decoded<T:Decodable>(_ expression:String,_ type:T.Type) throws -> T {let value=try raw(expression);return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed))}
    public var fen:String {(try? raw("game.fen()") as? String) ?? ""}
    public var pgn:String {(try? raw("game.pgn()") as? String) ?? ""}
    public var turn:String {(try? raw("game.turn()") as? String) ?? "w"}
    public var history:[String] {(try? decoded("game.history()",[String].self)) ?? []}
    public var records:[MoveRecord] {(try? decoded("game.history({verbose:true})",[MoveRecord].self)) ?? []}
    public var over:Bool {checkmate || draw}
    public var check:Bool {(try? raw("game.isCheck()") as? Bool) ?? false}
    public var checkmate:Bool {(try? raw("game.isCheckmate()") as? Bool) ?? false}
    public var stalemate:Bool {(try? raw("game.isStalemate()") as? Bool) ?? false}
    public var insufficientMaterial:Bool {(try? raw("game.isInsufficientMaterial()") as? Bool) ?? false}
    /// Claimable draws do not terminate play until claimed; fivefold/75 moves are automatic.
    public var automaticDraw:Bool {
        (try? raw("(()=>{const f=game.fen().split(' ');if(Number(f[4])>=150&&!game.isCheckmate())return true;const h=game.history({verbose:true}),key=fen=>fen.split(' ').slice(0,4).join(' '),current=key(game.fen()),positions=[h.length?h[0].before:game.fen(),...h.map(m=>m.after)];return positions.filter(fen=>key(fen)===current).length>=5})()") as? Bool) ?? false
    }
    public var draw:Bool {stalemate || insufficientMaterial || automaticDraw}
    public var status:String {checkmate ? "Checkmate" : draw ? "Draw" : (turn == "w" ? "White to move" : "Black to move") + (check ? " · Check" : "")}
    public func piece(_ square:String)->ChessPiece? {guard Self.validSquare(square) else{return nil};return try? decoded("game.get(\(literal(square)))",ChessPiece.self)}
    public var board:[String:String] {
        var result:[String:String]=[:]
        for sq in Self.squares {if let p=piece(sq){result[sq]=p.color+p.type}}
        return result
    }
    public func moves(_ square:String?=nil)->[MoveRecord] {
        guard square == nil || Self.validSquare(square!) else{return []}
        let args:[String:Any]=square.map{["verbose":true,"square":$0]} ?? ["verbose":true]
        return (try? decoded("game.moves(\(literal(args)))",[MoveRecord].self)) ?? []
    }
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
    public func recordPGN()throws -> String {
        let result=checkmate ? (turn=="w" ? "0-1":"1-0"):draw ? "1/2-1/2":"*"
        guard let value=try raw("(()=>{const g=new exports.Chess();g.loadPgn(game.pgn());g.setHeader('Result',\(literal(result)));return g.pgn()})()") as? String else{throw CheckmateError.invalid("The game record could not be written.")}
        return value
    }
    public func load(_ fen:String) throws {_ = try raw("game.load(\(literal(fen)))")}
    public func restore(_ pgn:String) throws {let next=try ChessRules();_ = try next.raw("game.loadPgn(\(next.literal(pgn)))");_ = try raw("game.loadPgn(\(literal(pgn)))")}
    public func reset(){_ = try? raw("game.reset()")}
    public func undo(){_ = try? raw("game.undo()")}
    public func copy() throws -> ChessRules {let next=try ChessRules();try next.restore(pgn);return next}
    public func attackers(_ square:String,_ color:String)->[String] {guard Self.validSquare(square),["w","b"].contains(color) else{return []};return (try? decoded("game.attackers(\(literal(square)),\(literal(color)))",[String].self)) ?? []}
    public func inspect(_ sq:String) throws -> PieceInspection {
        guard let p=piece(sq) else{throw CheckmateError.invalid("NO_PIECE")}
        let attacks=Self.squares.filter{attackers($0,p.color).contains(sq)},legal=p.color==turn
        var destinations=legal ? Array(Set(moves(sq).map(\.to))).sorted() : attacks.filter {let target=piece($0);return p.type == "p" ? target != nil && target!.color != p.color && target!.type != "k" : target == nil || (target!.color != p.color && target!.type != "k")}
        if !legal,p.type=="p",let rank=Int(sq.suffix(1)) {
            let d=p.color=="w" ? 1 : -1,one=String(sq.prefix(1))+String(rank+d),two=String(sq.prefix(1))+String(rank+d*2)
            if (1...8).contains(rank+d),piece(one)==nil {destinations.append(one);if rank==(d==1 ? 2:7),piece(two)==nil{destinations.append(two)}}
        }
        return PieceInspection(square:sq,piece:p.type,color:p.color,attacks:attacks,destinations:destinations,legalNow:legal,note:legal ? "Dots show legal moves. Rings show attacks or defended squares.":"Dots show potential movement with current blockers. It is not this side’s turn; checks and pins may restrict these moves. Rings show attacks or defended squares.")
    }
    /// Evaluates a displayed position without mutating the live game or its history.
    /// An authored partial diagram intentionally supplies geometry only.
    public func relationships(_ square:String,mode:RelationshipMode,diagram:Position?=nil) throws -> RelationshipInspection {
        guard Self.validSquare(square) else{throw CheckmateError.invalid("INVALID_SQUARE")}
        let input:[String:Any]=["square":square,"mode":mode.rawValue,"diagram":diagram as Any? ?? NSNull()]
        let expression="""
        (()=>{
            const input=\(try literal(input)),g=new exports.Chess(game.fen());
            if(input.diagram){g.clear();for(const [sq,p] of Object.entries(input.diagram)){if(!g.put({color:p[0],type:p[1]},sq))throw Error('invalid diagram')}}
            const selected=g.get(input.square);if(!selected)throw Error('no piece');
            const own=selected.color,enemy=own==='w'?'b':'w',legalContext=!input.diagram,king=selected.type==='k';
            const copy=()=>new exports.Chess(g.fen(),{skipValidation:!legalContext});
            const enemyGame=()=>{const fields=g.fen().split(' ');if(fields[1]!==enemy){fields[1]=enemy;fields[3]='-'}return new exports.Chess(fields.join(' '))};
            const captures=legalContext&&!king ? enemyGame().moves({verbose:true}).filter(m=>m.captured && (m.to===input.square || (m.flags.includes('e') && m.to[0]+m.from[1]===input.square))) : [];
            const responses=captures.map(m=>{const after=enemyGame();after.move({from:m.from,to:m.to,promotion:m.promotion||'q'});const replies=after.moves({verbose:true}).filter(r=>r.to===m.to && r.captured);return {move:m,replies}});
            const geometric=g.attackers(input.square,input.mode==='protected'?own:enemy);
            const sources=new Set(geometric);
            if(input.mode==='protected')for(const r of responses)for(const reply of r.replies)sources.add(reply.from);
            else for(const m of captures)sources.add(m.from);
            const safeCoverage=from=>{const test=copy(),piece=test.get(from);test.remove(input.square);test.remove(from);test.put(piece,input.square);const k=test.board().flat().find(p=>p&&p.color===own&&p.type==='k');return !!k&&!test.isAttacked(k.square,enemy)};
            const relations=[...sources].sort().map(from=>{
                const p=g.get(from),coverage=geometric.includes(from);
                let status='coverage',replies=[],enPassant=false;
                if(legalContext&&!king){
                    if(input.mode==='attacked'){
                        const moves=captures.filter(m=>m.from===from);status=moves.length?'available':'restricted';enPassant=moves.some(m=>m.flags.includes('e'));
                        replies=moves.map(m=>({attackerSquare:from,attackerPiece:p.type,captureSAN:m.san,destination:m.to,canRecapture:false,recaptures:[]}));
                    }else{
                        replies=responses.map(r=>({attackerSquare:r.move.from,attackerPiece:r.move.piece,captureSAN:r.move.san,destination:r.move.to,canRecapture:r.replies.some(m=>m.from===from),recaptures:r.replies.filter(m=>m.from===from).map(m=>m.san)}));
                        if(replies.length){const count=replies.filter(r=>r.canRecapture).length;status=count===replies.length?'available':count?'conditional':'restricted'}
                        else if(!safeCoverage(from))status='restricted';
                    }
                }
                return {square:from,piece:p.type,color:p.color,status,coverage,enPassant,responses:replies};
            });
            return {square:input.square,piece:selected.type,color:own,mode:input.mode,legalContext,relations};
        })()
        """
        return try decoded(expression,RelationshipInspection.self)
    }
    public static let squares=(1...8).flatMap {r in "abcdefgh".map {String($0)+String(r)}}
    public static func validSquare(_ s:String)->Bool {s.count==2 && s.first.map{"abcdefgh".contains($0)}==true && s.last.map{"12345678".contains($0)}==true}
    public static func validUCI(_ s:String)->Bool {(s.count==4 || s.count==5) && validSquare(String(s.prefix(2))) && validSquare(String(s.dropFirst(2).prefix(2))) && (s.count==4 || "qrbn".contains(s.last!))}
}
