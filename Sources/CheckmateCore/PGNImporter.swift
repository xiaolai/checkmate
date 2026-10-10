import Foundation
public struct ReviewImportError:Error,LocalizedError {public let record:Int,token:Int,reason:String;public var errorDescription:String? {"Record \(record), token \(token): \(reason)"}}
public enum PGNImporter {
    private enum Kind {case tag(String,String),word(String),comment(String),open,close}
    private struct Token {let kind:Kind,start:Int,end:Int}
    private struct Builder {var parent:Int?,children:[Int]=[],move:MoveRecord?=nil,fen:String,ply:Int,before:[String]=[],after:[String]=[],nags:[Int]=[]}
    public static func parse(_ data:Data,provenance:String="Imported",cancelled:@escaping ()->Bool={false})throws -> [GameDocument] {
        guard data.count<=ReviewPolicy.maximumBytes else{throw ReviewImportError(record:1,token:0,reason:"File exceeds the 16 MiB limit.")}
        guard var source=String(data:data,encoding:.utf8) else{throw ReviewImportError(record:1,token:0,reason:"Use UTF-8 PGN text.")}
        if source.first=="\u{feff}"{source.removeFirst()};guard !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ReviewImportError(record:1,token:0,reason:"The file is empty.")}
        let trimmed=source.trimmingCharacters(in:.whitespacesAndNewlines)
        if let boardField=trimmed.split(whereSeparator:{$0.isWhitespace}).first,boardField.filter({$0=="/"}).count==7,!trimmed.contains("[") {
            try validateFEN(trimmed)
            let rules=try ChessRules(fen:trimmed),fields=trimmed.split(separator:" "),root=GameNode(id:0,parent:nil,children:[],uci:nil,san:nil,beforeFEN:rules.fen,afterFEN:rules.fen,ply:0,fullmove:Int(fields[5])!,side:String(fields[1]),commentsBefore:[],commentsAfter:[],nags:[])
            return [GameDocument(schemaVersion:1,id:UUID(),contentHash:reviewHash(data),importedAt:Date(),provenance:provenance,original:data,headers:[],startingFEN:rules.fen,result:"*",termination:nil,historyAvailable:false,nodes:[root])]
        }
        let chars=Array(source.unicodeScalars),scanner=Scanner(chars,cancelled:cancelled),results=Set(["1-0","0-1","1/2-1/2","*"]);var records:[GameDocument]=[],index=0,token=try scanner.next()
        func advance()throws {index+=1;token=try scanner.next()}
        while token != nil {
            if cancelled(){throw CheckmateError.cancelled};guard records.count<ReviewPolicy.maximumRecords else{throw ReviewImportError(record:records.count+1,token:index,reason:"Too many game records.")}
            scanner.record=records.count+1
            let document=try autoreleasepool{() throws -> GameDocument in
            let start=token!.start;var headers:[PGNHeader]=[]
            while token != nil,case let .tag(name,value)=token!.kind {guard !headers.contains(where:{$0.name==name}) else{throw ReviewImportError(record:records.count+1,token:index,reason:"Duplicate header \(name).")};headers.append(PGNHeader(name,value));try advance()}
            func failure(_ reason:String)->ReviewImportError {ReviewImportError(record:records.count+1,token:index,reason:reason)}
            let variant=headers.first{$0.name=="Variant"}?.value.lowercased();guard variant==nil || ["standard","normal","normal chess","chess"].contains(variant!) else{throw failure("Only standard chess is supported.")}
            let fen=headers.first{$0.name=="FEN"}?.value
            let setup=headers.first{$0.name=="SetUp"}?.value
            guard setup==nil || ["0","1"].contains(setup!),setup != "1" || fen != nil,fen==nil || setup=="1" else{throw failure("Custom positions require SetUp 1 and FEN together.")}
            if let fen=fen{try validateFEN(fen)}
            let root=try ChessRules(fen:fen),starting=root.fen;var builders=[Builder(parent:nil,fen:starting,ply:0)],marker:String?
            func sequence(parent initial:Int,depth:Int)throws {
                guard depth<=ReviewPolicy.maximumDepth else{throw failure("Variation nesting exceeds 32.")};var cursor=initial,played=false,leading:[String]=[];let rules=try ChessRules(fen:builders[initial].fen)
                while token != nil {
                    if cancelled(){throw CheckmateError.cancelled}
                    switch token!.kind {
                    case .tag: if depth>0{throw failure("Header inside variation.")};return
                    case .close:guard depth>0 else{throw failure("Unexpected closing variation.")};try advance();return
                    case .open:
                        guard let parent=builders[cursor].parent else{throw failure("Variation needs a preceding move.")};try advance();try sequence(parent:parent,depth:depth+1)
                    case .comment(let text):
                        if played{builders[cursor].after.append(text)}else if depth==0{builders[initial].before.append(text)}else{leading.append(text)};try advance()
                    case .word(let raw):
                        // The token after a result belongs to the next record; attribute lexer errors there.
                        if results.contains(raw) {guard depth==0 else{throw failure("Result marker inside variation.")};marker=raw;scanner.record=records.count+2;try advance();return}
                        try advance()
                        if raw.hasPrefix("$"){guard let nag=Int(raw.dropFirst()),(0...255).contains(nag),played else{throw failure("Invalid annotation glyph.")};builders[cursor].nags.append(nag);continue}
                        var san=raw
                        if let match=san.range(of:"^[0-9]+\\.(\\.\\.)?",options:.regularExpression){san.removeSubrange(match)}
                        if san.isEmpty || san=="..."{continue}
                        let glyphs=["!!":3,"??":4,"!?":5,"?!":6,"!":1,"?":2];var nag:Int?
                        for suffix in ["!!","??","!?","?!","!","?"] where san.hasSuffix(suffix){nag=glyphs[suffix];san.removeLast(suffix.count);break}
                        guard builders.count<ReviewPolicy.maximumNodes else{throw failure("Tree node limit exceeded.")}
                        guard depth>0 || builders[cursor].ply<ReviewPolicy.maximumMainlinePlies else{throw failure("Mainline exceeds 2000 plies.")}
                        guard let move=try legalMove(san,rules:rules) else{throw failure("Illegal or ambiguous SAN: \(san).")}
                        try rules.move(uci:move.uci);let next=builders.count
                        builders.append(Builder(parent:cursor,move:move,fen:rules.fen,ply:builders[cursor].ply+1,before:leading,nags:nag.map{[$0]} ?? []));leading=[];builders[cursor].children.append(next);cursor=next;played=true
                    }
                }
                if depth>0{throw failure("Unclosed variation.")}
            }
            try sequence(parent:0,depth:0)
            guard let marker=marker else{throw failure("A game must end with a result marker, including * for unfinished records.")}
            if let tagged=headers.first(where:{$0.name=="Result"})?.value,tagged != marker{throw failure("Result header conflicts with movetext result.")}
            let end=token != nil ? token!.start:chars.count
            let original=Data(String(String.UnicodeScalarView(chars[start..<end])).trimmingCharacters(in:.whitespacesAndNewlines).utf8)
            let nodes=builders.enumerated().map{offset,b -> GameNode in let fields=(b.move?.before ?? b.fen).split(separator:" ");return GameNode(id:offset,parent:b.parent,children:b.children,uci:b.move?.uci,san:b.move?.san,beforeFEN:b.move?.before ?? b.fen,afterFEN:b.fen,ply:b.ply,fullmove:Int(fields[5]) ?? 1,side:String(fields[1]),commentsBefore:b.before,commentsAfter:b.after,nags:b.nags)}
            // Preserve exact bytes for single-record input, including BOM and whitespace.
            let preserved=records.isEmpty && token==nil ? data:original
            return GameDocument(schemaVersion:1,id:UUID(),contentHash:reviewHash(preserved),importedAt:Date(),provenance:provenance,original:preserved,headers:headers,startingFEN:starting,result:marker,termination:headers.first{$0.name=="Termination"}?.value,historyAvailable:true,nodes:nodes)
            };records.append(document)
        }
        guard !records.isEmpty else{throw ReviewImportError(record:1,token:0,reason:"No game records.")};return records
    }
    /// Accept common legal overspecification/check-suffix omissions, but never resolve ambiguity by guessing.
    private static func legalMove(_ san:String,rules:ChessRules)throws -> MoveRecord? {
        let clean=san.replacingOccurrences(of:"0",with:"O").replacingOccurrences(of:"[+#]+$",with:"",options:.regularExpression)
        let legal=rules.moves(),canonical=legal.filter{$0.san.replacingOccurrences(of:"[+#]+$",with:"",options:.regularExpression)==clean}
        if canonical.count==1{return canonical[0]}
        let regex=try NSRegularExpression(pattern:"^([KQRBN])([a-h])?([1-8])?(x?)([a-h][1-8])(?:=([QRBN]))?$")
        let text=clean as NSString
        guard let match=regex.firstMatch(in:clean,range:NSRange(location:0,length:text.length)) else{return nil}
        func group(_ index:Int)->String {let range=match.range(at:index);return range.location==NSNotFound ? "":text.substring(with:range)}
        let piece=group(1).lowercased(),file=group(2),rank=group(3),capture=group(4)=="x",target=group(5),promotion=group(6).lowercased()
        let matches=legal.filter{move in move.piece==piece && move.to==target && (file.isEmpty || move.from.hasPrefix(file)) && (rank.isEmpty || move.from.hasSuffix(rank)) && (promotion.isEmpty || move.promotion==promotion) && (capture==((move.captured != nil)) || (!file.isEmpty && !rank.isEmpty))}
        return matches.count==1 ? matches[0]:nil
    }
    public static func validateFEN(_ fen:String)throws {
        let rules=try ChessRules(fen:fen),fields=fen.split(separator:" ");guard fields.count==6 else{throw CheckmateError.invalid("FEN needs six fields.")}
        let board=rules.board
        guard board.values.filter({$0=="wk"}).count==1,board.values.filter({$0=="bk"}).count==1 else{throw CheckmateError.invalid("FEN must have one king per side.")}
        guard !board.contains(where:{$0.value.hasSuffix("p") && ($0.key.hasSuffix("1") || $0.key.hasSuffix("8"))}) else{throw CheckmateError.invalid("Pawns cannot occupy the first or eighth rank.")}
        let white=board.first{$0.value=="wk"}!.key,black=board.first{$0.value=="bk"}!.key
        guard !rules.attackers(white,"b").contains(black),!rules.attackers(black,"w").contains(white) else{throw CheckmateError.invalid("Kings cannot be adjacent.")}
        let other=rules.turn=="w" ? "b":"w",king=other=="w" ? white:black
        guard rules.attackers(king,rules.turn).isEmpty else{throw CheckmateError.invalid("The side that just moved cannot remain in check.")}
        for (right,kingSquare,rookSquare,color) in [("K","e1","h1","w"),("Q","e1","a1","w"),("k","e8","h8","b"),("q","e8","a8","b")] where fields[2].contains(right) {guard board[kingSquare]==color+"k",board[rookSquare]==color+"r" else{throw CheckmateError.invalid("Castling rights do not match the pieces.")}}
        if fields[3] != "-" {let target=String(fields[3]),rank=rules.turn=="w" ? "6":"3",pawnSquare=String(target.prefix(1))+(rules.turn=="w" ? "5":"4"),origin=String(target.prefix(1))+(rules.turn=="w" ? "7":"2");guard board[origin]==nil, target.hasSuffix(rank),board[target]==nil,board[pawnSquare]==other+"p",fields[4]=="0" else{throw CheckmateError.invalid("En passant target is inconsistent.")}}
    }
    /// Streaming lexer retains only one token, so collection limits do not imply a huge token array.
    private final class Scanner {
        let chars:[Unicode.Scalar],cancelled:()->Bool
        var i=0,count=0,record=1
        init(_ chars:[Unicode.Scalar],cancelled:@escaping ()->Bool){self.chars=chars;self.cancelled=cancelled}
        func next()throws -> Token? {defer{count+=1}
        func fail(_ reason:String)->ReviewImportError {ReviewImportError(record:record,token:count,reason:reason)}
        while i<chars.count {
            if i % 256 == 0,cancelled(){throw CheckmateError.cancelled};if chars[i].properties.isWhitespace{i+=1;continue};let start=i,c=chars[i];i+=1
            if c=="{" {var text="";while i<chars.count,chars[i] != "}"{text.unicodeScalars.append(chars[i]);i+=1;if i % 256 == 0,cancelled(){throw CheckmateError.cancelled};guard i-start<=ReviewPolicy.maximumTextScalars else{throw fail("Comment exceeds text limit.")}};guard i<chars.count else{throw fail("Unclosed comment.")};i+=1;return Token(kind:.comment(text),start:start,end:i)}
            else if c==";" {var text="";while i<chars.count,chars[i] != "\n",chars[i] != "\r"{text.unicodeScalars.append(chars[i]);i+=1;if i % 256 == 0,cancelled(){throw CheckmateError.cancelled};guard i-start<=ReviewPolicy.maximumTextScalars else{throw fail("Comment exceeds text limit.")}};return Token(kind:.comment(text),start:start,end:i)}
            else if c=="(" || c==")" {return Token(kind:c=="(" ? .open:.close,start:start,end:i)}
            else if c=="[" {
                while i<chars.count,chars[i].properties.isWhitespace{i+=1};var name="";while i<chars.count,!chars[i].properties.isWhitespace,chars[i] != "\""{name.unicodeScalars.append(chars[i]);i+=1;guard name.unicodeScalars.count<=ReviewPolicy.maximumTokenScalars else{throw fail("Header name is too long.")}};while i<chars.count,chars[i].properties.isWhitespace{i+=1};guard !name.isEmpty,i<chars.count,chars[i]=="\"" else{throw fail("Invalid PGN header.")};i+=1;var value="",closed=false
                while i<chars.count {if i % 256 == 0,cancelled(){throw CheckmateError.cancelled};guard i-start<=ReviewPolicy.maximumTextScalars else{throw fail("Header exceeds text limit.")};let ch=chars[i];i+=1;if ch=="\""{closed=true;break};if ch=="\\"{guard i<chars.count,["\\","\""].contains(chars[i]) else{throw fail("Invalid header escape.")};value.unicodeScalars.append(chars[i]);i+=1}else{value.unicodeScalars.append(ch)}}
                while i<chars.count,chars[i].properties.isWhitespace{i+=1};guard closed,i<chars.count,chars[i]=="]" else{throw fail("Unclosed PGN header.")};i+=1;return Token(kind:.tag(name,value),start:start,end:i)
            }else {var word=String(c);while i<chars.count,!chars[i].properties.isWhitespace,!"{}();[]".unicodeScalars.contains(chars[i]){word.unicodeScalars.append(chars[i]);i+=1;guard word.unicodeScalars.count<=ReviewPolicy.maximumTokenScalars else{throw fail("Movetext token is too long.")}};return Token(kind:.word(word),start:start,end:i)}
        };return nil
        }
    }
}
/// Cancellation is shared explicitly across detached parsing and its owning UI task.
public final class ReviewImportCancellation:@unchecked Sendable {
    private let lock=NSLock();private var value=false
    public init(){}
    public func cancel(){lock.lock();value=true;lock.unlock()}
    public var cancelled:Bool {lock.lock();defer{lock.unlock()};return value}
}
public enum PGNExporter {
    public static func original(_ document:GameDocument)->Data {document.original}
    /// Keep the imported record byte-for-byte, then append clearly identified idea games.
    /// Each idea includes the original preceding history and starts from the original FEN.
    public static func withIdeas(_ document:GameDocument,branches:[ReviewBranch])throws -> Data {
        guard branches.count<=ReviewPolicy.maximumBranches else{throw CheckmateError.invalid("Too many idea games.")}
        var records:[Data]=document.historyAvailable ? [document.original]:[]
        if !document.historyAvailable{let rules=try ChessRules(fen:document.startingFEN);records.append(Data((rules.pgn+"\n*").utf8))}
        var seen:Set<UUID>=[]
        for branch in branches where !branch.moves.isEmpty && seen.insert(branch.id).inserted {
            guard branch.moves.count<=ReviewPolicy.maximumBranchPlies else{throw CheckmateError.invalid("Idea game exceeds the move limit.")}
            let rules=try document.rules(at:branch.root)
            for move in branch.moves{try rules.move(uci:move)}
            var pgn=rules.pgn
            pgn=pgn.replacingOccurrences(of:"[Event \"?\"]",with:"[Event \"Checkmate imagined line\"]")
            if !pgn.contains("[Event "){pgn="[Event \"Checkmate imagined line\"]\n"+pgn}
            if !["*","1-0","0-1","1/2-1/2"].contains(pgn.split(whereSeparator:{$0.isWhitespace}).last.map(String.init) ?? ""){pgn+="\n*"}
            records.append(Data(pgn.utf8))
        }
        var data=Data();for record in records{if !data.isEmpty{data.append(Data("\n\n".utf8))};data.append(record)};return data
    }
}
