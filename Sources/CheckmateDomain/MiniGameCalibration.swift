import Foundation

/// Calibration of the mini-game opponent levels (plan D4, WI-016): which levels of a game are far enough apart to be
/// offered. The manifest fixes everything before a game is played; `Tools/MiniGameCalibration` plays it on the test host
/// and writes `Content/calibration/mini-game-results.json`, from which `verdict` derives each game's offered levels.
/// `MiniGameOffering.table` holds them, and a unit test keeps the two equal.
public enum MiniGameCalibration {
    /// The entry kinds the harness plays. Simplified games use the mini-game search; standard-rule entries (Stockfish)
    /// join after WI-017 as a second kind with their own references and identity, and are refused until then.
    public static let entryKinds=["simplified"]
    public static let references=["random","greedy","level-below"]
    /// The files, relative to the package root, whose contents decide a calibration game or its verdict. The harness
    /// records their SHA-256 beside the manifest's, and a unit test re-hashes them, so results of older sources fail.
    public static let sourceFiles=["Sources/CheckmateDomain/MiniGames.swift","Sources/CheckmateDomain/MiniGameCalibration.swift","Sources/CheckmateDomain/Course.swift","Sources/CheckmateDomain/ChessNotation.swift","Tools/MiniGameCalibration/main.swift"]
    /// One side of a calibration game: a level of the mini-game search, or a reference player.
    public enum Player:Equatable {
        case level(String),random,greedy
        public init?(reference:String,below level:String) {
            switch reference {
            case "random":self = .random
            case "greedy":self = .greedy
            case "level-below":
                guard let index=MiniOpponentPolicy.profiles.firstIndex(of:level),index>0 else{return nil};self = .level(MiniOpponentPolicy.profiles[index-1])
            default:return nil
            }
        }
    }

    // MARK: Manifest

