import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Foundation
public enum PGNImporter {
    private enum Kind {case tag(String,String),word(String),comment(String),open,close}
    private struct Token {let kind:Kind,start:Int,end:Int}
    private struct Builder {var parent:Int?,children:[Int]=[],move:MoveRecord?=nil,fen:String,ply:Int,before:[String]=[],after:[String]=[],nags:[Int]=[]}
    public static func parse(_ data:Data,provenance:ReviewProvenance = .imported,cancelled:@escaping ()->Bool={false})throws -> [GameDocument] {try parseReport(data,provenance:provenance,cancelled:cancelled).documents}
    /// Every readable game, plus the games that could not be read: one bad game in a collection is skipped and
    /// reported, never allowed to fail the whole file. A file with no readable game fails with its first problem.
    public static func parseReport(_ data:Data,provenance:ReviewProvenance = .imported,cancelled:@escaping ()->Bool={false})throws -> (documents:[GameDocument],skipped:[ReviewImportError]) {
        guard data.count<=ReviewPolicy.maximumBytes else{throw ReviewImportError(file:String(localized:"File exceeds the 16 MiB limit.",bundle:.checkmate))}
        // The PGN standard's character set is ISO 8859-1; many exports (ChessBase, TWIC) still use it.
        guard var source=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.windowsCP1252) ?? String(data:data,encoding:.isoLatin1) else{throw ReviewImportError(file:String(localized:"The file is not readable text.",bundle:.checkmate))}
        if source.first=="\u{feff}"{source.removeFirst()};guard !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ReviewImportError(file:String(localized:"The file is empty.",bundle:.checkmate))}
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
            if cancelled(){throw CheckmateError.cancelled};guard records.count<ReviewPolicy.maximumRecords else{throw ReviewImportError(file:String(localized:"Too many game records.",bundle:.checkmate))}
            scanner.record=records.count+skipped.count+1;nesting=0
            // Commentary before a game's headers (or after the last result) belongs to no move. The game's text starts
            // with it, because its root keeps it: re-reading that text alone must give the same tree.
            let start=token!.start,recordNumber=records.count+skipped.count+1;var preamble:[String]=[],failedInHeaders=false,ended=false
            do{
            while token != nil,case let .comment(text)=token!.kind {preamble.append(text);try advance()}
            if token==nil{break}
            let document=try autoreleasepool{() throws -> GameDocument in
            var headers:[PGNHeader]=[],names:Set<String>=[]
            while token != nil,case let .tag(name,value)=token!.kind {guard names.insert(name).inserted else{failedInHeaders=true;throw ReviewImportError(record:recordNumber,token:index,reason:String(localized:"Duplicate header \(name).",bundle:.checkmate))};headers.append(PGNHeader(name,value));try advance()}
            func failure(_ reason:String)->ReviewImportError {ReviewImportError(record:recordNumber,token:index,reason:reason)}
            let variant=headers.first{$0.name=="Variant"}?.value.lowercased();guard variant==nil || ["standard","normal","normal chess","chess","from position"].contains(variant!) else{throw failure(String(localized:"Only standard chess is supported.",bundle:.checkmate))} // not localized: PGN Variant tag values
            // A FEN header alone (common in exports) is a custom start; SetUp 1 without a FEN, or SetUp 0 with one, conflicts.
            var fen=headers.first{$0.name=="FEN"}?.value;if let value=fen,value.split(separator:" ").count==4{fen=value+" 0 1"}
            let setup=headers.first{$0.name=="SetUp"}?.value
            guard setup==nil || ["0","1"].contains(setup!),setup != "1" || fen != nil,fen==nil || setup != "0" else{throw failure(String(localized:"Custom positions require SetUp 1 and FEN together.",bundle:.checkmate))}
            // An unreadable start position is this game's problem, reported like any other; it never fails the file.
            let root:ChessRules;do{if let fen=fen{try validateFEN(fen)};root=try ChessRules(fen:fen)}catch CheckmateError.cancelled{throw CheckmateError.cancelled}catch{throw failure(String(localized:"Invalid FEN: \(userFacingMessage(error,fallback:String(localized:"the position cannot be read.",bundle:.checkmate,comment:"Why a start position is invalid, after Invalid FEN:")))",bundle:.checkmate))}
            let starting=root.fen;var builders=[Builder(parent:nil,fen:starting,ply:0,before:preamble)],marker:String?,markerEnd:Int?
            func sequence(parent initial:Int,depth:Int)throws {
                guard depth<=ReviewPolicy.maximumDepth else{throw failure(String(localized:"Variation nesting exceeds 32.",bundle:.checkmate))};var cursor=initial,played=false,leading:[String]=[],rules:ChessRules?
                while token != nil {
                    if cancelled(){throw CheckmateError.cancelled}
                    switch token!.kind {
                    case .tag: if depth>0{throw failure(String(localized:"Header inside variation.",bundle:.checkmate))};return
                    case .close:guard depth>0 else{throw failure(String(localized:"Unexpected closing variation.",bundle:.checkmate))};try advance();return
                    case .open:
                        guard let parent=builders[cursor].parent else{throw failure(String(localized:"Variation needs a preceding move.",bundle:.checkmate))};try advance();try sequence(parent:parent,depth:depth+1)
                    case .comment(let text):
                        if played{builders[cursor].after.append(text)}else if depth==0{builders[initial].before.append(text)}else{leading.append(text)};try advance()
                    case .word(let spelled):
                        let raw=resultSpellings[spelled] ?? spelled
                        // The token after a result belongs to the next record: a lexical error in it is reported for
                        // that record and never costs this one.
                        if results.contains(raw) {guard depth==0 else{let problem=failure(String(localized:"Result marker inside variation.",bundle:.checkmate));do{try advance()}catch is ReviewImportError{};throw problem};marker=raw;markerEnd=token!.end;ended=true;scanner.record=recordNumber+1;do{try advance()}catch let problem as ReviewImportError{lookahead=problem};return}
                        try advance()
                        if raw.hasPrefix("$"){guard let nag=Int(raw.dropFirst()),(0...255).contains(nag),played else{throw failure(String(localized:"Invalid annotation glyph.",bundle:.checkmate))};builders[cursor].nags.append(nag);continue}
                        var san=raw
                        if let match=san.range(of:"^[0-9]+\\.(\\.\\.)?",options:.regularExpression){san.removeSubrange(match)}
                        if san.isEmpty || san=="..."{continue}
                        let glyphs=["!!":3,"??":4,"!?":5,"?!":6,"!":1,"?":2];var nag:Int?
                        for suffix in ["!!","??","!?","?!","!","?"] where san.hasSuffix(suffix){nag=glyphs[suffix];san.removeLast(suffix.count);break}
                        guard builders.count<ReviewPolicy.maximumNodes else{throw failure(String(localized:"Tree node limit exceeded.",bundle:.checkmate))}
                        guard depth>0 || builders[cursor].ply<ReviewPolicy.maximumMainlinePlies else{throw failure(String(localized:"This game has more than 2,000 moves, counting each side's moves separately, which is more than Checkmate can review.",bundle:.checkmate))}
                        // Built at the first move, so an empty or comment-only variation costs no chess.js context.
                        let board=try rules ?? ChessRules(fen:builders[initial].fen);rules=board
                        guard let move=try legalMove(san,rules:board) else{throw failure(String(localized:"Illegal or ambiguous SAN: \(san).",bundle:.checkmate))}
                        try board.move(uci:move.uci);let next=builders.count
                        builders.append(Builder(parent:cursor,move:move,fen:board.fen,ply:builders[cursor].ply+1,before:leading,nags:nag.map{[$0]} ?? []));leading=[];builders[cursor].children.append(next);cursor=next;played=true
                    }
                }
                if depth>0{throw failure(String(localized:"Unclosed variation.",bundle:.checkmate))}
            }
            try sequence(parent:0,depth:0)
            // Move lists copied from websites often omit the result: take the Result header, else unfinished (*).
            let tagged=headers.first(where:{$0.name=="Result"})?.value,result=marker ?? tagged.flatMap{results.contains($0) ? $0:nil} ?? "*"
            if let tagged,tagged != result{throw failure(String(localized:"Result header conflicts with movetext result.",bundle:.checkmate))}
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
        guard !records.isEmpty else{throw skipped.first ?? ReviewImportError(file:String(localized:"No game records.",bundle:.checkmate))};return (records,skipped)
    }
    /// One record of a collection as the importer divides it: its byte range in the file and its header tags. Only the
    /// lexer runs (no replay, no document): a record is fully validated when it is opened.
    public struct RecordSpan:Equatable,Sendable {public let offset:Int,length:Int,tags:[String:String]}
    /// Splits a PGN collection into records with the importer's own lexer and record boundaries (`refuseOversizedCollection`).
    /// A lexical error makes the record it falls in unreadable; reading resumes at the next line that starts a header.
    /// Reading stops once `enough` readable records are found.
    public static func splitRecords(_ data:Data,maximumRecords:Int,stoppingAt enough:Int=Int.max,cancelled:@escaping ()->Bool={false})throws -> (records:[RecordSpan],unreadable:Int) {
        guard data.count<=ReviewPolicy.maximumBytes else{throw ReviewImportError(file:String(localized:"File exceeds the 16 MiB limit.",bundle:.checkmate))}
        let utf8=String(data:data,encoding:.utf8)
        guard var source=utf8 ?? String(data:data,encoding:.windowsCP1252) ?? String(data:data,encoding:.isoLatin1) else{throw ReviewImportError(file:String(localized:"The file is not readable text.",bundle:.checkmate))}
        // Foundation may or may not keep a UTF-8 byte order mark in the decoded text; the bytes decide where text starts.
        if source.first=="\u{feff}"{source.removeFirst()};let base=utf8 != nil && data.starts(with:[0xEF,0xBB,0xBF]) ? 3:0
        let chars=Array(source.unicodeScalars),results=Set(["1-0","0-1","1/2-1/2","*"]),spellings=["1/2":"1/2-1/2","½-½":"1/2-1/2"]
        // Scalar index to byte offset, advanced monotonically: a single-byte decoding has one byte per scalar.
        var cursor=(scalar:0,byte:base)
        func byte(_ index:Int)->Int {if utf8==nil{return base+index};while cursor.scalar<index{cursor.byte+=chars[cursor.scalar].utf8.count;cursor.scalar+=1};return cursor.byte}
        let scanner=Scanner(chars,cancelled:cancelled);var spans:[RecordSpan]=[],unreadable=0,open=false,moves=false,depth=0,start=0,end=0,tags:[String:String]=[:],broken=false
        func close(){if open{if broken{unreadable+=1}else{let first=byte(start),last=byte(end);spans.append(RecordSpan(offset:first,length:last-first,tags:tags))}};open=false;moves=false;depth=0;tags=[:];broken=false}
        func begin(_ at:Int){close();open=true;start=at;end=at}
        /// A record boundary: a header at the start of the file or at the start of a line that follows a blank line.
        /// Recovery resumes only there, so a broken game's remaining headers never become a game of their own.
        /// A line break is LF, CRLF or a lone CR, as the lexer accepts all three.
        func boundary(after index:Int)->Int {
            var i=index+1
            while i<chars.count {
                if chars[i]=="[" {var j=i-1,newlines=0;while j>=0,chars[j]==" " || chars[j]=="\t" || chars[j]=="\r" || chars[j]=="\n"{if chars[j]=="\n" || (chars[j]=="\r" && chars[j+1] != "\n"){newlines+=1};j-=1};if j<0 || newlines>=2{return i}}
                i+=1
            }
            return chars.count
        }
        func overLimit()->ReviewImportError? {spans.count+unreadable>maximumRecords ? ReviewImportError(file:String(localized:"The file has more than \(maximumRecords) games.",bundle:.checkmate)):nil}
        while true {
            if spans.count>=enough{return (spans,unreadable)}
            // Checked before every token, so a file of millions of tiny records is refused as soon as it passes the limit.
            if let problem=overLimit(){throw problem}
            let before=scanner.i,token:Token?
            do{token=try scanner.next()}catch is ReviewImportError{
                // The failed token starts at or after `before`: the record it belongs to is unreadable, and reading
                // resumes at the next record boundary after it (an unclosed comment does not swallow the games after it).
                // The failed token starts at the first non-whitespace scalar from `before` (the lexer skips only whitespace
                // between tokens); resuming strictly after it never rereads the same broken header.
                var failed=before;while failed<chars.count,chars[failed].properties.isWhitespace{failed+=1}
                if !open{begin(failed)};broken=true;let resume=boundary(after:failed);scanner.i=resume;end=max(end,failed);close();continue
            }
            guard let token else{break}
            switch token.kind {
            case .comment:if !open{continue}
            case .tag(let name,let value):if !open || moves{begin(token.start)};if tags[name]==nil,tags.count<32{tags[name]=Self.bounded(value,scalars:256)}
            case .open:if !open{begin(token.start)};moves=true;depth+=1
            case .close:if !open{begin(token.start)};moves=true;depth=max(0,depth-1)
            case .word(let spelled):if !open{begin(token.start)};moves=true;if depth==0,results.contains(spellings[spelled] ?? spelled){end=token.end;close();continue}
            }
            end=token.end
        }
        close()
        if let problem=overLimit(){throw problem}
        return (spans,unreadable)
    }
    /// Whether `data` holds at least two readable games, by the lexer alone and without the review's record limit: such a
    /// record is a collection (R-9). Text that cannot be split is not, and is left to the review parse to explain.
    public static func holdsSeveralRecords(_ data:Data,cancelled:@escaping ()->Bool={false})->Bool {((try? splitRecords(data,maximumRecords:Int.max,stoppingAt:2,cancelled:cancelled))?.records.count ?? 0)>=2}
    /// Untrusted text bounded by Unicode scalars (so also by UTF-8 bytes, at most four per scalar), never by grapheme
    /// clusters, which a run of combining marks can make arbitrarily long.
    public static func bounded(_ text:String,scalars limit:Int)->String {
        guard text.unicodeScalars.count>limit else{return text};var view=String.UnicodeScalarView();view.append(contentsOf:text.unicodeScalars.prefix(limit));return String(view)
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
        guard count<=ReviewPolicy.maximumRecords else{throw ReviewImportError(file:String(localized:"The file has more than \(ReviewPolicy.maximumRecords) games; split it into smaller files.",bundle:.checkmate))}
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
        guard !board.contains(where:{$0.value.hasSuffix("p") && ($0.key.hasSuffix("1") || $0.key.hasSuffix("8"))}) else{throw CheckmateError.invalid(String(localized:"Pawns cannot occupy the first or eighth rank.",bundle:.checkmate))}
        let white=board.first{$0.value=="wk"}!.key,black=board.first{$0.value=="bk"}!.key
        guard !rules.attackers(white,"b").contains(black),!rules.attackers(black,"w").contains(white) else{throw CheckmateError.invalid(String(localized:"Kings cannot be adjacent.",bundle:.checkmate))}
        let other=rules.turn=="w" ? "b":"w",king=other=="w" ? white:black
        guard rules.attackers(king,rules.turn).isEmpty else{throw CheckmateError.invalid(String(localized:"The side that just moved cannot remain in check.",bundle:.checkmate))}
        for (right,kingSquare,rookSquare,color) in [("K","e1","h1","w"),("Q","e1","a1","w"),("k","e8","h8","b"),("q","e8","a8","b")] where fields[2].contains(right) {guard board[kingSquare]==color+"k",board[rookSquare]==color+"r" else{throw CheckmateError.invalid(String(localized:"Castling rights do not match the pieces.",bundle:.checkmate))}}
        if fields[3] != "-" {let target=String(fields[3]),rank=rules.turn=="w" ? "6":"3",pawnSquare=String(target.prefix(1))+(rules.turn=="w" ? "5":"4"),origin=String(target.prefix(1))+(rules.turn=="w" ? "7":"2");guard board[origin]==nil, target.hasSuffix(rank),board[target]==nil,board[pawnSquare]==other+"p",fields[4]=="0" else{throw CheckmateError.invalid(String(localized:"En passant target is inconsistent.",bundle:.checkmate))}}
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
            if c=="{" {var text="";while i<chars.count,chars[i] != "}"{text.unicodeScalars.append(chars[i]);i+=1;if i % 256 == 0,cancelled(){throw CheckmateError.cancelled};guard i-start<=ReviewPolicy.maximumTextScalars else{throw fail(String(localized:"Comment exceeds text limit.",bundle:.checkmate))}};guard i<chars.count else{throw fail(String(localized:"Unclosed comment.",bundle:.checkmate))};i+=1;return Token(kind:.comment(text),start:start,end:i)}
            else if c==";" {var text="";while i<chars.count,chars[i] != "\n",chars[i] != "\r"{text.unicodeScalars.append(chars[i]);i+=1;if i % 256 == 0,cancelled(){throw CheckmateError.cancelled};guard i-start<=ReviewPolicy.maximumTextScalars else{throw fail(String(localized:"Comment exceeds text limit.",bundle:.checkmate))}};return Token(kind:.comment(text),start:start,end:i)}
            else if c=="(" || c==")" {return Token(kind:c=="(" ? .open:.close,start:start,end:i)}
            else if c=="[" {
                while i<chars.count,chars[i].properties.isWhitespace{i+=1};var name="";while i<chars.count,!chars[i].properties.isWhitespace,chars[i] != "\""{name.unicodeScalars.append(chars[i]);i+=1;guard name.unicodeScalars.count<=ReviewPolicy.maximumTokenScalars else{throw fail(String(localized:"Header name is too long.",bundle:.checkmate))}};while i<chars.count,chars[i].properties.isWhitespace{i+=1};guard !name.isEmpty,i<chars.count,chars[i]=="\"" else{throw fail(String(localized:"Invalid PGN header.",bundle:.checkmate))};i+=1;var value="",closed=false
                while i<chars.count {if i % 256 == 0,cancelled(){throw CheckmateError.cancelled};guard i-start<=ReviewPolicy.maximumTextScalars else{throw fail(String(localized:"Header exceeds text limit.",bundle:.checkmate))};let ch=chars[i];i+=1;if ch=="\""{closed=true;break};if ch=="\\"{guard i<chars.count,["\\","\""].contains(chars[i]) else{throw fail(String(localized:"Invalid header escape.",bundle:.checkmate))};value.unicodeScalars.append(chars[i]);i+=1}else{value.unicodeScalars.append(ch)}}
                while i<chars.count,chars[i].properties.isWhitespace{i+=1};guard closed,i<chars.count,chars[i]=="]" else{throw fail(String(localized:"Unclosed PGN header.",bundle:.checkmate))};i+=1;return Token(kind:.tag(name,value),start:start,end:i)
            }else {var word=String(c);while i<chars.count,!chars[i].properties.isWhitespace,!"{}();[]".unicodeScalars.contains(chars[i]){word.unicodeScalars.append(chars[i]);i+=1;guard word.unicodeScalars.count<=ReviewPolicy.maximumTokenScalars else{throw fail(String(localized:"Movetext token is too long.",bundle:.checkmate))}};return Token(kind:.word(word),start:start,end:i)}
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
    /// The comment that opens each imagined line in an export.
    public static let imaginedMarker="Imagined line" // not localized: a record comment read back
    private static let standardStart="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    /// One move of the exported tree: the game's own moves, then the imagined lines merged in.
    private struct Move {var parent:Int?,san:String?,uci:String?,before:[String],after:[String],nags:[Int],children:[Int],side:String,fullmove:Int,imagined:Bool}
    /// The game as one PGN record (R-13): its tags, moves, own variations, comments and glyphs; each imagined line as a
    /// variation from where it leaves the game (a line from the game's last move varies that move), opened by
    /// `imaginedMarker`; the engine's evaluation of each move, when given, as a `[%eval]` comment (White's view, in
    /// pawns, or `#n` for mate); and a move's grade as its glyph where the record gives it none.
    public static func withIdeas(_ document:GameDocument,branches:[ReviewBranch],evaluations:[Int:AnalysisScore]=[:],grades:[Int:MoveGrade]=[:])throws -> Data {
        guard branches.count<=ReviewPolicy.maximumBranches else{throw CheckmateError.invalid(String(localized:"Too many imagined lines.",bundle:.checkmate))}
        var moves=document.nodes.map{node in
            let fields=node.beforeFEN.split(separator:" ")
            var after=node.commentsAfter,nags=node.nags
            if node.parent != nil,let score=evaluations[node.id],!after.contains(where:{$0.contains("[%eval")}){after.append("[%eval \(score.kind=="mate" ? "#\(score.value)":String(format:"%.2f",Double(score.value)/100))]")}
            if node.parent != nil,let grade=grades[node.id],!nags.contains(where:{(1...6).contains($0)}){nags.insert(gradeNAGs[grade]!,at:0)}
            return Move(parent:node.parent,san:node.san,uci:node.uci,before:node.commentsBefore,after:after,nags:nags,children:node.children,side:fields.count>1 ? String(fields[1]):node.side,fullmove:fields.count>5 ? Int(fields[5]) ?? node.fullmove:node.fullmove,imagined:false)
        }
        var seen:Set<UUID>=[]
        for branch in branches where !branch.moves.isEmpty && seen.insert(branch.id).inserted {
            guard branch.moves.count<=ReviewPolicy.maximumBranchPlies else{throw CheckmateError.invalid(String(localized:"An imagined line exceeds the move limit.",bundle:.checkmate))}
            var rules=try document.rules(at:branch.root),cursor=branch.root,marked=false
            func add(_ record:MoveRecord,to parent:Int){
                let fields=record.before.split(separator:" ")
                moves.append(Move(parent:parent,san:record.san,uci:record.from+record.to+(record.promotion ?? ""),before:marked ? []:[imaginedMarker],after:[],nags:[],children:[],side:String(fields[1]),fullmove:Int(fields[5]) ?? 1,imagined:true))
                moves[parent].children.append(moves.count-1);marked=true
            }
            // A line from a move nothing follows varies that move: it repeats it, then goes on.
            if moves[cursor].children.isEmpty,let parent=moves[cursor].parent {
                let uci=moves[cursor].uci
                if let twin=moves[parent].children.dropFirst().first(where:{moves[$0].imagined && moves[$0].uci==uci}){cursor=twin}
                else{rules=try document.rules(at:parent);add(try rules.move(uci:uci ?? ""),to:parent);cursor=moves.count-1}
            }
            for uci in branch.moves {
                let record=try rules.move(uci:uci)
                if let same=moves[cursor].children.first(where:{moves[$0].uci==uci}){cursor=same}else{add(record,to:cursor);cursor=moves.count-1}
            }
        }
        var tokens:[String]=[]
        func comment(_ text:String){tokens.append("{"+String(String.UnicodeScalarView(text.unicodeScalars.map{$0=="}" ? ")":$0}))+"}")}
        func emit(_ id:Int,force:Bool){
            let move=moves[id];move.before.forEach(comment)
            if move.side=="w"{tokens.append("\(move.fullmove).")}else if force || !move.before.isEmpty{tokens.append("\(move.fullmove)...")}
            let quality=move.nags.firstIndex{(1...6).contains($0)}
            tokens.append((move.san ?? "")+(quality.map{glyphs[move.nags[$0]]!} ?? ""))
            for (offset,nag) in move.nags.enumerated() where offset != quality{tokens.append("$\(nag)")}
            move.after.forEach(comment)
        }
        func line(_ parent:Int,force start:Bool){
            var cursor=parent,force=start
            while let first=moves[cursor].children.first {
                emit(first,force:force);force = !moves[first].after.isEmpty
                for alternative in moves[cursor].children.dropFirst(){tokens.append("(");emit(alternative,force:true);line(alternative,force:!moves[alternative].after.isEmpty);tokens.append(")");force=true}
                cursor=first
            }
        }
        moves[0].before.forEach(comment);moves[0].after.forEach(comment);line(0,force:true);tokens.append(document.result)
        var text=tags(document).map{"[\($0.name) \"\(escaped($0.value))\"]"}.joined(separator:"\n")+"\n\n",column=0
        for token in tokens {
            let joined=token==")" || text.hasSuffix("(") || column==0
            if !joined && column+1+token.count>79{text+="\n";column=0}else if !joined{text+=" ";column+=1}
            text+=token;column+=token.count
        }
        return Data((text+"\n").utf8)
    }
    private static let glyphs=[1:"!",2:"?",3:"!!",4:"??",5:"!?",6:"?!"],gradeNAGs:[MoveGrade:Int]=[.inaccuracy:6,.mistake:2,.blunder:4]
    /// The Seven Tag Roster first (unknown ones as "?"), the record's other tags in their order, and the start position
    /// when it is not the usual one.
    private static func tags(_ document:GameDocument)->[PGNHeader] {
        let roster=["Event","Site","Date","Round","White","Black"] // not localized: PGN tag names
        var result=roster.map{name in PGNHeader(name,document.header(name) ?? (name=="Date" ? "????.??.??":"?"))}+[PGNHeader("Result",document.result)]
        result+=document.headers.filter{!roster.contains($0.name) && !["Result","SetUp","FEN"].contains($0.name)} // not localized: PGN tag names
        if document.startingFEN != standardStart{result+=[PGNHeader("SetUp","1"),PGNHeader("FEN",document.startingFEN)]}
        return result
    }
    private static func escaped(_ value:String)->String {
        String(String.UnicodeScalarView(value.unicodeScalars.map{CharacterSet.controlCharacters.contains($0) ? " ":$0})).replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
    }
    /// The export's file name: the review's title with the characters a file name cannot hold replaced, never hidden,
    /// at most 80 characters, else "review".
    public static func fileName(_ title:String,pgn:Bool)->String {
        let spaced=String(String.UnicodeScalarView(title.unicodeScalars.compactMap{CharacterSet.controlCharacters.contains($0) ? nil:"/\\:".unicodeScalars.contains($0) ? "-":$0}))
        let trimmed=String(spaced.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:".-"))).prefix(80)).trimmingCharacters(in:.whitespaces)
        return (trimmed.isEmpty ? "review":trimmed)+(pgn ? ".pgn":".fen")
    }
}
