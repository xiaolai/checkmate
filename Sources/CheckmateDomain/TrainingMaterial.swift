/// Material and defence-technique geometry for Increment B (plan: Increment B objective contracts). Values only: the
/// bounded outcome search that certifies safety lives in Application; these tags explain technique, never safety.
public enum TrainingMaterial {
    /// Queen 9, rook 5, bishop 3, knight 3, pawn 1; the king has no material value.
    public static let values:[Character:Int]=["p":1,"n":3,"b":3,"r":5,"q":9,"k":0]
    public static func value(_ piece:String)->Int {piece.last.flatMap{values[$0]} ?? 0}
    /// The pieces of a FEN's placement field, or nil when it is malformed.
    public static func board(fen:String)->Position? {
        let rows=fen.split(separator:" ").first?.split(separator:"/",omittingEmptySubsequences:false) ?? []
        guard rows.count==8 else{return nil}
        var board=Position()
        for (index,row) in rows.enumerated() {
            // Only ASCII 1-8 count empty squares, never two in a row, and a rank never runs past the h-file.
            var file=0,skipped=false
            for symbol in row {
                if let ascii=symbol.asciiValue,(49...56).contains(ascii) {guard !skipped else{return nil};file+=Int(ascii)-48;skipped=true}
                else {
                    guard "pnbrqkPNBRQK".contains(symbol),let square=TrainingGeometry.square(file,7-index) else{return nil}
                    board[square]=(symbol.isUppercase ? "w":"b")+symbol.lowercased();file+=1;skipped=false
                }
                guard file<=8 else{return nil}
            }
            guard file==8 else{return nil}
        }
        return board
    }
    /// How a root move answers a threat to the target (plan: defense method coverage). A move can carry several tags.
    public enum DefenseMethod:String,Codable,CaseIterable {
        /// The threatened piece itself moved.
        case moveAway
        /// A piece attacking the target at the root was captured.
        case captureAttacker
        /// The (unmoved) target gained a geometric defender it did not have before.
        case protect
        /// A piece other than the target now stands between a sliding attacker and the target.
        case block
        /// None of the above (for example a counter-threat).
        case other
    }
    /// The squares strictly between two squares on one straight or diagonal line, or nil when they share no line.
    public static func between(_ a:String,_ b:String)->[String]? {
        guard let (ax,ay)=TrainingGeometry.coordinates(a),let (bx,by)=TrainingGeometry.coordinates(b),a != b else{return nil}
        let dx=bx-ax,dy=by-ay
        guard dx==0 || dy==0 || abs(dx)==abs(dy) else{return nil}
        let sx=dx.signum(),sy=dy.signum()
        return (1..<max(abs(dx),abs(dy))).compactMap{TrainingGeometry.square(ax+sx*$0,ay+sy*$0)}
    }
    /// The learner's pieces a move relocates, origin to destination: the moved piece, and the rook when castling.
    static func relocations(before:Position,from:String,to:String,learner:Character)->[String:String] {
        var moved=[from:to]
        guard before[from]==String(learner)+"k",let (fromFile,rank)=TrainingGeometry.coordinates(from),let (toFile,toRank)=TrainingGeometry.coordinates(to),toRank==rank,abs(toFile-fromFile)==2,
              let rookFrom=TrainingGeometry.square(toFile>fromFile ? 7:0,rank),before[rookFrom]==String(learner)+"r",let rookTo=TrainingGeometry.square((fromFile+toFile)/2,rank) else{return moved}
        moved[rookFrom]=rookTo;return moved
    }
    /// The tags for one root move, from the boards before and after it. `target` is the threatened piece's root square;
    /// the attackers are the opponent's pieces geometrically attacking it at the root.
    public static func defenseTags(before:Position,after:Position,from:String,to:String,target:String,learner:Character)->Set<DefenseMethod> {
        let opponent:Character=learner=="w" ? "b":"w"
        let attackers=TrainingGeometry.attackers(of:target,color:opponent,board:before)
        // Castling moves the rook too: each relocated piece is followed, so a castled rook has moved away.
        let moved=relocations(before:before,from:from,to:to,learner:learner)
        var tags=Set<DefenseMethod>()
        if moved[target] != nil{tags.insert(.moveAway)}
        // Removal is the only way an opponent piece leaves its square on the learner's move, en passant included.
        if attackers.contains(where:{after[$0] != before[$0]}){tags.insert(.captureAttacker)}
        if moved[target]==nil,after[target]==before[target] {
            // The same defender relocating is not a new one: follow each moved piece to its new square.
            let old=Set(TrainingGeometry.defenders(of:target,board:before).map{moved[$0] ?? $0}),new=TrainingGeometry.defenders(of:target,board:after)
            if !new.subtracting(old).isEmpty{tags.insert(.protect)}
            let sliders=attackers.filter{before[$0].flatMap{$0.last}.map{"brq".contains($0)}==true && after[$0]==before[$0]}
            if sliders.contains(where:{line in between(line,target).map{path in moved.values.contains{path.contains($0)}}==true}){tags.insert(.block)}
        }
        return tags.isEmpty ? [.other]:tags
    }
}