    public struct PassRule:Codable,Equatable {
        /// The reference every level plays for the pass rule, the least difference of score against it between adjacent
        /// levels, and the two-sided confidence of the Wilson intervals that must not overlap.
        public var reference:String,minimumDifference:Double,confidence:Double
        /// The second branch, for a pair whose lower level already beats the reference almost always.
        public var headToHead:HeadToHeadRule
    }
    public struct HeadToHeadRule:Codable,Equatable {
        /// The reference is saturated for a level that scores at least `saturatedScore` against it; the upper level then
        /// passes by scoring at least `minimumScore` against the lower one with its interval's lower bound above
        /// `lowerBoundAbove`.
        public var saturatedScore:Double,minimumScore:Double,lowerBoundAbove:Double
    }
    public struct Accessibility:Codable,Equatable {
        /// Gentle (the weakest level) is accessible when `reference` scores at least `minimumReferenceScore` against it.
        public var reference:String,minimumReferenceScore:Double
    }
    public struct Entry:Codable,Equatable {public var kind:String,game:String,start:String,accessibility:Accessibility}
    public struct DeadlineRun:Codable,Equatable {
        /// The production-deadline run: `gamesPerLevel` games of each level against `reference` with the time limit on,
        /// while `loadThreadsPerCore` busy threads per core load the machine beside one game per core.
        public var reference:String,gamesPerLevel:Int,loadThreadsPerCore:Int
    }
    public struct Manifest:Codable,Equatable {
        public var schema:Int,levels:[String],references:[String]
        /// The sides a level plays, each in half of a pairing's games: every start has White to move, so "the reference
        /// plays both sides" means the level is White in one half and Black (as in the app) in the other.
        public var sides:[String]
        public var gamesPerPairing:Int,drawScore:Double
        /// A game still running after this many plies is stopped and scored as a draw, and counted as adjudicated.
        public var maximumPlies:Int
        /// Every game's seeds derive from this one, its game, pairing and index (`seed(_:_:_:_:)`).
        public var seed:String
        public var passRule:PassRule,deadline:DeadlineRun,entries:[Entry]
    }
    /// Everything wrong with `manifest`, empty when it may be played. Checked before any game.
    public static func problems(_ manifest:Manifest)->[String] {
        var found:[String]=[]
        func require(_ condition:Bool,_ message:String){if !condition{found.append(message)}}
        require(manifest.schema==1,"schema must be 1")
        require(manifest.levels==MiniOpponentPolicy.profiles,"levels must be \(MiniOpponentPolicy.profiles), weakest first")
        require(manifest.references==references,"references must be \(references)")
        require(manifest.sides==["w","b"],"sides must be [w, b]")
        require(manifest.drawScore==0.5,"a draw scores half a point")
        require((100...2000).contains(manifest.maximumPlies),"maximumPlies must be 100...2000")
        require(UInt64(manifest.seed,radix:16) != nil,"seed must be hexadecimal")
        let rule=manifest.passRule
        require(rule.reference=="greedy","the pass rule plays greedy")
        require(rule.minimumDifference==0.10,"the pass rule needs at least 10 points of difference")
        require(rule.confidence==0.95,"the pass rule uses 95% Wilson intervals")
        require(rule.headToHead==HeadToHeadRule(saturatedScore:0.90,minimumScore:0.60,lowerBoundAbove:0.50),"the head-to-head branch needs greedy saturated at 90%, then at least 60% against the level below with the lower bound above 50%")
        let needed=requiredGames(minimumDifference:rule.minimumDifference,confidence:rule.confidence)
        require(manifest.gamesPerPairing%manifest.sides.count==0,"gamesPerPairing must split evenly between the sides")
        require(manifest.gamesPerPairing>=needed,"gamesPerPairing \(manifest.gamesPerPairing) is below the \(needed) games at which a \(Int(rule.minimumDifference*100))-point difference always separates the intervals")
        require(references.contains(manifest.deadline.reference) && manifest.deadline.reference != "level-below","the deadline run plays a fixed reference")
        require((2...1000).contains(manifest.deadline.gamesPerLevel) && manifest.deadline.gamesPerLevel%2==0,"the deadline run needs an even number of games, 2...1000")
        require((0...8).contains(manifest.deadline.loadThreadsPerCore),"loadThreadsPerCore must be 0...8")
        let competitive=MiniGameKind.allCases.filter{!$0.solo}.map(\.rawValue)
        require(manifest.entries.map(\.game).sorted()==competitive.sorted(),"entries must name every competitive game exactly once: \(competitive)")
        for entry in manifest.entries {
            require(entryKinds.contains(entry.kind),"\(entry.game): entry kind \(entry.kind) is not played yet (standard-rule entries follow WI-017)")
            require(entry.start=="initial","\(entry.game): the only start is the game's initial position")
            require(references.contains(entry.accessibility.reference) && entry.accessibility.reference != "level-below","\(entry.game): accessibility is measured against a fixed reference")
            require(entry.accessibility.minimumReferenceScore>0 && entry.accessibility.minimumReferenceScore<1,"\(entry.game): accessibility threshold must be inside (0, 1)")
        }
        return found
    }
    /// The pairings every level plays, in order: each reference the level has (the weakest level has none below it).
    public static func pairings(_ manifest:Manifest)->[(level:String,reference:String)] {
        manifest.levels.flatMap{level in manifest.references.filter{Player(reference:$0,below:level) != nil}.map{(level,$0)}}
    }

    // MARK: Statistics

