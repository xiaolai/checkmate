/// Elementary tactical relations read from the board's geometry (plan: basic tactics). Recognition only: whether a
/// motif wins material is decided by the bounded search, never assumed from the pattern.
public enum TrainingRelationship {
    /// A king can attack only what is undefended, so as an attacker it outranks every piece.
    static func attackerValue(_ piece:String)->Int {piece.last=="k" ? 100:TrainingMaterial.value(piece)}
    /// The enemy pieces a fork by `square` hits: each is the king, worth more than the forking piece, or undefended.
    public static func forked(by square:String,board:Position)->Set<String> {
        guard let piece=board[square] else{return []}
        return TrainingGeometry.attacks(from:square,board:board).filter{to in
            guard let target=board[to],target.first != piece.first else{return false}
            return target.last=="k" || TrainingMaterial.value(target)>attackerValue(piece) || TrainingGeometry.defenders(of:to,board:board).isEmpty
        }
    }
    /// Pieces of `color` making a fork: attacking two or more enemy pieces as `forked(by:)` counts them. Attacking two
    /// defended pieces of no greater value is not a fork.
    public static func forks(by color:Character,board:Position)->Set<String> {
        Set(board.filter{$0.value.first==color && forked(by:$0.key,board:board).count>=2}.keys)
    }
    /// Pieces of `color` pinned by an enemy bishop, rook or queen: to their own king behind them (an absolute pin) or
    /// to a more valuable own piece behind them (a relative pin). Kings are never pinned.
    public static func pinned(color:Character,board:Position)->Set<String> {
        var result=Set<String>()
        for (square,piece) in board where piece.count==2 && piece.first != color && piece.last.map({"brq".contains($0)})==true {
            guard let (file,rank)=TrainingGeometry.coordinates(square) else{continue}
            let directions=(piece.last=="b" ? []:TrainingGeometry.straight)+(piece.last=="r" ? []:TrainingGeometry.diagonal)
            for (dx,dy) in directions {
                var x=file+dx,y=rank+dy,first:String?
                while let at=TrainingGeometry.square(x,y) {
                    if let occupant=board[at] {
                        guard let front=first else {
                            guard occupant.first==color,occupant.last != "k" else{break}
                            first=at;x+=dx;y+=dy;continue
                        }
                        if occupant.first==color,occupant.last=="k" || TrainingMaterial.value(occupant)>TrainingMaterial.value(board[front]!){result.insert(front)}
                        break
                    }
                    x+=dx;y+=dy
                }
            }
        }
        return result
    }
}
