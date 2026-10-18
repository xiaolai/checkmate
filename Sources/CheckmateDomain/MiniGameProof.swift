import Foundation

/// The proof search's limits (plan D5), fixed by WI-018's spike on the test host. Per root position: at most `plies`
/// plies and `nodesPerRoot` nodes. Per review: at most `reviewCPUSeconds` of CPU; a stop is noticed within
/// `cancellationMilliseconds`; the cache is emptied between roots once it holds more than `cacheEntries` positions.
public enum MiniGameProofBudget {
    public static let plies=9,nodesPerRoot=200_000,reviewCPUSeconds=3.0,cancellationMilliseconds=100,cacheEntries=500_000
    /// The search asks its caller's stop condition once per this many nodes (well under a millisecond of work).
    static let stopInterval=64
}
/// A root's result from the side to move's point of view. `win`/`loss` are forced against every defence, at that
/// distance in plies to the referee's verdict under best play; `draw` is forced. Anything not proved is `unknown`.
public enum MiniGameProofResult:Equatable {case win(plies:Int),loss(plies:Int),draw,unknown}
public struct MiniGameProofAnswer:Equatable {
    public let result:MiniGameProofResult
    /// Neither side can force a win within this many plies of the root. An `unknown` answer says how far its search got.
    public let clearPlies:Int
    /// For `win` and `loss`: one line of best play to the verdict, the winner's fastest and the loser's longest.
    public let line:[MiniGameMove]?
    public let nodes:Int
    /// The node budget or the caller's stop ended the search; the answer is then `unknown`.
    public let exhausted:Bool
}
/// History-aware proof search for the simplified mini-games' post-game review, separate from `MiniGameOpponent`
/// (plan D5, rule 9). It plays only through the referee (`MiniGameState.advance`, `winner`, `drawReason`), with the
/// positions back to the last capture or pawn move, so repetition and the 80-ply rule are judged as in the game.
///
/// One value is one review's cache: one kind at one rules version, never shared. Entries are keyed by the board, turn,
/// pending finish and the positions since the last irreversible move (whose count is the no-progress count); a board
/// alone is never a key. Every entry records facts about the game itself, qualified by depth: a win or loss in d plies
/// answers any query of at least d plies, a draw proved with r plies left answers queries of at least r, and a
/// position found not to resolve within r plies answers only queries of at most r. So a cached answer is always the
/// answer an uncached search would give.
///
/// Exactness: a position's result at horizon r is exact only when every branch within r resolved. Wins and losses are
/// threshold searches (a forced win within t plies, iteratively deepened from 1, so the first success is the true
/// distance); a forced result within the horizon is always found exactly. A draw needs every move to resolve within the
/// remaining plies, each to a draw or a loss for the mover, with at least one draw.
public struct MiniGameProof {
    public let kind:MiniGameKind,rulesVersion:Int
    /// Nodes searched across this review: every position reached by a move the search examined.
    public private(set) var nodes=0
    public var entryCount:Int {entries.count}
    /// `MiniGameProofBudget.cacheEntries`; tests lower it to show that emptying the cache changes no answer.
    var cacheLimit=MiniGameProofBudget.cacheEntries
    public init(kind:MiniGameKind){precondition(!kind.solo,"Knight Corners has no opponent to prove anything against");self.kind=kind;rulesVersion=MiniGameRules.version}

    /// A position as the referee compares them (board, turn, pending finish), packed four bits a square.
    private struct Spot:Hashable {
        let a:UInt64,b:UInt64,c:UInt64,d:UInt64,flags:UInt8
        /// Nil for a square or piece no mini-game has.
        init?(_ snapshot:MiniGameSnapshot){
            var words:[UInt64]=[0,0,0,0]
            for (square,piece) in snapshot.board {
                guard ChessNotation.validSquare(square),piece.count==2,let colour=piece.first,colour=="w" || colour=="b",let type=Self.types.firstIndex(of:piece.last!) else{return nil}
                let index=Int(square.utf8.first!-97)*8+Int(square.utf8.last!-49)
                words[index/16] |= UInt64(type+1+(colour=="b" ? 8:0))<<UInt64(4*(index%16))
            }
            a=words[0];b=words[1];c=words[2];d=words[3];flags=(snapshot.turn=="w" ? 0:1)+(snapshot.pendingFinish=="w" ? 2:snapshot.pendingFinish=="b" ? 4:0)
        }
        static let types:[Character]=["p","r","b","n","q"]
    }
    private enum Outcome:UInt8 {case unseen,open,won,lost,drawn}
    /// Facts about one position-with-context, in plies. `noWin`/`noLoss`/`notDrawn`: proved not to happen within that
    /// many; `winBy`/`lossBy`/`drawnBy`: proved within that many (`never` until then).
    private struct Entry {var outcome=Outcome.unseen,noWin:Int8=0,winBy=MiniGameProof.never,noLoss:Int8=0,lossBy=MiniGameProof.never,notDrawn:Int8=0,drawnBy=MiniGameProof.never}
    private static let never=Int8.max
    /// A trail is a position with the positions since the last irreversible move, interned as a chain: the trail
    /// before it (or none, -1) and its own position. Its identity is the cache key, so equal keys mean equal positions
    /// with equal context and equal no-progress count.
    private struct Link:Hashable {let before:Int32,spot:Int32}
    private struct Node {var state:MiniGameState,trail:Int32}
    private struct Exhausted:Error {}
    private var spots:[Spot:Int32]=[:],trails:[Link:Int32]=[:],entries:[Entry]=[]
    private var spent=0,limit=0,stop:()->Bool={false}