    /// The two-sided normal quantile of the confidences the manifest may name.
    static func z(_ confidence:Double)->Double {confidence==0.95 ? 1.959963984540054:confidence==0.99 ? 2.5758293035489:.nan}
    /// The Wilson score interval of `score` over `games`. A score with draws (half points) has less variance than a
    /// win-or-lose proportion of the same mean, so this interval is conservative for it.
    public static func wilson(score:Double,games:Int,confidence:Double)->ClosedRange<Double> {
        guard games>0 else{return 0...1}
        let n=Double(games),z=z(confidence),z2=z*z,centre=(score+z2/(2*n))/(1+z2/n)
        let half=z*((score*(1-score)/n+z2/(4*n*n)).squareRoot())/(1+z2/n)
        return max(0,centre-half)...min(1,centre+half)
    }
    /// The fewest games per pairing (split evenly between two sides) at which any two scores `minimumDifference` apart
    /// have disjoint intervals, so the difference rule, not the sample, decides a pass.
    public static func requiredGames(minimumDifference:Double,confidence:Double)->Int {
        var n=2
        while n<100_000 {
            let separates=stride(from:0.0,through:1-minimumDifference,by:0.001).allSatisfy{p in
                wilson(score:p,games:n,confidence:confidence).upperBound<wilson(score:min(1,p+minimumDifference),games:n,confidence:confidence).lowerBound}
            if separates{return n};n+=2
        }
        return n
    }

    // MARK: Players and games

