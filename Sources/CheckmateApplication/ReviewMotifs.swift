import CheckmateAssets
import CheckmateDomain
import Foundation
/// A tactical pattern a move created, read from the real boards before and after it. The geometry is an attack map
/// (`TrainingGeometry`: pinned pieces still attack, legality is not checked), so each text says what is attacked or
/// lined up, never that something wins.
public struct ReviewMotif:Equatable {
    public enum Kind:String,CaseIterable {case fork,pin,skewer,hanging,backRank,discovered}
    public let kind:Kind,text:String,squares:[String]
}
public enum ReviewMotifs {
    private static let values:[Character:Int]=["p":1,"n":3,"b":3,"r":5,"q":9,"k":100]
    private static let straight=[(1,0),(-1,0),(0,1),(0,-1)],diagonal=[(1,1),(1,-1),(-1,1),(-1,-1)]
    private static func kind(_ board:Position,_ square:String)->Character? {board[square].flatMap{$0.count==2 ? $0.last:nil}}
    private static func value(_ board:Position,_ square:String)->Int {kind(board,square).flatMap{values[$0]} ?? 0}
    private static func color(_ board:Position,_ square:String)->Character? {board[square]?.first}
    /// "the black rook on a8": a piece by color and kind, with its square.
    private static func named(_ board:Position,_ square:String)->String {
        String(localized:"review.motif.named",defaultValue:"\(PieceName.the(color(board,square).map{String($0)},kind(board,square).map{String($0)})) on \(square)",bundle:.checkmate,comment:"A piece by color and kind with its square, as in: the black rook on a8")
    }
    /// The kind of the piece on `square`, for a phrase from `PieceName.phrase`.
    private static func letter(_ board:Position,_ square:String)->String? {kind(board,square).map{String($0)}}
    private static func other(_ side:Character)->Character {side=="w" ? "b":"w"}
    private static func hanging(_ board:Position,_ square:String)->Bool {
        guard let side=color(board,square),kind(board,square) != "k" else{return false}
        return !TrainingGeometry.attackers(of:square,color:other(side),board:board).isEmpty && TrainingGeometry.defenders(of:square,board:board).isEmpty
    }