    /// Proves `state`, using its history as the game's. `historyComplete` says the history reaches back to the start;
    /// when it does not and no capture or pawn move is in it, the draw context is missing and the root is `unknown`.
    public mutating func prove(_ state:MiniGameState,historyComplete:Bool,horizon:Int=MiniGameProofBudget.plies,nodeLimit:Int=MiniGameProofBudget.nodesPerRoot,stop:@escaping ()->Bool={false})->MiniGameProofAnswer {
        precondition(state.kind==kind,"A proof cache belongs to one kind");precondition(horizon<Int(Self.never),"A horizon is a few plies")
        if let winner=state.winner{return MiniGameProofAnswer(result:winner==state.turn ? .win(plies:0):.loss(plies:0),clearPlies:0,line:[],nodes:0,exhausted:false)}
        if state.drawReason != nil{return MiniGameProofAnswer(result:.draw,clearPlies:horizon,line:nil,nodes:0,exhausted:false)}
        let unknown=MiniGameProofAnswer(result:.unknown,clearPlies:0,line:nil,nodes:0,exhausted:false)
        guard let context=Self.drawContext(state,historyComplete:historyComplete) else{return unknown}
        // The cache only ever holds facts, so emptying it between roots changes no answer, only the work.
        if entries.count>cacheLimit{spots=[:];trails=[:];entries=[]}
        var root=state,trail:Int32 = -1;root.history=context
        for snapshot in context+[root.snapshot] {guard let spot=Spot(snapshot) else{return unknown};trail=link(trail,spot)}
        let node=Node(state:root,trail:trail)
        spent=0;limit=nodeLimit;self.stop=stop;defer{self.stop={false}}
        var clear=0
        func answer(_ result:MiniGameProofResult,line:[MiniGameMove]?=nil,exhausted:Bool=false)->MiniGameProofAnswer {MiniGameProofAnswer(result:result,clearPlies:clear,line:line,nodes:spent,exhausted:exhausted)}
        do {
            for t in stride(from:1,through:horizon,by:1) {
                if try wins(node,within:t){return answer(.win(plies:t),line:try self.line(node,wins:true,plies:t))}
                if try loses(node,within:t){return answer(.loss(plies:t),line:try self.line(node,wins:false,plies:t))}
                clear=t
            }
            return try drawn(node,within:horizon) ? answer(.draw):answer(.unknown)
        } catch {return answer(.unknown,exhausted:true)}
    }
    /// The positions before `state` back to its last capture or pawn move: the only ones repetition and the 80-ply
    /// rule can still reach, since a capture lowers the piece count for good and pawns only advance. Nil when the
    /// history was cut before that move.
    public static func drawContext(_ state:MiniGameState,historyComplete:Bool)->[MiniGameSnapshot]? {
        let board=state.board,pawns=board.filter{$0.value.hasSuffix("p")}
        let start=state.history.lastIndex{$0.board.count != board.count || $0.board.filter{$0.value.hasSuffix("p")} != pawns}.map{$0+1}
        guard start != nil || historyComplete else{return nil}
        return Array(state.history[(start ?? 0)...])
    }

