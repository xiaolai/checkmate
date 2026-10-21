import Foundation
/// A move the learner types (B-23), in SAN ("Nf3", "exd5", "O-O", "a8=Q") or as squares ("g1f3", "g1-f3", "a7a8q"),
/// resolved against the moves a position offers. Every refusal says why in words a beginner can act on.
public enum TypedMove {
    /// What the text names before any position is consulted. A lowercase "b" before a square may be a pawn's file or a
    /// bishop, so one text can have two readings.
    enum Reading:Equatable {
        case squares(from:String,to:String,promotion:String?)
        case piece(String,file:Character?,rank:Character?,to:String,promotion:String?)
        case castle(kingside:Bool)
    }
    public struct Choice:Equatable {public let from:String,to:String,promotion:String?;public init(from:String,to:String,promotion:String?){self.from=from;self.to=to;self.promotion=promotion}}
    public enum Resolution:Equatable {case move(Choice),refused(String)}
    static let names=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    static func side(_ color:String)->String {color=="w" ? "White":"Black"}
    /// "Two", "Three": a count of pieces at the start of a sentence, in US English whatever the system language.
    static func spelled(_ n:Int)->String {
        let formatter=NumberFormatter();formatter.numberStyle = .spellOut;formatter.locale=Locale(identifier:"en_US_POSIX")
        return (formatter.string(from:NSNumber(value:n)) ?? String(n)).capitalized
    }

    static func readings(_ text:String)->[Reading] {
        var s=text.trimmingCharacters(in:.whitespaces)
        while let last=s.last,"+#!?".contains(last){s.removeLast()}
        for suffix in ["e.p.","ep"] where s.lowercased().hasSuffix(suffix) && s.count>suffix.count+1 {s=String(s.dropLast(suffix.count))}
        s=s.filter{!" x:X-=".contains($0)}
        let castle=s.uppercased().replacingOccurrences(of:"0",with:"O")
        if castle=="OO"{return [.castle(kingside:true)]};if castle=="OOO"{return [.castle(kingside:false)]}
        let c=Array(s)
        func square(_ i:Int)->String? {guard i>=0,i+1<c.count else{return nil};let text=String(c[i...i+1]);return ChessNotation.validSquare(text) ? text:nil}
        if (c.count==4 || c.count==5),let from=square(0),let to=square(2) {
            if c.count==4{return [.squares(from:from,to:to,promotion:nil)]}
            if "qrbnQRBN".contains(c[4]){return [.squares(from:from,to:to,promotion:c[4].lowercased())]}
        }
        var core=c,promotion:String?=nil
        if core.count>=3,"QRBNqrbn".contains(core.last!),ChessNotation.validSquare(String(core[core.count-3...core.count-2])){promotion=core.removeLast().lowercased()}
        guard core.count>=2,let to=Optional(String(core.suffix(2))),ChessNotation.validSquare(to) else{return []}
        let prefix=Array(core.dropLast(2))
        func piece(_ letter:String,_ rest:ArraySlice<Character>)->Reading? {
            var rest=rest,file:Character?=nil,rank:Character?=nil
            if let f=rest.first,"abcdefgh".contains(f){file=f;rest=rest.dropFirst()}
            if let r=rest.first,"12345678".contains(r){rank=r;rest=rest.dropFirst()}
            guard rest.isEmpty,letter=="p" || promotion==nil,letter != "p" || rank==nil else{return nil}
            return .piece(letter,file:file,rank:rank,to:to,promotion:promotion)
        }
        guard let first=prefix.first else{return [piece("p",[])].compactMap{$0}}
        if "KQRBNP".contains(first){return [piece(first.lowercased(),prefix.dropFirst())].compactMap{$0}}
        if "kqrn".contains(first){return [piece(String(first),prefix.dropFirst())].compactMap{$0}}
        if first=="b"{return [piece("p",prefix[...]),piece("b",prefix.dropFirst())].compactMap{$0}}
        return [piece("p",prefix[...])].compactMap{$0}
    }

