import Foundation

public enum MiniGameKind:String,Codable,CaseIterable {
    case pawnDuel="pawn-duel",rookSweep="rook-sweep",rooksAndPawns="rooks-and-pawns"
    case bishopSweep="bishop-sweep",bishopsAndPawns="bishops-and-pawns",queenVsPawns="queen-vs-pawns",knightCapture="knight-capture",knightCorners="knight-corners"
    public var title:String {switch self{case .pawnDuel:return "Pawn Duel";case .rookSweep:return "Rook Sweep";case .rooksAndPawns:return "Rooks and Pawns";case .bishopSweep:return "Bishop Sweep";case .bishopsAndPawns:return "Bishops and Pawns";case .queenVsPawns:return "Queen Against Pawns";case .knightCapture:return "Knight Capture";case .knightCorners:return "Knight Corners"}}
    public var solo:Bool {self == .knightCorners}
    public var lessonID:String {switch self{case .pawnDuel:return "pawn-duel";case .rookSweep,.rooksAndPawns:return "rook-practice";case .bishopSweep,.bishopsAndPawns:return "bishop-practice";case .queenVsPawns:return "queen-practice";case .knightCapture,.knightCorners:return "knight-practice"}}
    public static func available(lessonID:String)->[Self] {allCases.filter{$0.lessonID==lessonID}}
    public var rules:String {return baseRules+(solo ? "":" "+MiniGameState.drawRules)}
    private var baseRules:String {switch self {
        case .pawnDuel:return "Reach the far rank, capture every opposing pawn, or leave the opponent without a move. Pawns stay pawns. No en passant."
        case .rookSweep,.bishopSweep:return "Only \(self == .rookSweep ? "rooks":"bishops") move. Capture every opposing pawn to win. Losing all your moving pieces or having no move loses."
        case .rooksAndPawns,.bishopsAndPawns,.queenVsPawns:return "Win by capturing all the other side’s pieces, or by getting a pawn to the last rank and keeping it there through the reply. A side with no legal move loses. A pawn on the last rank stays a pawn, and pawns never capture en passant."
        case .knightCapture:return "Only the knights move. Take the other side’s pieces; a side whose knight is gone, or cannot move, loses."
        case .knightCorners:return "Visit a8, h8 and h1, then return to a1. Avoid the black pawns and the squares they attack."
    }}
    /// Each side's half is the other's turned through 180 degrees with colours swapped, so neither side starts ahead.
    public var initialBoard:Position {
        func mirrored(_ white:Position)->Position {
            var board=white
            for (square,piece) in white {
                let file=Character(UnicodeScalar(UInt8(201)-square.utf8.first!)),rank=9-Int(square.suffix(1))!
                board[String(file)+String(rank)]="b"+piece.suffix(1)
            }
            return board
        }
        let duelPawns=Dictionary(uniqueKeysWithValues:"abcfgh".flatMap{[(String($0)+"2","wp"),(String($0)+"7","bp")]})
        switch self {
        case .pawnDuel:return Dictionary(uniqueKeysWithValues:"bcdefg".flatMap{[(String($0)+"2","wp"),(String($0)+"7","bp")]})
        case .rookSweep:return mirrored(["b1":"wr","a4":"wp","c3":"wp","d6":"wp","e2":"wp","f5":"wp","g3":"wp","h6":"wp"])
        case .rooksAndPawns:return mirrored(["d1":"wr","e1":"wr","a2":"wp","b2":"wp","c2":"wp","f2":"wp","g2":"wp","h2":"wp"])
        case .bishopSweep:return mirrored(["b2":"wb","e2":"wb","a3":"wp","c5":"wp","d4":"wp","f3":"wp","g5":"wp","h4":"wp"])
        case .bishopsAndPawns:return duelPawns.merging(["d1":"wb","e1":"wb","d8":"bb","e8":"bb"]){_,new in new}
        case .queenVsPawns:return Dictionary(uniqueKeysWithValues:"abcdefgh".map{(String($0)+"2","wp")}).merging(["e8":"bq"]){_,new in new}
        case .knightCapture:return mirrored(["b1":"wn","a3":"wp","c4":"wp","e3":"wp","g2":"wp","h4":"wp","d2":"wb","f1":"wr"])
        case .knightCorners:return ["a1":"wn","c3":"bp","f3":"bp","d6":"bp","e5":"bp","b6":"bp","g6":"bp"]
        }
    }
    public func canMove(_ piece:String)->Bool {switch self{case .rookSweep:return piece.hasSuffix("r");case .bishopSweep:return piece.hasSuffix("b");case .knightCapture,.knightCorners:return piece.hasSuffix("n");case .pawnDuel:return piece.hasSuffix("p");case .rooksAndPawns:return piece.hasSuffix("p") || piece.hasSuffix("r");case .bishopsAndPawns:return piece.hasSuffix("p") || piece.hasSuffix("b");case .queenVsPawns:return piece.hasSuffix("p") || piece.hasSuffix("q")}}
    var delayedFinish:Bool {self == .rooksAndPawns || self == .bishopsAndPawns || self == .queenVsPawns}
}
public struct MiniGameMove:Codable,Equatable {public let from:String,to:String;public init(from:String,to:String){self.from=from;self.to=to}}
public struct MiniGameSnapshot:Codable,Equatable {
    public var board:Position,turn:String,pendingFinish:String?,cornerIndex:Int,lastMove:MiniGameMove?
}
public struct MiniGameState:Codable,Equatable {
    public static let maximumHistory=256
    public static let repetitionCount=3,noProgressPlies=80
    public static let drawRules="Three repeated positions or 40 turns without a capture or pawn move draw this mini-game."
    public var kind:MiniGameKind,computer:Bool,snapshot:MiniGameSnapshot,history:[MiniGameSnapshot]=[]
    public var opponentSeed:String?
    /// The opponent level this run plays at (plan D4); absent from older saves and from solo games. Read it through
    /// `runLevel`, which ignores a level of another run.
    public var level:MiniGameLevel?
    public init(kind:MiniGameKind,computer:Bool=true){self.kind=kind;self.computer=computer && !kind.solo;opponentSeed=String(UInt64.random(in:UInt64.min...UInt64.max),radix:16);snapshot=MiniGameSnapshot(board:kind.initialBoard,turn:"w",pendingFinish:nil,cornerIndex:0,lastMove:nil)}
    private enum CodingKeys:String,CodingKey {case kind,computer,snapshot,history,opponentSeed,level}
    /// As the synthesized decoder, except that a level this build cannot use (damaged, or of a shape a newer build
    /// wrote) reads as none: the run is then unverified, never the whole saved state unreadable.
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        kind=try c.decode(MiniGameKind.self,forKey:.kind);computer=try c.decode(Bool.self,forKey:.computer);snapshot=try c.decode(MiniGameSnapshot.self,forKey:.snapshot);history=try c.decode([MiniGameSnapshot].self,forKey:.history)
        opponentSeed=try c.decodeIfPresent(String.self,forKey:.opponentSeed);level=(try? c.decodeIfPresent(MiniGameLevel.self,forKey:.level)).flatMap{$0}.flatMap{$0.valid ? $0:nil}
    }
    public var board:Position {snapshot.board}
    public var turn:String {snapshot.turn}
    /// The run's identity, shared by its level and its completion event: a restart makes a new one. Saves from before
    /// seeds form one run until the game restarts.
    public var run:String {opponentSeed ?? "unseeded"}
    /// A stable digest of the board and how many positions precede it: 64-bit FNV-1a, as 16 hex digits.
    public var witness:String {
        let move=snapshot.lastMove.map{$0.from+$0.to} ?? "-",text="mini-witness-v1|"+board.keys.sorted().map{$0+"="+board[$0]!}.joined(separator:",")+"|\(turn)|\(snapshot.pendingFinish ?? "-")|\(snapshot.cornerIndex)|\(move)|\(history.count)"
        var hash:UInt64=0xcbf29ce484222325;for byte in text.utf8{hash=(hash ^ UInt64(byte)) &* 0x100000001b3}
        return String(format:"%016llx",hash)
    }
    /// The stored level when it belongs to this run; nil when there is none, or it names another run (an older build
    /// restarted the game and wrote the unknown field back).
    public var runLevel:MiniGameLevel? {level.flatMap{$0.run==run ? $0:nil}}
    /// Settles the run's level as the game is opened, before its first save here. The run's own level is kept, marked
    /// not exact if the board moved since this build last saved it (an older build continued the run). Without one,
    /// the run takes `profile` from now on, exact only if no move has been played: earlier moves had an unknown level.
    /// A solo game has no opponent and no level.
    public mutating func settleLevel(adopting profile:String) {
        guard !kind.solo else{level=nil;return}
        if var own=runLevel {if own.witness != witness{own.exact=false};own.witness=witness;level=own}
        else {level=MiniGameLevel(profile:profile,run:run,witness:witness,exact:history.isEmpty)}
    }
    /// Records the board in the run's level, as every save by this build does.
    public mutating func stampWitness(){if runLevel != nil{let current=witness;level?.witness=current}}
    public var winner:String? {
        if kind.solo{return snapshot.cornerIndex==MiniGameRules.corners.count ? "w":nil}
        for side in ["w","b"] {
            let far=side=="w" ? "8":"1",atEnd=board.contains{$0.value==side+"p" && $0.key.hasSuffix(far)}
            if atEnd && (kind == .pawnDuel || kind.delayedFinish && turn==side){return side}
            let other=side=="w" ? "b":"w"
            let targets=board.values.filter{$0.hasPrefix(other) && (!(kind == .rookSweep || kind == .bishopSweep) || $0.hasSuffix("p"))}
            if targets.isEmpty{return side}
        }
        return MiniGameRules.moves(board:board,kind:kind,side:turn).isEmpty ? (turn=="w" ? "b":"w"):nil
    }
    /// Mini-game variant rules: three identical positions, or 80 plies without a capture/pawn move, draw.
    /// Derived from snapshots so old saves and undo need no new counters.
    public var drawReason:String? {guard !kind.solo,winner==nil else{return nil};return drawReasonWithoutWinner}
    /// `drawReason` for a competitive position already known to have no winner (the proof search asks `winner` once).
    var drawReasonWithoutWinner:String? {
        if kind == .bishopSweep {
            func colour(_ square:String)->Int {(Int(square.utf8.first!)-97+Int(square.suffix(1))!-1)%2}
            let bishops=board.filter{$0.value.hasSuffix("b")}
            let anyReachable=bishops.contains{from,piece in board.contains{to,target in target.first != piece.first && colour(from)==colour(to)}}
            if !anyReachable{return "No remaining targets can be reached."}
        }
        func same(_ a:MiniGameSnapshot,_ b:MiniGameSnapshot)->Bool {a.board==b.board && a.turn==b.turn && a.pendingFinish==b.pendingFinish}
        if history.filter({same($0,snapshot)}).count>=Self.repetitionCount-1{return "The same position appeared three times."}
        if history.count>=Self.noProgressPlies {
            let recent=history.suffix(Self.noProgressPlies)
            let pawns=board.filter{$0.value.hasSuffix("p")}
            if recent.allSatisfy({$0.board.count==board.count && $0.board.filter{$0.value.hasSuffix("p")}==pawns}) {return "No capture or pawn move for 40 turns."}
        }
        return nil
    }
    public var isFinished:Bool {winner != nil || drawReason != nil}
    public func destinations(from:String)->[String] {guard !isFinished,board[from]?.hasPrefix(turn)==true else{return []};return MiniGameRules.moves(board:board,kind:kind,side:turn).filter{$0.from==from}.map(\.to)}
    @discardableResult public mutating func play(_ move:MiniGameMove,remember:Bool=true)->Bool {
        guard destinations(from:move.from).contains(move.to),board[move.from] != nil else{return false}
        advance(move,remember:remember);return true
    }
    /// Applies a move `destinations` allows here, unchecked: `play` checks it first, and the proof search plays only
    /// moves it has just generated for an unfinished position.
    mutating func advance(_ move:MiniGameMove,remember:Bool){
        let piece=board[move.from]!
        if remember{history.append(snapshot);if history.count>Self.maximumHistory{history.removeFirst()}}
        snapshot.board.removeValue(forKey:move.from);snapshot.board[move.to]=piece;snapshot.lastMove=move
        if kind.solo {if snapshot.cornerIndex<MiniGameRules.corners.count,move.to==MiniGameRules.corners[snapshot.cornerIndex]{snapshot.cornerIndex+=1}}
        else {
            if let pending=snapshot.pendingFinish,!board.contains(where:{$0.value==pending+"p" && $0.key.hasSuffix(pending=="w" ? "8":"1")}){snapshot.pendingFinish=nil}
            if kind.delayedFinish,piece.hasSuffix("p"),move.to.hasSuffix(turn=="w" ? "8":"1"){snapshot.pendingFinish=turn}
            snapshot.turn=turn=="w" ? "b":"w"
        }
    }
    public mutating func undo(){guard let previous=history.popLast() else{return};snapshot=previous;if computer,snapshot.turn=="b",let whiteTurn=history.popLast(){snapshot=whiteTurn}}
}
public enum MiniGameRules {
    /// The referee's rules version (`MiniGameState.winner`, `drawReason`, `play` and `moves`). Bump it whenever any of
    /// them changes, so a proof computed under the old rules is never taken for one under the new.
    public static let version=1
    public static let corners=["a8","h8","h1","a1"]
    private static let straight=[(1,0),(-1,0),(0,1),(0,-1)],diagonal=[(1,1),(1,-1),(-1,1),(-1,-1)]
    private static let jumps=[(1,2),(2,1),(-1,2),(-2,1),(1,-2),(2,-1),(-1,-2),(-2,-1)]
    public static func moves(board:Position,kind:MiniGameKind,side:String)->[MiniGameMove] {
        var result:[MiniGameMove]=[]
        for from in board.keys.sorted() {
            guard let piece=board[from],piece.hasPrefix(side),kind.canMove(piece),ChessNotation.validSquare(from) else{continue}
            if piece.hasSuffix("p"){result += CourseLibrary.pawnMoves(board,from:from).map{MiniGameMove(from:from,to:$0)};continue}
            let file=Int(from.utf8.first!-97),rank=Int(from.suffix(1))!-1
            let knight=piece.hasSuffix("n"),directions=knight ? jumps:piece.hasSuffix("b") ? diagonal:piece.hasSuffix("r") ? straight:straight+diagonal
            for (dx,dy) in directions {
                var x=file+dx,y=rank+dy
                while (0..<8).contains(x),(0..<8).contains(y) {
                    let to=String(UnicodeScalar(97+x)!)+String(y+1),occupant=board[to]
                    if occupant?.hasPrefix(side)==true{break}
                    let safe = !kind.solo || occupant==nil && !board.contains{entry in entry.value=="bp" && abs(Int(entry.key.utf8.first!-97)-x)==1 && Int(entry.key.suffix(1))!-2==y}
                    if safe{result.append(MiniGameMove(from:from,to:to))}
                    if occupant != nil || knight{break};x+=dx;y+=dy
                }
            }
        }
        return result
    }
}
/// The opponent level one run of a mini-game plays at, frozen when the run starts (plan D4). `run` is the state's
/// `run`, so a level an older build carried through a restart names another run and is ignored. `witness` is the
/// state's `witness` at this build's last save: an older build that continued the run moved the board without
/// rewriting it, and the run is then marked not exact for good. The run keeps playing at its level either way.
public struct MiniGameLevel:Codable,Equatable {
    public var profile:String,run:String,witness:String,exact:Bool
    public init(profile:String,run:String,witness:String,exact:Bool=true){self.profile=profile;self.run=run;self.witness=witness;self.exact=exact}
    var valid:Bool {MiniOpponentPolicy.profiles.contains(profile) && (1...64).contains(run.count) && witness.count<=64}
    /// The completion event's name for the policy this level searched with.
    public func policy(_ kind:MiniGameKind)->String {"mini-search-v\(MiniOpponentPolicy.forGame(kind,profile:profile).version)"}
}
public struct MiniOpponentPolicy:Codable,Equatable {
    public let version:Int,maximumDepth:Int,nodeBudget:Int,milliseconds:Int
    /// Every profile the search knows, weakest first. Which of them a game offers is `MiniGameOffering`'s decision.
    public static let profiles=["beginner","standard","challenging"]
    public static func forGame(_ kind:MiniGameKind,profile:String)->Self {
        let complex = kind == .pawnDuel || kind == .rooksAndPawns || kind == .bishopsAndPawns
        let depth = profile == "beginner" ? 1 : profile == "challenging" ? (complex ? 5:4) : (complex ? 4:3)
        let nodes = profile == "beginner" ? 400 : profile == "challenging" ? (complex ? 12000:7000) : (complex ? 7000:3500)
        return Self(version:2,maximumDepth:depth,nodeBudget:nodes,milliseconds:650)
    }
}
public enum MiniGameOpponent {
    // Bounded search is independent of kings, check and standard-chess promotion.
    public static let replyDelay:Duration = .milliseconds(400),nodeBudget=8_000,maximumDepth=4
    private static let win=100_000,limit=1_000_000
    /// The node budget makes a choice deterministic for a seed; the time limit only guards responsiveness on a slow or
    /// loaded machine, where it can stop the search earlier and so choose differently. Pass `timeLimited:false` to
    /// examine the search itself.
    public static func choose(in state:MiniGameState,profile:String="standard",seed:UInt64=1,timeLimited:Bool=true)->MiniGameMove? {decide(in:state,profile:profile,seed:seed,timeLimited:timeLimited).move}
    /// One search's choice and what bounded it. `deadlineCut` says the time limit stopped the search before its node
    /// budget did, the case in which a loaded machine can choose differently from the reproducible search; calibration
    /// (WI-016) counts it. The choice is exactly `choose`'s.
    public struct Decision:Equatable {public let move:MiniGameMove?,nodes:Int,completedDepth:Int,deadlineCut:Bool}
    public static func decide(in state:MiniGameState,profile:String="standard",seed:UInt64=1,timeLimited:Bool=true)->Decision {
        let policy=MiniOpponentPolicy.forGame(state.kind,profile:profile),maximumDepth=policy.maximumDepth,nodeBudget=policy.nodeBudget
        let deadline=timeLimited ? Date().addingTimeInterval(Double(policy.milliseconds)/1000):Date.distantFuture
        var random=seed,deadlineCut=false,completedDepth=0
        func pick(_ moves:[MiniGameMove])->MiniGameMove {random=random &* 6364136223846793005 &+ 1442695040888963407;return moves[Int((random >> 32) % UInt64(moves.count))]}
        func exhausted()->Bool {
            if nodes>=nodeBudget || Task.isCancelled{return true}
            if Date()>=deadline{deadlineCut=true;return true};return false
        }
        guard !state.kind.solo,!state.isFinished else{return Decision(move:nil,nodes:0,completedDepth:0,deadlineCut:false)}
        let legal=ordered(state);guard var best=legal.first else{return Decision(move:nil,nodes:0,completedDepth:0,deadlineCut:false)}
        var nodes=0
        func evaluate(_ s:MiniGameState)->Int {
            var score=0
            for (square,piece) in s.board {
                let side=piece.hasPrefix("w") ? 1:-1,type=String(piece.suffix(1)),rank=Int(square.suffix(1))!
                let value=["p":100,"n":350,"b":330,"r":500,"q":900][type,default:0]
                score+=side*(value+(type=="p" ? (side==1 ? rank-2:7-rank)*18:0))
            }
            return score
        }
        func search(_ s:MiniGameState,_ depth:Int,_ alpha:Int,_ beta:Int)->Int {
            nodes+=1
            if let winner=s.winner{return (winner=="w" ? 1:-1)*(win+depth)}
            if s.drawReason != nil{return 0}
            if depth==0 || exhausted(){return evaluate(s)}
            var a=alpha,b=beta,value=s.turn=="w" ? -limit:limit
            for move in ordered(s) {
                var child=s;_ = child.play(move,remember:false)
                let score=search(child,depth-1,a,b)
                if s.turn=="w"{value=max(value,score);a=max(a,value)}else{value=min(value,score);b=min(b,value)}
                if a>=b || exhausted(){break}
            }
            return value
        }
        for depth in 1...maximumDepth {
            var candidates:[MiniGameMove]=[],value=state.turn=="w" ? -limit:limit,complete=true
            for move in legal {
                if exhausted(){complete=false;break}
                var child=state;_ = child.play(move,remember:false)
                let score=search(child,depth-1,-limit,limit)
                if state.turn=="w" ? score>value:score<value{candidates=[move];value=score}else if score==value{candidates.append(move)}
                if exhausted(){complete=false;break}
            }
            if complete,!candidates.isEmpty{best=pick(candidates);completedDepth=depth}else{break}
        }
        return Decision(move:Task.isCancelled ? nil:best,nodes:nodes,completedDepth:completedDepth,deadlineCut:deadlineCut)
    }
    private static func ordered(_ state:MiniGameState)->[MiniGameMove] {MiniGameRules.moves(board:state.board,kind:state.kind,side:state.turn).sorted{a,b in
        func priority(_ m:MiniGameMove)->Int {(state.board[m.to] != nil ? 10:0)+(m.to.hasSuffix(state.turn=="w" ? "8":"1") ? 5:0)}
        return priority(a)==priority(b) ? a.from+a.to<b.from+b.to:priority(a)>priority(b)
    }}
}