    /// The patterns the move from `from` to `to` created, strongest first: `before` and `after` are the real boards.
    public static func find(before:Position,after:Position,from:String,to:String)->[ReviewMotif] {
        guard let mover=color(after,to) else{return []}
        let enemy=other(mover);var found:[ReviewMotif]=[]
        // Fork: the moved piece attacks two or more pieces that each matter: the king, a piece worth more than the
        // attacker, or one nothing defends.
        let targets=TrainingGeometry.attacks(from:to,board:after).filter{color(after,$0)==enemy && value(after,$0)>=3 && (kind(after,$0)=="k" || value(after,$0)>value(after,to) || TrainingGeometry.defenders(of:$0,board:after).isEmpty)}.sorted{(value(after,$0),$0)>(value(after,$1),$1)}
        if targets.count>=2 {found.append(ReviewMotif(kind:.fork,text:String(localized:"Fork: \(PieceName.phrase(letter(after,to),.subject)) on \(to) attacks \(Plural.list(targets.map{named(after,$0)})) at once.",bundle:.checkmate,comment:"A tactic in a reviewed move, as in: Fork: the knight on c7 attacks the black king on e8 and the black rook on a8 at once."),squares:[to]+targets))}
        // Pin and skewer: two enemy pieces on one line from the moved piece. A cheaper piece in front pins; a dearer
        // one in front (the king above all) is skewered.
        if let mover=kind(after,to),"brq".contains(mover) {
            let directions=mover=="b" ? diagonal:mover=="r" ? straight:straight+diagonal
            for line in directions.map({ray(from:to,$0,after)}) where line.count==2 && line.allSatisfy({color(after,$0)==enemy}) {
                let front=line[0],back=line[1]
                if value(after,back)>value(after,front) {found.append(ReviewMotif(kind:.pin,text:kind(after,back)=="k" ? String(localized:"Pin: \(PieceName.phrase(letter(after,to),.subject)) on \(to) pins \(named(after,front)) to \(named(after,back)); moving it would expose the king.",bundle:.checkmate):String(localized:"Pin: \(PieceName.phrase(letter(after,to),.subject)) on \(to) pins \(named(after,front)) against \(named(after,back)) behind it.",bundle:.checkmate),squares:[to,front,back]))}
                else if value(after,front)>value(after,back),value(after,back)>=3 {found.append(ReviewMotif(kind:.skewer,text:String(localized:"Skewer: \(PieceName.phrase(letter(after,to),.subject)) on \(to) attacks \(named(after,front)), with \(named(after,back)) behind it on the same line.",bundle:.checkmate),squares:[to,front,back]))}
            }
        }
        // Discovered attack: another of the mover's long-range pieces now reaches a piece the moved one stood in front of.
        for (square,occupant) in after where square != to && occupant.first==mover && "brq".contains(occupant.last!) {
            let before=TrainingGeometry.attacks(from:square,board:before)
            for target in TrainingGeometry.attacks(from:square,board:after) where !before.contains(target) && color(after,target)==enemy && value(after,target)>=3 && between(square,target).contains(from) {
                found.append(ReviewMotif(kind:.discovered,text:String(localized:"Discovered attack: moving away from \(from) opens the line of \(PieceName.phrase(letter(after,square),.object)) on \(square) to \(named(after,target)).",bundle:.checkmate),squares:[square,from,target]))
            }
        }
        // Back rank: the move created a threat to check the king along its home row with no square to step forward to.
        if let threat=backRank(after,attacker:mover),backRank(before,attacker:mover)==nil {
            found.append(ReviewMotif(kind:.backRank,text:color(after,threat.king)=="w" ? String(localized:"Back rank: the white king on \(threat.king) has no free square in front of it, and \(PieceName.phrase(letter(after,threat.piece),.subject)) on \(threat.piece) can reach \(threat.entry) with check. Watch for a back-rank checkmate.",bundle:.checkmate):String(localized:"Back rank: the black king on \(threat.king) has no free square in front of it, and \(PieceName.phrase(letter(after,threat.piece),.subject)) on \(threat.piece) can reach \(threat.entry) with check. Watch for a back-rank checkmate.",bundle:.checkmate),squares:[threat.king,threat.piece,threat.entry]))
        }
        // Hanging pieces: attacked with no defender now, and not before the move (or just arrived). A piece another
        // pattern already names is not repeated, and two are enough to point at.
        let mentioned=Set(found.flatMap(\.squares))
        for square in after.keys.sorted() where hanging(after,square) && !mentioned.contains(square) && (square==to || before[square] != after[square] || !hanging(before,square)) && value(after,square)>=3 && found.filter({$0.kind == .hanging}).count<2 {
            let by=TrainingGeometry.attackers(of:square,color:other(color(after,square)!),board:after).sorted{(value(after,$0),$0)<(value(after,$1),$1)}
            found.append(ReviewMotif(kind:.hanging,text:String(localized:"Hanging piece: \(named(after,square)) is attacked by \(PieceName.phrase(letter(after,by[0]),.object)) on \(by[0]) and nothing defends it.",bundle:.checkmate),squares:[square,by[0]]))
        }
        return found
    }
    /// The first two occupied squares along a direction from `square`.
    private static func ray(from square:String,_ direction:(Int,Int),_ board:Position)->[String] {
        guard var (file,rank)=TrainingGeometry.coordinates(square) else{return []};var hits:[String]=[]
        while hits.count<2 {file+=direction.0;rank+=direction.1;guard let next=TrainingGeometry.square(file,rank) else{break};if board[next] != nil{hits.append(next)}}
        return hits
    }
    /// The squares strictly between two squares on one line; empty when they share no line.
    private static func between(_ a:String,_ b:String)->[String] {
        guard let p=TrainingGeometry.coordinates(a),let q=TrainingGeometry.coordinates(b) else{return []}
        let dx=q.file-p.file,dy=q.rank-p.rank;guard (dx==0 || dy==0 || abs(dx)==abs(dy)),dx != 0 || dy != 0 else{return []}
        let steps=max(abs(dx),abs(dy)),sx=dx.signum(),sy=dy.signum()
        return (1..<steps).compactMap{TrainingGeometry.square(p.file+sx*$0,p.rank+sy*$0)}
    }
    /// The defender's king on its home row with every square in front of it blocked by its own pieces or attacked,
    /// and an attacking rook or queen that reaches an undefended square of that row with a clear path to the king.
    private static func backRank(_ board:Position,attacker:Character)->(king:String,piece:String,entry:String)? {
        let defender=other(attacker),home=defender=="w" ? 0:7,forward=defender=="w" ? 1:-1
        guard let king=board.first(where:{$0.value==String(defender)+"k"})?.key,let (file,rank)=TrainingGeometry.coordinates(king),rank==home else{return nil}
        let front=(-1...1).compactMap{TrainingGeometry.square(file+$0,rank+forward)}
        guard front.allSatisfy({color(board,$0)==defender || !TrainingGeometry.attackers(of:$0,color:attacker,board:board).isEmpty}) else{return nil}
        for (square,occupant) in board.sorted(by:{$0.key<$1.key}) where occupant.first==attacker && "rq".contains(occupant.last!) {
            for entry in TrainingGeometry.attacks(from:square,board:board).sorted() where TrainingGeometry.coordinates(entry)?.rank==home && entry != king && board[entry]==nil {
                let guards=TrainingGeometry.attackers(of:entry,color:defender,board:board).filter{$0 != king}
                let kingCovers=TrainingGeometry.attacks(from:king,board:board).contains(entry) && TrainingGeometry.attackers(of:entry,color:attacker,board:board).count<2
                if guards.isEmpty && !kingCovers && between(entry,king).allSatisfy({board[$0]==nil}) {return (king,square,entry)}
            }
        }
        return nil
    }
}