    /// Resolves `text` against `moves`, the moves of the side to move. With `squaresAsTyped`, a move typed as squares is
    /// passed on unchecked, for an exercise that grades raw attempts itself.
    public static func resolve(_ text:String,moves:[MoveRecord],board:Position,turn:String,inCheck:Bool,squaresAsTyped:Bool=false)->Resolution {
        let trimmed=text.trimmingCharacters(in:.whitespaces)
        guard !trimmed.isEmpty else{return .refused("Type a move, such as e4 or Nf3.")}
        let readings=readings(trimmed)
        guard !readings.isEmpty else{return .refused("“\(trimmed)” is not a move. Type a move such as e4, Nf3, O-O or e2e4.")}
        var first:Resolution?
        for reading in readings {
            let result=resolve(reading,moves:moves,board:board,turn:turn,inCheck:inCheck,squaresAsTyped:squaresAsTyped)
            if case .move=result{return result};if first==nil{first=result}
        }
        return first!
    }
    private static func resolve(_ reading:Reading,moves:[MoveRecord],board:Position,turn:String,inCheck:Bool,squaresAsTyped:Bool)->Resolution {
        switch reading {
        case .squares(let from,let to,let promotion):
            if squaresAsTyped{return .move(Choice(from:from,to:to,promotion:promotion))}
            guard let piece=board[from] else{return .refused("There's no piece on \(from).")}
            guard piece.hasPrefix(turn) else{return .refused("The \(names[String(piece.suffix(1))] ?? "piece") on \(from) is \(side(String(piece.prefix(1))))'s, and it's \(side(turn))'s move.")}
            return choose(moves.filter{$0.from==from && $0.to==to},promotion:promotion,example:from+to+"q",board:board,turn:turn,inCheck:inCheck){refusal(piece:piece,from:from,to:to,board:board,enPassant:nil,inCheck:inCheck)}
        case .castle(let kingside):
            let matches=moves.filter{$0.piece=="k" && $0.flags.contains(kingside ? "k":"q")}
            if let move=matches.first{return .move(Choice(from:move.from,to:move.to,promotion:nil))}
            return .refused(inCheck ? "You cannot castle while your king is in check.":"Castling \(kingside ? "kingside":"queenside") is not allowed here.")
        case .piece(let kind,let file,let rank,let to,let promotion):
            let fits={(from:String)->Bool in (file.map{from.first==$0} ?? (kind != "p" || from.first==to.first)) && (rank.map{from.last==$0} ?? true)}
            let matches=moves.filter{$0.piece==kind && $0.to==to && fits($0.from)}
            let name=names[kind] ?? "piece"
            if Set(matches.map(\.from)).count>1 {
                let froms=Array(Set(matches.map(\.from))).sorted(),letter=kind=="p" ? "":kind.uppercased()
                let byFile=Set(froms.map(\.first)).count==froms.count,byRank=Set(froms.map(\.last)).count==froms.count
                let examples=froms.map{letter+(byFile ? String($0.first!):byRank ? String($0.last!):$0)+to}
                let count=spelled(froms.count)
                return .refused("\(count) \(name)s can move to \(to). Type which one, such as "+(examples.count==2 ? examples.joined(separator:" or "):examples.dropLast().joined(separator:", ")+" or "+examples.last!)+".")
            }
            return choose(matches,promotion:promotion,example:to+"=Q",board:board,turn:turn,inCheck:inCheck){
                let own=board.filter{$0.value==turn+kind && fits($0.key)}.keys.sorted()
                if own.isEmpty{return "You have no \(name)\(file != nil || rank != nil ? " there":"")."}
                let reaching=own.filter{follows(from:$0,to:to,board:board,enPassant:nil)}
                if own.count==1 || reaching.count==1{return refusal(piece:turn+kind,from:reaching.first ?? own[0],to:to,board:board,enPassant:nil,inCheck:inCheck)}
                return "No \(name) of yours can move to \(to)."
            }
        }
    }
    /// One move from `matches` (all from one square to one square), with the promotion piece settled.
    private static func choose(_ matches:[MoveRecord],promotion:String?,example:String,board:Position,turn:String,inCheck:Bool,otherwise:()->String)->Resolution {
        guard let any=matches.first else{return .refused(otherwise())}
        let promotes=matches.contains{$0.promotion != nil}
        if promotes,promotion==nil{return .refused("Add the piece to promote to, such as \(example).")}
        if !promotes,promotion != nil{return .refused("Only a pawn reaching the last rank promotes.")}
        guard let move=promotes ? matches.first(where:{$0.promotion==promotion}):any else{return .refused("A pawn can promote only to a queen, rook, bishop or knight.")}
        return .move(Choice(from:move.from,to:move.to,promotion:move.promotion))
    }

