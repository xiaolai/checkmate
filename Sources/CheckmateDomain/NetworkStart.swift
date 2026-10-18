import Foundation
/// What a peer says it can do (mini-games plan D7, `docs/network-protocol-1.2.md`): stated in every `hello` and
/// `resume`, and checked by the host before it admits the connection. At most 8 tokens of 1 to 32 printable ASCII bytes,
/// none twice; anything else is malformed, in both directions. Tokens a host does not know are ignored.
public struct NetworkCapabilities:Hashable,CustomStringConvertible {
    public static let maximumTokens=8,maximumTokenBytes=32
    /// Sorted, as written on the wire.
    public let tokens:[String]
    public init?(_ tokens:[String]){
        guard tokens.count<=Self.maximumTokens,Set(tokens).count==tokens.count,tokens.allSatisfy(Self.valid) else{return nil}
        self.tokens=tokens.sorted()
    }
    public static let none=NetworkCapabilities([])!
    /// What this build states: it replays a record from a declared start and pins it (L1), and it plays and verifies
    /// each mini-game ruleset (L2, protocol 1.3). Eight tokens, 1.2's bound: one more fails here, at launch and in tests,
    /// rather than truncating what is stated (`docs/network-protocol-1.3.md`, the capability budget).
    public static let supported=NetworkCapabilities([NetworkStart.capability]+NetworkRuleset.supported.map(\.capability))!
    public func contains(_ token:String)->Bool {tokens.contains(token)}
    public func isSubset(of other:NetworkCapabilities)->Bool {tokens.allSatisfy(other.contains)}
    public var description:String {tokens.joined(separator:",")}
    static func valid(_ token:String)->Bool {(1...maximumTokenBytes).contains(token.utf8.count) && token.utf8.allSatisfy{(0x21...0x7E).contains($0)}}
}
/// A network game's start (D7, L1): the standard start, or a position the host declared. The domain reads only the
/// fields it needs (side to move, full-move number) and the structure chess.js does not check; the rules decide the
/// rest (`NetworkChessRules.networkLoad(start:)`).
public enum NetworkStart {
    /// The FEN chess.js writes for the initial position. Never written as a `startFEN`: its absence means it.
    public static let standard="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    /// The capability a game with a declared start requires of every guest and spectator.
    public static let capability="start"
    public static let maximumBytes=128,maximumFullmove=9999
    /// Six fields separated by single spaces, printable ASCII, eight ranks of eight squares, the side to move `w` or `b`,
    /// and a full-move number of 1 to 9999: the shape a `startFEN` must have before any rules read it.
    public static func wellFormed(_ fen:String)->Bool {
        guard (1...maximumBytes).contains(fen.utf8.count),fen.utf8.allSatisfy({(0x21...0x7E).contains($0) || $0==0x20}) else{return false}
        let fields=fen.split(separator:" ",omittingEmptySubsequences:false)
        guard fields.count==6,fields.allSatisfy({!$0.isEmpty}),placement(String(fields[0])) != nil,["w","b"].contains(fields[1]),fields[5].allSatisfy(\.isNumber),fields[5].count<=4,let move=Int(fields[5]),(1...maximumFullmove).contains(move) else{return false}
        return true
    }
    /// The side that makes ply 1 from this start.
    public static func side(_ fen:String)->NetworkSide {fen.split(separator:" ").dropFirst().first=="b" ? .black:.white}
    /// The full-move number of ply 1.
    public static func fullmove(_ fen:String)->Int {fen.split(separator:" ").last.flatMap{Int($0)} ?? 1}
    /// The checks chess.js does not make (D7, hosting refuses): every castling right has its king and rook on their home
    /// squares, and an en passant square has the pawn that just passed it beyond it, with the square and the one behind
    /// it empty. A position failing them cannot have arisen in a game.
    public static func consistent(_ fen:String)->Bool {
        let fields=fen.split(separator:" ",omittingEmptySubsequences:false).map(String.init)
        guard fields.count==6,let board=placement(fields[0]) else{return false}
        let rights:[(Character,String,String,Character)]=[("K","e1","h1","K"),("Q","e1","a1","K"),("k","e8","h8","k"),("q","e8","a8","k")]
        for (right,king,rook,kingPiece) in rights where fields[2].contains(right) {
            guard board[king]==kingPiece,board[rook]==(kingPiece=="K" ? "R":"r") else{return false}
        }
        if fields[3] != "-" {
            let square=Array(fields[3])
            guard square.count==2,let file=square.first,"abcdefgh".contains(file) else{return false}
            // White to move: Black's pawn has just passed the sixth rank to the fifth; Black to move, the mirror.
            let (passed,beyond,behind,pawn):(Character,Character,Character,Character)=fields[1]=="w" ? ("6","5","7","p"):("3","4","2","P")
            guard square[1]==passed,board["\(file)\(beyond)"]==pawn,board["\(file)\(passed)"]==nil,board["\(file)\(behind)"]==nil else{return false}
        }
        return true
    }
    /// The pieces by square, or nil when the placement field is not eight ranks of eight squares.
    static func placement(_ field:String)->[String:Character]? {
        let ranks=field.split(separator:"/",omittingEmptySubsequences:false)
        guard ranks.count==8 else{return nil}
        var board:[String:Character]=[:]
        for (index,rank) in ranks.enumerated() {
            var file=0
            for symbol in rank {
                if let empty=symbol.wholeNumberValue {file+=empty}
                else{guard "KQRBNPkqrbnp".contains(symbol),file<8 else{return nil};board["\(Array("abcdefgh")[file])\(8-index)"]=symbol;file+=1}
                guard file<=8 else{return nil}
            }
            guard file==8 else{return nil}
        }
        return board
    }
}