    /// SplitMix64: independent seeds from one manifest seed.
    static func mix(_ value:UInt64)->UInt64 {var z=value &+ 0x9e3779b97f4a7c15;z=(z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9;z=(z ^ (z >> 27)) &* 0x94d049bb133111eb;return z ^ (z >> 31)}
    /// The seed of game `index` of one pairing of one game.
    public static func seed(_ manifestSeed:UInt64,_ game:MiniGameKind,_ pairing:String,_ index:Int)->UInt64 {
        var hash:UInt64=0xcbf29ce484222325;for byte in "\(game.rawValue)|\(pairing)|\(index)".utf8{hash=(hash ^ UInt64(byte)) &* 0x100000001b3}
        return mix(manifestSeed ^ hash)
    }
    static let values=["p":100,"n":350,"b":330,"r":500,"q":900]
    /// A reference player's move: `random` picks uniformly among the legal moves; `greedy` captures the most valuable
    /// piece it can (ties at random), else moves at random.
    public static func referenceMove(_ player:Player,in state:MiniGameState,seed:UInt64)->MiniGameMove? {
        let legal=MiniGameRules.moves(board:state.board,kind:state.kind,side:state.turn);guard !legal.isEmpty,!state.isFinished else{return nil}
        var pool=legal
        if player == .greedy {
            let gain={(move:MiniGameMove) in state.board[move.to].map{values[String($0.suffix(1)),default:0]} ?? 0}
            let best=legal.map(gain).max() ?? 0;if best>0{pool=legal.filter{gain($0)==best}}
        }
        return pool[Int(mix(seed) % UInt64(pool.count))]
    }
    /// How one calibration game ended, from the level's side.
    public struct Game:Equatable {
        public var winner:String?,plies:Int,adjudicated:Bool
        /// The level's decisions, and how many of them the deadline cut; with `compareUntimed`, how many chose another
        /// move than the untimed search would have.
        public var decisions=0,deadlineCuts=0,changedByDeadline=0
        public init(winner:String?,plies:Int,adjudicated:Bool){self.winner=winner;self.plies=plies;self.adjudicated=adjudicated}
        public func points(for side:String,draw:Double)->Double {winner==nil ? draw:winner==side ? 1:0}
    }
    /// Plays one game of `kind` from its initial position. The level's moves come from the mini-game search at `seed`
    /// plus the ply, as the app seeds a run's replies; with `timeLimited` its production deadline applies, and
    /// `compareUntimed` also runs the reproducible search on each position to count changed choices.
    public static func play(_ kind:MiniGameKind,white:Player,black:Player,seed:UInt64,maximumPlies:Int,timeLimited:Bool=false,compareUntimed:Bool=false)->Game {
        var state=MiniGameState(kind:kind,computer:false),game=Game(winner:nil,plies:0,adjudicated:false)
        while !state.isFinished {
            guard game.plies<maximumPlies else{game.adjudicated=true;break}
            let player=state.turn=="w" ? white:black,moveSeed=seed &+ UInt64(game.plies+1)
            let move:MiniGameMove?
            if case .level(let profile)=player {
                let decision=MiniGameOpponent.decide(in:state,profile:profile,seed:moveSeed,timeLimited:timeLimited)
                game.decisions+=1;if decision.deadlineCut{game.deadlineCuts+=1}
                if compareUntimed,MiniGameOpponent.decide(in:state,profile:profile,seed:moveSeed,timeLimited:false).move != decision.move{game.changedByDeadline+=1}
                move=decision.move
            } else {move=referenceMove(player,in:state,seed:moveSeed ^ 0x5eed)}
            guard let chosen=move,state.play(chosen) else{preconditionFailure("\(kind.rawValue): no legal move chosen in an unfinished game")}
            game.plies+=1
        }
        game.winner=state.winner;return game
    }

    // MARK: Results and verdicts

    /// One side's games of a pairing, counted from the level's side.
    public struct Tally:Codable,Equatable {
        public var games=0,wins=0,draws=0,losses=0,adjudicated=0,plies=0
        public init(){}
        public mutating func add(_ game:Game,side:String){games+=1;plies+=game.plies;if game.adjudicated{adjudicated+=1};if game.winner==nil{draws+=1}else if game.winner==side{wins+=1}else{losses+=1}}
        public static func +(a:Self,b:Self)->Self {var t=a;t.games+=b.games;t.wins+=b.wins;t.draws+=b.draws;t.losses+=b.losses;t.adjudicated+=b.adjudicated;t.plies+=b.plies;return t}
        public func score(draw:Double)->Double {games==0 ? 0:(Double(wins)+draw*Double(draws))/Double(games)}
    }
    public struct Pairing:Codable,Equatable {
        public var level:String,reference:String,asWhite:Tally,asBlack:Tally
        public init(level:String,reference:String,asWhite:Tally,asBlack:Tally){self.level=level;self.reference=reference;self.asWhite=asWhite;self.asBlack=asBlack}
        public var total:Tally {asWhite+asBlack}
    }
    public struct EntryResult:Codable,Equatable {
        public var game:String,pairings:[Pairing]
        /// The search policy each level played with; a result stops describing the search once a profile is retuned.
        public var policies:[String:MiniOpponentPolicy]
        public init(game:String,pairings:[Pairing],policies:[String:MiniOpponentPolicy]){self.game=game;self.pairings=pairings;self.policies=policies}
    }
    public struct PairVerdict:Codable,Equatable {
        /// Scores against the pass rule's reference (greedy), and branch (a)'s two tests on them.
        public var lower:String,higher:String,lowerScore:Double,higherScore:Double,lowerInterval:[Double],higherInterval:[Double],differs:Bool,separated:Bool
        /// Branch (b): whether greedy is saturated for the lower level, and the higher level's score against it head-to-head.
        public var saturated:Bool,headToHeadScore:Double,headToHeadInterval:[Double],headToHeadSeparated:Bool
        public var passedAgainstReference:Bool {differs && separated}
        public var passedHeadToHead:Bool {saturated && headToHeadSeparated}
        public var passed:Bool {passedAgainstReference || passedHeadToHead}
    }
    public struct Verdict:Codable,Equatable {
        public var game:String,pairs:[PairVerdict],referenceScoreAgainstGentle:Double,gentleAccessible:Bool
        /// The levels the game offers, weakest first: always the fallback level, Gentle when its pair with Steady passes
        /// and it is accessible, Strong when its pair with Steady passes.
        public var offered:[String]
    }
    /// The pass rule for one adjacent pair, which passes by either branch:
    /// (a) against the rule's reference the higher level scores at least `minimumDifference` more, and the two intervals
    ///     are disjoint;
    /// (b) the reference is saturated for the lower level (it scores at least `headToHead.saturatedScore` against it),
    ///     and the higher level scores at least `headToHead.minimumScore` against the lower one head-to-head, with that
    ///     score's interval lower bound above `headToHead.lowerBoundAbove`.
    /// Branch (b) is the orchestrator's decision after the first full run (2026-10-18): Steady already scored 94% to
    /// 100% against greedy in every game, so greedy could not separate Steady from Strong and (a) alone withdrew Strong
    /// everywhere, although Strong beat Steady clearly head-to-head in some games. The plan's third reference, the next
    /// level down, decides once greedy has nothing left to measure; while greedy still discriminates, only (a) can pass.
    public static func pair(lower:String,_ lowerTally:Tally,higher:String,_ higherTally:Tally,headToHead:Tally,rule:PassRule,draw:Double)->PairVerdict {
        let a=lowerTally.score(draw:draw),b=higherTally.score(draw:draw),h=headToHead.score(draw:draw)
        let ia=wilson(score:a,games:lowerTally.games,confidence:rule.confidence),ib=wilson(score:b,games:higherTally.games,confidence:rule.confidence),ih=wilson(score:h,games:headToHead.games,confidence:rule.confidence)
        return PairVerdict(lower:lower,higher:higher,lowerScore:a,higherScore:b,lowerInterval:[ia.lowerBound,ia.upperBound],higherInterval:[ib.lowerBound,ib.upperBound],differs:b-a>=rule.minimumDifference-1e-9,separated:ia.upperBound<ib.lowerBound,
            saturated:a>=rule.headToHead.saturatedScore-1e-9,headToHeadScore:h,headToHeadInterval:[ih.lowerBound,ih.upperBound],headToHeadSeparated:h>=rule.headToHead.minimumScore-1e-9 && ih.lowerBound>rule.headToHead.lowerBoundAbove)
    }
    /// What a game's results allow it to offer under `manifest`. Fails loudly on results that do not answer the manifest.
    public static func verdict(_ result:EntryResult,manifest:Manifest)throws -> Verdict {
        struct Incomplete:Error,CustomStringConvertible {let description:String}
        guard let entry=manifest.entries.first(where:{$0.game==result.game}) else{throw Incomplete(description:"\(result.game) is not in the manifest")}
        func tally(_ level:String,_ reference:String)throws -> Tally {
            guard let pairing=result.pairings.first(where:{$0.level==level && $0.reference==reference}),pairing.asWhite.games==manifest.gamesPerPairing/2,pairing.asBlack.games==manifest.gamesPerPairing/2
            else{throw Incomplete(description:"\(result.game): \(level) against \(reference) is missing or incomplete")}
            return pairing.total
        }
        let rule=manifest.passRule,levels=manifest.levels
        let pairs=try zip(levels,levels.dropFirst()).map{try pair(lower:$0,tally($0,rule.reference),higher:$1,tally($1,rule.reference),headToHead:tally($1,"level-below"),rule:rule,draw:manifest.drawScore)}
        let against=1-(try tally(levels[0],entry.accessibility.reference)).score(draw:manifest.drawScore)
        let accessible=against>=entry.accessibility.minimumReferenceScore-1e-9
        let fallback=MiniGameOffering.fallbackLevel,middle=levels.firstIndex(of:fallback)!
        var offered=[fallback]
        if pairs[middle-1].passed,accessible{offered.insert(levels[middle-1],at:0)}
        if pairs[middle].passed{offered.append(levels[middle+1])}
        return Verdict(game:result.game,pairs:pairs,referenceScoreAgainstGentle:against,gentleAccessible:accessible,offered:offered)
    }
    /// The published results file, as the harness writes it. `manifest` is the manifest it played, which must equal
    /// the tracked one for the results to count.
    public struct Results:Codable {
        public var manifest:Manifest,entries:[EntryResult],verdicts:[Verdict]
        public var smoke:Bool
    }
}