    /// Whether a piece's own way of moving takes it from one square to the other on this board, ignoring check.
    static func follows(from:String,to:String,board:Position,enPassant:String?)->Bool {
        guard let piece=board[from],let (fx,fy)=TrainingGeometry.coordinates(from),let (tx,ty)=TrainingGeometry.coordinates(to) else{return false}
        if piece.last=="p" {
            let forward=piece.first=="w" ? 1:-1,home=piece.first=="w" ? 1:6
            let push=tx==fx && board[to]==nil && (ty==fy+forward || fy==home && ty==fy+2*forward && TrainingGeometry.square(fx,fy+forward).map{board[$0]==nil}==true)
            let capture=abs(tx-fx)==1 && ty==fy+forward && (board[to] != nil || enPassant==to)
            return push || capture
        }
        return TrainingGeometry.attacks(from:from,board:board).contains(to)
    }
    /// Why a move that is not among the position's moves is refused. Shared with the training exercises' grading.
    public static func refusal(piece:String,from:String,to:String,board:Position,enPassant:String?,inCheck:Bool)->String {
        let name=names[String(piece.suffix(1))] ?? "piece",turn=String(piece.prefix(1))
        guard let (fx,fy)=TrainingGeometry.coordinates(from),let (tx,ty)=TrainingGeometry.coordinates(to) else{return "That move is not possible."}
        if board[to]?.hasPrefix(turn)==true{return "That square holds your own piece."}
        if piece.last=="k",fy==ty,abs(fx-tx)==2{return inCheck ? "You cannot castle while your king is in check.":"Castling is not allowed here."}
        guard follows(from:from,to:to,board:board,enPassant:enPassant) else{return "A \(name) cannot move from \(from) to \(to)."}
        // A board without the mover's king plays its own rules (a mini-game): nothing about check applies.
        guard board.values.contains(turn+"k") else{return "That move is not allowed here."}
        if piece.last=="k"{return "Your king would be attacked on \(to)."}
        return inCheck ? "That move does not get your king out of check.":"That move would leave your king in check."
    }
    /// The moves the side's pieces can make by their own way of moving, ignoring check: what SAN is read against in an
    /// exercise that grades raw attempts and must not reveal its legal moves. Castling is offered where king and rook
    /// stand on their home squares with nothing between them.
    public static func reachable(board:Position,turn:String,enPassant:String?)->[MoveRecord] {
        var moves:[MoveRecord]=[]
        func add(_ from:String,_ to:String,_ piece:String,_ flags:String="n",_ promotion:String?=nil){moves.append(MoveRecord(color:turn,from:from,to:to,piece:piece,flags:flags,san:"",before:"",after:"",captured:board[to].map{String($0.suffix(1))},promotion:promotion))}
        for (from,piece) in board where piece.hasPrefix(turn) && piece.count==2 {
            let kind=String(piece.suffix(1))
            for to in ChessNotation.squares where board[to]?.hasPrefix(turn) != true && follows(from:from,to:to,board:board,enPassant:enPassant) {
                if kind=="p",to.last==(turn=="w" ? "8":"1"){for promotion in ["q","r","b","n"]{add(from,to,kind,"p",promotion)}}else{add(from,to,kind)}
            }
        }
        let rank=turn=="w" ? "1":"8"
        if board["e"+rank]==turn+"k" {
            if board["h"+rank]==turn+"r",["f","g"].allSatisfy({board[$0+rank]==nil}){add("e"+rank,"g"+rank,"k","k")}
            if board["a"+rank]==turn+"r",["b","c","d"].allSatisfy({board[$0+rank]==nil}){add("e"+rank,"c"+rank,"k","q")}
        }
        return moves
    }
}
