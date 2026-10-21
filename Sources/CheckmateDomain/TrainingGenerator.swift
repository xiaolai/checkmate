import CheckmateAssets
/// Seeded movement and recognition generators (plan rule 5). Each tier has explicit constraints; at most 64
/// candidates are tried per seed, every candidate is validated by the exact evaluator, and no transform is applied, so
/// pawn direction never changes meaning. Exhaustion returns nil and the caller says so honestly.
public enum TrainingGenerator {
    public static let version=2,candidateCap=64
    public static let pieceNames=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    static func randomSquare(_ random:inout TrainingRandom,files:ClosedRange<Int>=0...7,ranks:ClosedRange<Int>=0...7)->String {TrainingGeometry.square(random.int(files),random.int(ranks))!}
    static func cluster(_ prefix:String,_ parts:[String])->String {
        // A stable FNV-1a fingerprint of the concrete board: same board, same cluster.
        var hash:UInt64=0xcbf29ce484222325;for byte in parts.joined(separator:"|").utf8{hash=(hash ^ UInt64(byte)) &* 0x100000001b3}
        return prefix+"-"+String(hash,radix:16)
    }
    static func seedText(_ seed:UInt64)->String {String(seed,radix:16)}
    // MARK: Reach the Target
    struct ReachTier {let blockers:ClosedRange<Int>,enemies:ClosedRange<Int>,distance:ClosedRange<Int>,slack:Int}
    static func reachTier(_ tier:Int,piece:String)->ReachTier {
        switch tier {
        case 1:return ReachTier(blockers:0...2,enemies:0...0,distance:2...3,slack:2)
        case 2:return ReachTier(blockers:2...5,enemies:1...2,distance:piece=="p" ? 2...4:3...4,slack:1)
        default:return ReachTier(blockers:4...7,enemies:2...3,distance:3...5,slack:0)
        }
    }
    /// A movement drill for `piece` (p n b r q k). Tier 3 asks explicitly for a shortest route; earlier tiers allow slack,
    /// so a correct longer route is never punished unless the task says "fewest moves".
    public static func reachTarget(seed:UInt64,tier:Int,color:Character,piece:String)->TrainingScenario? {
        guard (1...3).contains(tier),["w","b"].contains(color),let name=pieceNames[piece] else{return nil}
        var random=TrainingRandom(seed:seed &+ UInt64(tier)<<56),limits=reachTier(tier,piece:piece)
        let own=String(color),enemy=color=="w" ? "b":"w",fillers=["p","n","b","r"]
        for candidate in 1...candidateCap {
            let start:String
            if piece=="p" {start=TrainingGeometry.square(random.int(0...7),color=="w" ? random.int(1...3):random.int(4...6))!}else{start=randomSquare(&random)}
            var pieces:Position=[:]
            // Pawns never stand on the first or last rank.
            func free(pawn:Bool=false)->String? {for _ in 0..<20 {let square=randomSquare(&random);if square != start,pieces[square]==nil,!pawn || !["1","8"].contains(square.suffix(1)){return square}};return nil}
            // A piece that finds no square rejects the candidate, so a drill never has fewer pieces than its tier asks.
            var placed=true
            for _ in 0..<random.int(limits.blockers){let kind=random.pick(fillers);if let square=free(pawn:kind=="p"){pieces[square]=own+kind}else{placed=false}}
            for _ in 0..<random.int(limits.enemies){let kind=random.pick(fillers);if let square=free(pawn:kind=="p"){pieces[square]=enemy+kind}else{placed=false}}
            guard placed else{continue}
            // The target is drawn from the squares the piece can actually reach at the tier's distance, so a seed rarely
            // needs a second candidate. Later tiers need a real detour: no target the piece already attacks from its start.
            let open=MovementDrill(piece:own+piece,start:start,target:start,pieces:pieces),startBoard=open.board(open.initial)
            if piece=="k",pieces.contains(where:{$0.value.first != color && TrainingGeometry.attacks(from:$0.key,board:startBoard).contains(start)}){continue}
            // The target changes no move, so these distances are the drill's own: one search serves both.
            let distances=open.distances(from:open.initial)
            let reachable=distances.filter{limits.distance.contains($0.value) && pieces[$0.key]==nil && (tier==1 || !TrainingGeometry.attacks(from:start,board:startBoard).contains($0.key))}.keys.sorted()
            guard !reachable.isEmpty else{continue}
            let target=random.pick(reachable),drill=MovementDrill(piece:own+piece,start:start,target:target,pieces:pieces)
            guard let distance=distances[target] else{continue}
            let budget=distance+limits.slack,shortest=tier>=3
            let mover=PieceName.the(String(color),piece)
            let prompt=shortest ? String(localized:"Move \(mover) from \(start) to \(target) in the fewest moves: \(budget).",bundle:.checkmate,comment:"A training prompt: the piece, as in the white knight, its start and target squares, then the number of moves"):String(localized:"Move \(mover) from \(start) to \(target) in at most \(budget) moves.",bundle:.checkmate,comment:"A training prompt: the piece, as in the white knight, its start and target squares, then the most moves allowed")
            let id="gen-reach-target-\(piece)-t\(tier)-\(own)-\(seedText(seed))"
            return TrainingScenario(id:id,entry:"reach-target",variant:name,tier:tier,cluster:cluster("reach",[own+piece,start,target]+pieces.sorted{$0.key<$1.key}.map{$0.key+$0.value}),learner:own,prompt:prompt,explanation:String(localized:"A shortest route takes \(distance) moves.",bundle:.checkmate),hints:[movementHint(piece)],drill:drill,budget:budget,shortest:shortest,expected:TrainingExpected(distance:distance),generation:TrainingGeneration(generator:"reach-target",version:version,seed:seedText(seed),candidates:candidate))
        }
        return nil
    }
    public static func movementHint(_ piece:String)->String {
        switch piece {
        case "p":return String(localized:"A pawn moves straight forward one square, or two from its starting square, and captures only one square diagonally forward.",bundle:.checkmate)
        case "n":return String(localized:"A knight jumps in an L: two squares one way and one square sideways. It hops over pieces.",bundle:.checkmate)
        case "b":return String(localized:"A bishop slides diagonally and stays on squares of one color. It cannot pass through pieces.",bundle:.checkmate)
        case "r":return String(localized:"A rook slides along ranks and files. It cannot pass through pieces.",bundle:.checkmate)
        case "q":return String(localized:"A queen slides like a rook or a bishop. It cannot pass through pieces.",bundle:.checkmate)
        default:return String(localized:"A king steps one square in any direction, and never onto a square an enemy piece attacks.",bundle:.checkmate)
        }
    }
    // MARK: Find the Attackers / Defenders
    struct RecognitionTier {let asked:ClosedRange<Int>,others:ClosedRange<Int>,answers:ClosedRange<Int>,kings:Bool,emptyChance:Int}
    static func recognitionTier(_ tier:Int)->RecognitionTier {
        switch tier {
        case 1:return RecognitionTier(asked:2...4,others:0...1,answers:1...3,kings:false,emptyChance:0)
        case 2:return RecognitionTier(asked:3...5,others:2...3,answers:0...3,kings:false,emptyChance:6)
        default:return RecognitionTier(asked:4...6,others:3...4,answers:0...4,kings:true,emptyChance:6)
        }
    }
    /// A slider of `color` aligned with `target` whose line is blocked, or a pawn beside it attacking away: a piece that
    /// looks like an attacker but is not one.
    static func lookalikes(_ board:Position,target:String,color:Character)->[String] {
        guard let (tx,ty)=TrainingGeometry.coordinates(target) else{return []}
        return board.compactMap{square,piece in
            guard piece.first==color,square != target,let (x,y)=TrainingGeometry.coordinates(square),!TrainingGeometry.attacks(from:square,board:board).contains(target) else{return nil}
            let dx=tx-x,dy=ty-y,straight=dx==0 || dy==0,diagonal=abs(dx)==abs(dy)
            switch piece.last! {
            case "r":return straight ? square:nil
            case "b":return diagonal ? square:nil
            case "q":return straight || diagonal ? square:nil
            case "p":return abs(dx)==1 && abs(dy)==1 ? square:nil
            case "n":return max(abs(dx),abs(dy))<=2 ? square:nil
            default:return nil
            }
        }
    }
    public static func findAttackers(seed:UInt64,tier:Int,color:Character)->TrainingScenario? {recognition(seed:seed,tier:tier,color:color,defenders:false)}
    public static func findDefenders(seed:UInt64,tier:Int,color:Character)->TrainingScenario? {recognition(seed:seed,tier:tier,color:color,defenders:true)}
    static func recognition(seed:UInt64,tier:Int,color:Character,defenders:Bool)->TrainingScenario? {
        guard (1...3).contains(tier),["w","b"].contains(color) else{return nil}
        var random=TrainingRandom(seed:seed &+ UInt64(tier)<<56 &+ (defenders ? 1<<60:0)),limits=recognitionTier(tier)
        let own=String(color),enemy=color=="w" ? "b":"w",kinds=["p","n","b","r","q"]
        for candidate in 1...candidateCap {
            let target=tier==1 ? randomSquare(&random,files:1...6,ranks:1...6):randomSquare(&random)
            var board:Position=[:]
            // Pawns never stand on the first or last rank, the marked square included.
            let occupants=["1","8"].contains(target.suffix(1)) ? kinds.filter{$0 != "p"}:kinds
            if defenders {board[target]=own+random.pick(occupants)}else if tier>1,random.chance(1,in:2){board[target]=enemy+random.pick(occupants)}
            // A piece that finds no square rejects the candidate, so a board never has fewer pieces than its tier asks.
            var placed=true
            func place(_ piece:String){for _ in 0..<20 {let square=randomSquare(&random);guard board[square]==nil,square != target else{continue};if piece.last=="p",["1","8"].contains(square.suffix(1)){continue};board[square]=piece;return};placed=false}
            if limits.kings {place(own+"k");place(enemy+"k")}
            for _ in 0..<random.int(limits.asked){place(own+random.pick(kinds))}
            for _ in 0..<random.int(limits.others){place(enemy+random.pick(kinds))}
            guard placed else{continue}
            if limits.kings {let kings=board.filter{$0.value.hasSuffix("k")}.keys.compactMap(TrainingGeometry.coordinates);if kings.count != 2 || abs(kings[0].file-kings[1].file)<=1 && abs(kings[0].rank-kings[1].rank)<=1{continue}}
            let answer=defenders ? TrainingGeometry.defenders(of:target,board:board):TrainingGeometry.attackers(of:target,color:color,board:board)
            let wantEmpty=limits.emptyChance>0 && random.chance(1,in:limits.emptyChance)
            guard limits.answers.contains(answer.count),wantEmpty==answer.isEmpty else{continue}
            if tier>1,lookalikes(board,target:target,color:color).isEmpty{continue}
            // Each side has its own sentences, so a language can make "White" agree with "piece".
            let white=color=="w",entry=defenders ? "find-defenders":"find-attackers"
            let prompt:String
            if let occupant=board[target] {
                let theirs=PieceName.bracketed(String(occupant.first!),String(occupant.last!))
                prompt=defenders ? (white ? String(localized:"Select every White piece that protects the piece on \(target) (\(theirs)). Choose None if nothing protects it.",bundle:.checkmate,comment:"A training prompt: the square, then the piece on it, as in the white knight"):String(localized:"Select every Black piece that protects the piece on \(target) (\(theirs)). Choose None if nothing protects it.",bundle:.checkmate,comment:"A training prompt: the square, then the piece on it, as in the black knight")):white ? String(localized:"Select every White piece that attacks \(target) (\(theirs)). Choose None if no White piece attacks it.",bundle:.checkmate,comment:"A training prompt: the square, then the piece on it, as in the black knight"):String(localized:"Select every Black piece that attacks \(target) (\(theirs)). Choose None if no Black piece attacks it.",bundle:.checkmate,comment:"A training prompt: the square, then the piece on it, as in the white knight")
            }else{
                prompt=defenders ? (white ? String(localized:"Select every White piece that protects the piece on \(target). Choose None if nothing protects it.",bundle:.checkmate):String(localized:"Select every Black piece that protects the piece on \(target). Choose None if nothing protects it.",bundle:.checkmate)):white ? String(localized:"Select every White piece that attacks \(target). Choose None if no White piece attacks it.",bundle:.checkmate):String(localized:"Select every Black piece that attacks \(target). Choose None if no Black piece attacks it.",bundle:.checkmate)
            }
            let hint=defenders ? (white ? String(localized:"Which other White pieces attack \(target)? Follow their lines and jumps; a line stops at the first piece in the way. A pinned piece or a king still counts as protecting here.",bundle:.checkmate):String(localized:"Which other Black pieces attack \(target)? Follow their lines and jumps; a line stops at the first piece in the way. A pinned piece or a king still counts as protecting here.",bundle:.checkmate)):white ? String(localized:"Follow each White piece's lines and jumps. A line stops at the first piece in the way; a pinned piece still attacks.",bundle:.checkmate):String(localized:"Follow each Black piece's lines and jumps. A line stops at the first piece in the way; a pinned piece still attacks.",bundle:.checkmate)
            let pieces=answer.sorted().joined(separator:", ")
            let explanation=answer.isEmpty ? (defenders ? (white ? String(localized:"No White piece protects \(target).",bundle:.checkmate):String(localized:"No Black piece protects \(target).",bundle:.checkmate)):white ? String(localized:"No White piece attacks \(target).",bundle:.checkmate):String(localized:"No Black piece attacks \(target).",bundle:.checkmate)):defenders ? (answer.count==1 ? String(localized:"\(pieces) protects \(target).",bundle:.checkmate,comment:"One piece's square, then the square it protects"):String(localized:"\(pieces) protect \(target).",bundle:.checkmate,comment:"Two or more pieces' squares, then the square they protect")):(answer.count==1 ? String(localized:"\(pieces) attacks \(target).",bundle:.checkmate,comment:"One piece's square, then the square it attacks"):String(localized:"\(pieces) attack \(target).",bundle:.checkmate,comment:"Two or more pieces' squares, then the square they attack"))
            return TrainingScenario(id:"gen-\(entry)-t\(tier)-\(own)-\(seedText(seed))",entry:entry,variant:defenders ? "defenders":"attackers",tier:tier,cluster:cluster(defenders ? "defend":"attack",[own,target]+board.sorted{$0.key<$1.key}.map{$0.key+$0.value}),learner:own,prompt:prompt,explanation:explanation,hints:[hint],diagram:board,target:target,expected:TrainingExpected(squares:answer.sorted()),generation:TrainingGeneration(generator:entry,version:version,seed:seedText(seed),candidates:candidate))
        }
        return nil
    }
}