    private mutating func link(_ before:Int32,_ spot:Spot)->Int32 {
        let position:Int32;if let known=spots[spot]{position=known}else{position=Int32(spots.count);spots[spot]=position}
        let key=Link(before:before,spot:position)
        if let known=trails[key]{return known};let id=Int32(entries.count);trails[key]=id;entries.append(Entry());return id
    }
    private mutating func charge()throws {guard spent<limit else{throw Exhausted()};spent+=1;nodes+=1;if spent%MiniGameProofBudget.stopInterval==0,stop(){throw Exhausted()}}
    private mutating func outcome(_ node:Node)->Outcome {
        let known=entries[Int(node.trail)].outcome;if known != .unseen{return known}
        let s=node.state,result:Outcome
        if let winner=s.winner{result=winner==s.turn ? .won:.lost}else{result=s.drawReasonWithoutWinner != nil ? .drawn:.open}
        entries[Int(node.trail)].outcome=result;return result
    }
    /// Captures and far-rank arrivals first, so a forced line is usually met early; then by square name.
    private func ordered(_ s:MiniGameState)->[MiniGameMove] {
        let far=s.turn=="w" ? "8":"1"
        func priority(_ m:MiniGameMove)->Int {(s.board[m.to] != nil ? 2:0)+(m.to.hasSuffix(far) && s.board[m.from]?.hasSuffix("p")==true ? 1:0)}
        return MiniGameRules.moves(board:s.board,kind:s.kind,side:s.turn).sorted{priority($0)==priority($1) ? $0.from+$0.to<$1.from+$1.to:priority($0)>priority($1)}
    }
    private mutating func child(_ node:Node,_ move:MiniGameMove)throws->Node {
        try charge()
        var state=node.state
        let irreversible=state.board[move.to] != nil || state.board[move.from]?.hasSuffix("p")==true
        if irreversible{state.history=[]}
        state.advance(move,remember:!irreversible)
        // A move between valid squares keeps every piece encodable.
        return Node(state:state,trail:link(irreversible ? -1:node.trail,Spot(state.snapshot)!))
    }
    private func entry(_ node:Node)->Entry {entries[Int(node.trail)]}
    private mutating func record(_ node:Node,_ change:(inout Entry)->Void){change(&entries[Int(node.trail)])}
    /// The side to move can force a win within `t` plies.
    private mutating func wins(_ node:Node,within t:Int)throws->Bool {
        guard t>=0 else{return false}
        switch outcome(node){case .won:return true;case .lost,.drawn:return false;case .open,.unseen:break}
        let known=entry(node)
        if known.winBy<=t{return true};if t==0 || known.noWin>=t || known.lossBy != Self.never || known.drawnBy != Self.never{return false}
        for move in ordered(node.state) {if try loses(child(node,move),within:t-1){record(node){$0.winBy=min($0.winBy,Int8(t))};return true}}
        record(node){$0.noWin=max($0.noWin,Int8(t))};return false
    }
    /// Every move of the side to move lets the other side force a win within `t` plies of this position.
    private mutating func loses(_ node:Node,within t:Int)throws->Bool {
        guard t>=0 else{return false}
        switch outcome(node){case .lost:return true;case .won,.drawn:return false;case .open,.unseen:break}
        let known=entry(node)
        if known.lossBy<=t{return true};if t==0 || known.noLoss>=t || known.winBy != Self.never || known.drawnBy != Self.never{return false}
        for move in ordered(node.state) {if try !wins(child(node,move),within:t-1){record(node){$0.noLoss=max($0.noLoss,Int8(t))};return false}}
        record(node){$0.lossBy=min($0.lossBy,Int8(t))};return true
    }
    /// The position is a forced draw resolved within `r` plies: no forced win for either side, and every move resolves
    /// within `r-1` to a draw or a loss for the mover (at least one is a draw, or this position would be lost).
    private mutating func drawn(_ node:Node,within r:Int)throws->Bool {
        guard r>=0 else{return false}
        switch outcome(node){case .drawn:return true;case .won,.lost:return false;case .open,.unseen:break}
        let known=entry(node)
        if known.drawnBy<=r{return true};if r==0 || known.notDrawn>=r || known.winBy != Self.never || known.lossBy != Self.never{return false}
        if try wins(node,within:r) || loses(node,within:r){return false}
        for move in ordered(node.state) {
            let next=try child(node,move)
            if try !(wins(next,within:r-1) || loses(next,within:r-1) || drawn(next,within:r-1)){record(node){$0.notDrawn=max($0.notDrawn,Int8(r))};return false}
        }
        record(node){$0.drawnBy=min($0.drawnBy,Int8(r))};return true
    }
    /// A line of best play for a root won or lost in exactly `plies`: the winner takes a move that keeps the shortest
    /// win, the loser one that delays it longest.
    private mutating func line(_ start:Node,wins winning:Bool,plies:Int)throws->[MiniGameMove] {
        var node=start,moves:[MiniGameMove]=[],toWin=winning,left=plies
        while left>0 {
            var chosen:(MiniGameMove,Node)?
            for move in ordered(node.state) {
                let next=try child(node,move)
                let keeps=toWin ? try loses(next,within:left-1):try wins(next,within:left-1) && !wins(next,within:left-2)
                if keeps{chosen=(move,next);break}
            }
            guard let (move,next)=chosen else{preconditionFailure("A proved result has a line")}
            moves.append(move);node=next;toWin.toggle();left-=1
        }
        return moves
    }
}
