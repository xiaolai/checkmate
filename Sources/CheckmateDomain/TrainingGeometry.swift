/// Exact board geometry for recognition and movement exercises: no turn, check or legality rules.
/// A ray stops at the first occupied square, which it still reaches; a pinned piece still attacks (plan rule 2).
public enum TrainingGeometry {
    static let straight=[(1,0),(-1,0),(0,1),(0,-1)],diagonal=[(1,1),(1,-1),(-1,1),(-1,-1)]
    static let jumps=[(1,2),(2,1),(-1,2),(-2,1),(1,-2),(2,-1),(-1,-2),(-2,-1)]
    public static func coordinates(_ square:String)->(file:Int,rank:Int)? {guard ChessNotation.validSquare(square) else{return nil};return (Int(square.utf8.first!)-97,Int(square.utf8.last!)-49)}
    public static func square(_ file:Int,_ rank:Int)->String? {guard (0..<8).contains(file),(0..<8).contains(rank) else{return nil};return String(UnicodeScalar(UInt8(97+file)))+String(rank+1)}
    /// Squares the piece on `from` attacks (or defends) on `board`. Pawns attack diagonally forward only.
    public static func attacks(from:String,board:Position)->Set<String> {
        guard let piece=board[from],piece.count==2,let (file,rank)=coordinates(from) else{return []}
        let color=piece.first!,kind=piece.last!
        var result=Set<String>()
        func ray(_ directions:[(Int,Int)],slide:Bool){for (dx,dy) in directions {var x=file+dx,y=rank+dy;while let to=square(x,y){result.insert(to);if !slide || board[to] != nil{break};x+=dx;y+=dy}}}
        switch kind {
        case "p":let forward=color=="w" ? 1:-1;for dx in [-1,1]{if let to=square(file+dx,rank+forward){result.insert(to)}}
        case "n":ray(jumps,slide:false)
        case "b":ray(diagonal,slide:true)
        case "r":ray(straight,slide:true)
        case "q":ray(straight+diagonal,slide:true)
        case "k":ray(straight+diagonal,slide:false)
        default:break
        }
        return result
    }
    /// Pieces of `color` that attack `target`, whatever stands on it and however pinned they are.
    public static func attackers(of target:String,color:Character,board:Position)->Set<String> {
        Set(board.filter{$0.key != target && $0.value.first==color && attacks(from:$0.key,board:board).contains(target)}.keys)
    }
    /// Pieces protecting the piece on `target`: its own side's attackers of that square. An own-colour capture is never
    /// legal, but the square is still defended.
    public static func defenders(of target:String,board:Position)->Set<String> {
        guard let occupant=board[target]?.first else{return []};return attackers(of:target,color:occupant,board:board)
    }
}
/// A movement drill: one learner piece among fixed pieces, reaching a marked square (plan rule 4: BFS).
/// Own pieces block and cannot be captured. Enemy pieces stand still; landing on one captures it (a pawn only
/// diagonally), except an enemy king, which blocks. A king never steps onto a square an enemy piece attacks, as in ordinary chess.
public struct MovementDrill:Codable,Equatable {
    /// The search distinguishes every set of captured pieces, so its size grows as 2^enemies: a drill names few.
    public static let maximumEnemies=8
    public let piece:String,start:String,target:String
    /// Fixed pieces: the learner's own colour blocks, the other colour can be captured.
    public let pieces:Position
    public init(piece:String,start:String,target:String,pieces:Position){self.piece=piece;self.start=start;self.target=target;self.pieces=pieces}
    public var color:Character {piece.first ?? "w"}
    /// One reachable state: where the piece stands and which enemy pieces it has captured.
    public struct State:Hashable {public let square:String,captured:Set<String>}
    public var initial:State {State(square:start,captured:[])}
    public func board(_ state:State)->Position {var board=pieces.filter{!state.captured.contains($0.key)};board[state.square]=piece;return board}
    /// Every square the piece may move to from `state`, with what it captures.
    public func moves(_ state:State)->[(to:String,captures:String?)] {
        let board=board(state)
        guard piece.count==2,let kind=piece.last,let (file,rank)=TrainingGeometry.coordinates(state.square) else{return []}
        // An enemy king is never captured: it blocks like an own piece.
        func enemy(_ square:String)->Bool {board[square].map{$0.first != color && $0.last != "k"} ?? false}
        var result:[(String,String?)]=[]
        switch kind {
        case "p":
            let forward=color=="w" ? 1:-1,home=color=="w" ? 1:6
            if let one=TrainingGeometry.square(file,rank+forward),board[one]==nil {result.append((one,nil));if rank==home,let two=TrainingGeometry.square(file,rank+2*forward),board[two]==nil{result.append((two,nil))}}
            for to in TrainingGeometry.attacks(from:state.square,board:board) where enemy(to){result.append((to,to))}
        default:
            for to in TrainingGeometry.attacks(from:state.square,board:board).sorted() where board[to]==nil || enemy(to) {result.append((to,board[to]==nil ? nil:to))}
        }
        guard kind=="k" else{return result}
        // A king may not step where an enemy piece would then attack it.
        return result.filter{to,_ in
            var after=board;after.removeValue(forKey:state.square);after[to]=piece
            return !after.contains{$0.value.first != color && $0.key != to && TrainingGeometry.attacks(from:$0.key,board:after).contains(to)}
        }
    }
    public func apply(_ state:State,to:String)->State? {
        guard let move=moves(state).first(where:{$0.to==to}) else{return nil}
        return Self.reached(state,move)
    }
    /// The state after `move`, one of `moves(state)`.
    private static func reached(_ state:State,_ move:(to:String,captures:String?))->State {State(square:move.to,captured:move.captures.map{state.captured.union([$0])} ?? state.captured)}
    /// Fewest moves from `state` to the target, or nil when it cannot be reached. The search ends once it is reached.
    public func distance(from state:State)->Int? {search(from:state,stopAt:target,finishAtStop:true)[target]}
    /// The fewest moves from `state` to every reachable square. Reaching `stopAt` ends that route: the drill is over.
    public func distances(from state:State,stopAt:String?=nil)->[String:Int] {search(from:state,stopAt:stopAt,finishAtStop:false)}
    private func search(from state:State,stopAt:String?,finishAtStop:Bool)->[String:Int] {
        var frontier=[state],seen:Set<State>=[state],depth=0,result:[String:Int]=[:]
        while !frontier.isEmpty {
            for current in frontier where result[current.square]==nil{result[current.square]=depth}
            if finishAtStop,let stopAt,result[stopAt] != nil{break}
            depth+=1;var next:[State]=[]
            for current in frontier where current.square != stopAt {for move in moves(current) {let child=Self.reached(current,move);if seen.insert(child).inserted{next.append(child)}}}
            frontier=next
        }
        return result
    }
}
