import Foundation
public struct ReviewImportError:Error,LocalizedError {public let record:Int,token:Int,reason:String;public var errorDescription:String? {"Record \(record), token \(token): \(reason)"}}
public enum PGNImporter {
    private enum Kind {case tag(String,String),word(String),comment(String),open,close}
    private struct Token {let kind:Kind,start:Int,end:Int}
    private struct Builder {var parent:Int?,children:[Int]=[],move:MoveRecord?=nil,fen:String,ply:Int,before:[String]=[],after:[String]=[],nags:[Int]=[]}
    public static func parse(_ data:Data,provenance:String="Imported",cancelled:@escaping ()->Bool={false})throws -> [GameDocument] {try parseReport(data,provenance:provenance,cancelled:cancelled).documents}
    /// Every readable game, plus the games that could not be read: one bad game in a collection is skipped and
    /// reported, never allowed to fail the whole file. A file with no readable game fails with its first problem.
    public static func parseReport(_ data:Data,provenance:String="Imported",cancelled:@escaping ()->Bool={false})throws -> (documents:[GameDocument],skipped:[ReviewImportError]) {
        guard data.count<=ReviewPolicy.maximumBytes else{throw ReviewImportError(record:1,token:0,reason:"File exceeds the 16 MiB limit.")}
        // The PGN standard's character set is ISO 8859-1; many exports (ChessBase, TWIC) still use it.
        guard var source=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.windowsCP1252) ?? String(data:data,encoding:.isoLatin1) else{throw ReviewImportError(record:1,token:0,reason:"The file is not readable text.")}
        if source.first=="\u{feff}"{source.removeFirst()};guard !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ReviewImportError(record:1,token:0,reason:"The file is empty.")}
        var trimmed=source.trimmingCharacters(in:.whitespacesAndNewlines)
        if trimmed.split(separator:" ").count==4,!trimmed.contains("["),trimmed.split(whereSeparator:{$0.isWhitespace}).first?.filter({$0=="/"}).count==7{trimmed+=" 0 1"}
        if let boardField=trimmed.split(whereSeparator:{$0.isWhitespace}).first,boardField.filter({$0=="/"}).count==7,!trimmed.contains("[") {
            let fullmove=try validateFEN(trimmed)
            let rules=try ChessRules(fen:trimmed),fields=trimmed.split(separator:" "),root=GameNode(id:0,parent:nil,children:[],uci:nil,san:nil,beforeFEN:rules.fen,afterFEN:rules.fen,ply:0,fullmove:fullmove,side:String(fields[1]),commentsBefore:[],commentsAfter:[],nags:[])
            let document=GameDocument(schemaVersion:1,id:UUID(),contentHash:reviewHash(data),importedAt:Date(),provenance:provenance,original:data,headers:[],startingFEN:rules.fen,result:"*",termination:nil,historyAvailable:false,nodes:[root])
            ImportedDocuments.shared.record(document);return ([document],[])
        }
        let chars=Array(source.unicodeScalars),results=Set(["1-0","0-1","1/2-1/2","*"]),resultSpellings=["1/2":"1/2-1/2","½-½":"1/2-1/2"]
        try refuseOversizedCollection(chars,cancelled:cancelled,results:results,spellings:resultSpellings)
        let scanner=Scanner(chars,cancelled:cancelled);var records:[GameDocument]=[],skipped:[ReviewImportError]=[],index=0,token:Token?,lookahead:ReviewImportError?,consumed=false
        // `consumed` marks a token the lexer could not read: `token` still holds the one before it, already read.
        // `nesting` counts the variations open in the current game at the token being read, so recovery from a failure
        // inside a variation knows a result marker there is not the game's own.
        var nesting=0
        func advance()throws {if !consumed,let left=token{if case .open=left.kind{nesting+=1}else if case .close=left.kind{nesting=max(0,nesting-1)}};index+=1;consumed=true;token=try scanner.next();consumed=false}
        /// Skips the rest of a game that cannot be read (see the catch below), up to the next game's headers or past its own
        /// top-level result, so a headerless game after it still imports. A lexical error here is part of the game already
        /// reported, and never costs the games around it; one after the result belongs to the next game, which it costs.
        func skipGame(movetext initial:Bool,depth start:Int=0)throws {var movetext=initial,depth=start;while consumed || token != nil {if !consumed{switch token!.kind {
            case .tag:if movetext{return}
            case .open:movetext=true;depth+=1
            case .close:movetext=true;depth=max(0,depth-1)
            case .comment:movetext=true
            case .word(let spelled):movetext=true;if depth==0,results.contains(resultSpellings[spelled] ?? spelled){scanner.record=records.count+skipped.count+1;do{try advance();return}catch let problem as ReviewImportError{skipped.append(problem);movetext=false;continue}}
        }};do{try advance()}catch is ReviewImportError{}}}
        do{token=try scanner.next()}catch let problem as ReviewImportError{skipped.append(problem);consumed=true;try skipGame(movetext:false)}
        while token != nil {
            if cancelled(){throw CheckmateError.cancelled};guard records.count<ReviewPolicy.maximumRecords else{throw ReviewImportError(record:records.count+1,token:index,reason:"Too many game records.")}
            scanner.record=records.count+skipped.count+1;nesting=0
            // Commentary before a game's headers (or after the last result) belongs to no move. The game's text starts
            // with it, because its root keeps it: re-reading that text alone must give the same tree.
            let start=token!.start,recordNumber=records.count+skipped.count+1;var preamble:[String]=[],failedInHeaders=false,ended=false
            do{
            while token != nil,case let .comment(text)=token!.kind {preamble.append(text);try advance()}
            if token==nil{break}
            let document=try autoreleasepool{() throws -> GameDocument in
            var headers:[PGNHeader]=[],names:Set<String>=[]
            while token != nil,case let .tag(name,value)=token!.kind {guard names.insert(name).inserted else{failedInHeaders=true;throw ReviewImportError(record:recordNumber,token:index,reason:"Duplicate header \(name).")};headers.append(PGNHeader(name,value));try advance()}
            func failure(_ reason:String)->ReviewImportError {ReviewImportError(record:recordNumber,token:index,reason:reason)}
            let variant=headers.first{$0.name=="Variant"}?.value.lowercased();guard variant==nil || ["standard","normal","normal chess","chess","from position"].contains(variant!) else{throw failure("Only standard chess is supported.")}
            // A FEN header alone (common in exports) is a custom start; SetUp 1 without a FEN, or SetUp 0 with one, conflicts.
            var fen=headers.first{$0.name=="FEN"}?.value;if let value=fen,value.split(separator:" ").count==4{fen=value+" 0 1"}
            let setup=headers.first{$0.name=="SetUp"}?.value
            guard setup==nil || ["0","1"].contains(setup!),setup != "1" || fen != nil,fen==nil || setup != "0" else{throw failure("Custom positions require SetUp 1 and FEN together.")}
            // An unreadable start position is this game's problem, reported like any other; it never fails the file.
            let root:ChessRules;do{if let fen=fen{try validateFEN(fen)};root=try ChessRules(fen:fen)}catch CheckmateError.cancelled{throw CheckmateError.cancelled}catch{throw failure("Invalid FEN: \(userFacingMessage(error,fallback:"the position cannot be read."))")}
            let starting=root.fen;var builders=[Builder(parent:nil,fen:starting,ply:0,before:preamble)],marker:String?,markerEnd:Int?
            func sequence(parent initial:Int,depth:Int)throws {
                guard depth<=ReviewPolicy.maximumDepth else{throw failure("Variation nesting exceeds 32.")};var cursor=initial,played=false,leading:[String]=[],rules:ChessRules?
                while token != nil {
                    if cancelled(){throw CheckmateError.cancelled}
                    switch token!.kind {
                    case .tag: if depth>0{throw failure("Header inside variation.")};return
                    case .close:guard depth>0 else{throw failure("Unexpected closing variation.")};try advance();return
                    case .open:
                        guard let parent=builders[cursor].parent else{throw failure("Variation needs a preceding move.")};try advance();try sequence(parent:parent,depth:depth+1)
                    case .comment(let text):
                        if played{builders[cursor].after.append(text)}else if depth==0{builders[initial].before.append(text)}else{leading.append(text)};try advance()
                    case .word(let spelled):
                        let raw=resultSpellings[spelled] ?? spelled
                        // The token after a result belongs to the next record: a lexical error in it is reported for
                        // that record and never costs this one.
                        if results.contains(raw) {guard depth==0 else{let problem=failure("Result marker inside variation.");do{try advance()}catch is ReviewImportError{};throw problem};marker=raw;markerEnd=token!.end;ended=true;scanner.record=recordNumber+1;do{try advance()}catch let problem as ReviewImportError{lookahead=problem};return}
                        try advance()
                        if raw.hasPrefix("$"){guard let nag=Int(raw.dropFirst()),(0...255).contains(nag),played else{throw failure("Invalid annotation glyph.")};builders[cursor].nags.append(nag);continue}
                        var san=raw
                        if let match=san.range(of:"^[0-9]+\\.(\\.\\.)?",options:.regularExpression){san.removeSubrange(match)}
                        if san.isEmpty || san=="..."{continue}
                        let glyphs=["!!":3,"??":4,"!?":5,"?!":6,"!":1,"?":2];var nag:Int?
                        for suffix in ["!!","??","!?","?!","!","?"] where san.hasSuffix(suffix){nag=glyphs[suffix];san.removeLast(suffix.count);break}
                        guard builders.count<ReviewPolicy.maximumNodes else{throw failure("Tree node limit exceeded.")}
                        guard depth>0 || builders[cursor].ply<ReviewPolicy.maximumMainlinePlies else{throw failure("Mainline exceeds 2000 plies.")}
                        // Built at the first move, so an empty or comment-only variation costs no chess.js context.
                        let board=try rules ?? ChessRules(fen:builders[initial].fen);rules=board
                        guard let move=try legalMove(san,rules:board) else{throw failure("Illegal or ambiguous SAN: \(san).")}
                        try board.move(uci:move.uci);let next=builders.count
                        builders.append(Builder(parent:cursor,move:move,fen:board.fen,ply:builders[cursor].ply+1,before:leading,nags:nag.map{[$0]} ?? []));leading=[];builders[cursor].children.append(next);cursor=next;played=true
                    }
                }
                if depth>0{throw failure("Unclosed variation.")}
            }
            try sequence(parent:0,depth:0)
            // Move lists copied from websites often omit the result: take the Result header, else unfinished (*).
            let tagged=headers.first(where:{$0.name=="Result"})?.value,result=marker ?? tagged.flatMap{results.contains($0) ? $0:nil} ?? "*"
            if let tagged,tagged != result{throw failure("Result header conflicts with movetext result.")}
            let end=markerEnd ?? (token != nil ? token!.start:chars.count)
            let original=Data(String(String.UnicodeScalarView(chars[start..<end])).trimmingCharacters(in:.whitespacesAndNewlines).utf8)
            let nodes=builders.enumerated().map{offset,b -> GameNode in let fields=(b.move?.before ?? b.fen).split(separator:" ");return GameNode(id:offset,parent:b.parent,children:b.children,uci:b.move?.uci,san:b.move?.san,beforeFEN:b.move?.before ?? b.fen,afterFEN:b.fen,ply:b.ply,fullmove:Int(fields[5]) ?? 1,side:String(fields[1]),commentsBefore:b.before,commentsAfter:b.after,nags:b.nags)}
            // Preserve exact bytes for single-record input, including BOM and whitespace; a file holding a skipped
            // game as well is not this record's text.
            let preserved=records.isEmpty && skipped.isEmpty && token==nil ? data:original
            return GameDocument(schemaVersion:1,id:UUID(),contentHash:reviewHash(preserved),importedAt:Date(),provenance:provenance,original:preserved,headers:headers,startingFEN:starting,result:result,termination:headers.first{$0.name=="Termination"}?.value,historyAvailable:true,nodes:nodes)
            };records.append(document);ImportedDocuments.shared.record(document);if let problem=lookahead{lookahead=nil;throw problem}
            }catch let problem as ReviewImportError{
                // Skip to the next game's headers; the bad game is reported, the rest still import. A game that failed
                // inside its own headers is skipped past its movetext first, so its remainder is not read as a game. A game
                // that failed after reading its own result (a conflicting Result header) has nothing left to skip.
                skipped.append(problem);if let pending=lookahead{lookahead=nil;skipped.append(pending)};if consumed,let last=token,case .tag=last.kind{failedInHeaders=true};if !ended || consumed{try skipGame(movetext:!failedInHeaders,depth:failedInHeaders ? 0:nesting)}
            }
        }
        guard !records.isEmpty else{throw skipped.first ?? ReviewImportError(record:1,token:0,reason:"No game records.")};return (records,skipped)
    }
    /// Counts game records from tokens alone, dividing them as `parseReport` does, so a collection over the limit is
    /// refused before any game is built rather than after building the first 1000. A lexical error ends the count;
    /// the parse then reports it against its own game.
    private static func refuseOversizedCollection(_ chars:[Unicode.Scalar],cancelled:@escaping ()->Bool,results:Set<String>,spellings:[String:String])throws {
        let scanner=Scanner(chars,cancelled:cancelled);var count=0,open=false,moves=false,depth=0
        do{while let token=try scanner.next() {
            switch token.kind {
            case .comment:continue
            case .tag:if !open || moves{count+=1;open=true;moves=false;depth=0}
            case .open:if !open{count+=1;open=true};moves=true;depth+=1
            case .close:if !open{count+=1;open=true};moves=true;depth=max(0,depth-1)
            case .word(let spelled):if !open{count+=1;open=true};moves=true;if depth==0,results.contains(spellings[spelled] ?? spelled){open=false;moves=false}
            }
            if count>ReviewPolicy.maximumRecords{break}
        }}catch is ReviewImportError{}
        guard count<=ReviewPolicy.maximumRecords else{throw ReviewImportError(record:count,token:scanner.count-1,reason:"The file has more than \(ReviewPolicy.maximumRecords) games; split it into smaller files.")}
    }
    /// Accept common legal overspecification/check-suffix omissions, but never resolve ambiguity by guessing.
    private static func legalMove(_ san:String,rules:ChessRules)throws -> MoveRecord? {
        let clean=san.replacingOccurrences(of:"0",with:"O").replacingOccurrences(of:"[+#]+$",with:"",options:.regularExpression).replacingOccurrences(of:"^([a-h](?:x[a-h])?[18])([QRBN])$",with:"$1=$2",options:.regularExpression)
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
    /// Validates a full six-field FEN and returns its fullmove number. chess.js reads the counters with
    /// `parseInt`, so it accepts `1.`, `1x` or `1e3`; the counters are checked here as plain decimal digits.
    @discardableResult public static func validateFEN(_ fen:String)throws -> Int {
        let rules=try ChessRules(fen:fen),fields=fen.split(separator:" ");guard fields.count==6 else{throw CheckmateError.invalid("FEN needs six fields.")}
        guard fenCounter(fields[4]) != nil,let fullmove=fenCounter(fields[5]),fullmove>=1 else{throw CheckmateError.invalid("FEN move counters must be whole numbers, with the move number at least 1.")}
        let board=rules.board
        guard board.values.filter({$0=="wk"}).count==1,board.values.filter({$0=="bk"}).count==1 else{throw CheckmateError.invalid("FEN must have one king per side.")}
        guard !board.contains(where:{$0.value.hasSuffix("p") && ($0.key.hasSuffix("1") || $0.key.hasSuffix("8"))}) else{throw CheckmateError.invalid("Pawns cannot occupy the first or eighth rank.")}
        let white=board.first{$0.value=="wk"}!.key,black=board.first{$0.value=="bk"}!.key
        guard !rules.attackers(white,"b").contains(black),!rules.attackers(black,"w").contains(white) else{throw CheckmateError.invalid("Kings cannot be adjacent.")}
        let other=rules.turn=="w" ? "b":"w",king=other=="w" ? white:black
        guard rules.attackers(king,rules.turn).isEmpty else{throw CheckmateError.invalid("The side that just moved cannot remain in check.")}
        for (right,kingSquare,rookSquare,color) in [("K","e1","h1","w"),("Q","e1","a1","w"),("k","e8","h8","b"),("q","e8","a8","b")] where fields[2].contains(right) {guard board[kingSquare]==color+"k",board[rookSquare]==color+"r" else{throw CheckmateError.invalid("Castling rights do not match the pieces.")}}
        if fields[3] != "-" {let target=String(fields[3]),rank=rules.turn=="w" ? "6":"3",pawnSquare=String(target.prefix(1))+(rules.turn=="w" ? "5":"4"),origin=String(target.prefix(1))+(rules.turn=="w" ? "7":"2");guard board[origin]==nil, target.hasSuffix(rank),board[target]==nil,board[pawnSquare]==other+"p",fields[4]=="0" else{throw CheckmateError.invalid("En passant target is inconsistent.")}}
        return fullmove
    }
    /// A FEN move counter: one to six ASCII digits, so it always fits an `Int`.
    private static func fenCounter(_ field:Substring)->Int? {guard (1...6).contains(field.count),field.allSatisfy({("0"..."9").contains($0)}) else{return nil};return Int(field)}
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
        if !document.historyAvailable{let rules=try ChessRules(fen:document.startingFEN);records.append(Data(terminated(rules.pgn).utf8))}
        var seen:Set<UUID>=[]
        for branch in branches where !branch.moves.isEmpty && seen.insert(branch.id).inserted {
            guard branch.moves.count<=ReviewPolicy.maximumBranchPlies else{throw CheckmateError.invalid("Idea game exceeds the move limit.")}
            let rules=try document.rules(at:branch.root)
            for move in branch.moves{try rules.move(uci:move)}
            var pgn=rules.pgn
            pgn=pgn.replacingOccurrences(of:"[Event \"?\"]",with:"[Event \"Checkmate imagined line\"]")
            if !pgn.contains("[Event "){pgn="[Event \"Checkmate imagined line\"]\n"+pgn}
            records.append(Data(terminated(pgn).utf8))
        }
        var data=Data();for record in records{if !data.isEmpty{data.append(Data("\n\n".utf8))};data.append(record)};return data
    }
    /// chess.js already ends its PGN with a result; a second one would read back as an extra empty game.
    private static func terminated(_ pgn:String)->String {["*","1-0","0-1","1/2-1/2"].contains(pgn.split(whereSeparator:{$0.isWhitespace}).last.map(String.init) ?? "") ? pgn:pgn+"\n*"}
}
