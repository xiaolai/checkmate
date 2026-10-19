import Foundation

/// Calibration of the opponent levels of standard-rule training games (mini-game plan D4, WI-020): the harness's second
/// entry kind, `standard`, beside the simplified mini-games (`MiniGameCalibration`). It has its own manifest
/// (`Content/calibration/position-game-manifest.json`) and results, so each result set's recorded identity covers only
/// what decides it: editing a Stockfish entry never voids the simplified games' run, nor the reverse. The manifest fixes
/// the entries, their starts, sides, references, sample size, scoring and accessibility before any game;
/// `Tools/PositionGameCalibration` plays it with the bundled Stockfish on the test host and writes
/// `Content/calibration/position-game-results.json`, from which `verdict` derives the levels each entry offers.
/// `MiniGameOffering.positionGames` holds them, and a unit test keeps the two equal.
///
/// The levels are an attempt's frozen opponents (`TrainingOpponentConfiguration.frozen`), every search node-limited.
/// Gentle and Strong are reproducible move for move; Steady is Stockfish below skill 20, which draws on its own unseeded
/// randomness, so the results record the engine's identity, options and node limits and report intervals.
public enum PositionGameCalibration {
    public static let kind="standard"
    public static let levels=TrainingOpponentLevel.allCases.map(\.rawValue)
    public static let references=["random","greedy","level-below"]
    /// The files, relative to the package root, whose contents decide a calibration game or its verdict: the referee and
    /// the level constants, the opponent strategy and the beginner opponent, the analysis options, the match, this file,
    /// the shared statistics and the harness. The harness records their SHA-256 beside the manifest's, and a unit test
    /// re-hashes them, so results of older sources fail. The engine binary is recorded by its identity.
    public static let sourceFiles=["Sources/CheckmateDomain/PositionGames.swift","Sources/CheckmateDomain/PositionGameCalibration.swift","Sources/CheckmateDomain/MiniGameCalibration.swift",
        "Sources/CheckmateDomain/BeginnerPolicy.swift","Sources/CheckmateDomain/OpponentPolicy.swift","Sources/CheckmateApplication/TrainingOpponent.swift","Sources/CheckmateApplication/BeginnerOpponent.swift",
        "Sources/CheckmateApplication/PositionGameMatch.swift","Tools/PositionGameCalibration/main.swift"]
    /// One side of a calibration game: an opponent level, or a reference player.
    public enum Player:Equatable {
        case level(TrainingOpponentLevel),random,greedy
        public init?(reference:String,below level:TrainingOpponentLevel) {
            switch reference {
            case "random":self = .random
            case "greedy":self = .greedy
            case "level-below":
                guard let index=TrainingOpponentLevel.allCases.firstIndex(of:level),index>0 else{return nil};self = .level(TrainingOpponentLevel.allCases[index-1])
            default:return nil
            }
        }
    }

    // MARK: Manifest

    /// How a game is scored from the level's side. `chess` (a start both sides could stand in): a win is a point and a
    /// draw half of one. `goal` (the learner has the material and a goal, the level only defends): the learner's side
    /// scores a point when the referee's row is a success and nothing otherwise, because the app counts a draw as a
    /// failed goal (plan D3); the level scores the rest.
    public enum Scoring:String,Codable {case chess,goal}
    /// A start: a published scenario and its FEN, which a unit test keeps equal to the published one.
    public struct Start:Codable,Equatable {public var scenario:String,fen:String}
    public struct Entry:Codable,Equatable {
        public var kind:String,entry:String,variant:String,check:TrainingCheck,learner:String
        /// Game `index` of a pairing (within its side's share) starts from `starts[index % starts.count]`.
        public var starts:[Start]
        /// The colours the level plays, each in an equal share of a pairing's games: both where either side could be the
        /// opponent, else only the opponent's colour (the level never plays the learner's material in the app).
        public var sides:[String]
        public var references:[String],scoring:Scoring,accessibility:MiniGameCalibration.Accessibility
        public var key:String {PositionGameCalibration.key(entry:entry,variant:variant)}
    }
    /// The levels as the app plays them; a retuned level fails the validator, so it must be calibrated again.
    public struct Opponent:Codable,Equatable {
        public var policyVersion:Int,gentleSearchNodes:Int,gentleDecisionNodes:Int,engineNodes:Int,steadySkill:Int,strongSkill:Int
        public static var current:Self {Self(policyVersion:TrainingOpponentPolicy.version,gentleSearchNodes:TrainingOpponentPolicy.gentleSearchNodes,gentleDecisionNodes:TrainingOpponentPolicy.gentleDecisionNodes,
            engineNodes:TrainingOpponentPolicy.engineNodes,steadySkill:TrainingOpponentPolicy.skill(.steady) ?? -1,strongSkill:TrainingOpponentPolicy.skill(.strong) ?? -1)}
    }
    public struct Manifest:Codable,Equatable {
        public var schema:Int,levels:[String],references:[String]
        /// Games per pairing, split evenly between the sides an entry lists.
        public var gamesPerPairing:Int,drawScore:Double
        /// A game still running after this many plies is stopped and scored as a draw (chess) or a failed goal (goal),
        /// and counted as adjudicated.
        public var maximumPlies:Int
        /// Every game's seeds derive from this one, its entry, pairing and index (`seed(_:_:_:_:)`).
        public var seed:String
        public var passRule:MiniGameCalibration.PassRule,opponent:Opponent,entries:[Entry]
    }
    public static func key(entry:String,variant:String)->String {entry+"/"+variant}
    /// The fewest games per pairing (an even number) at which a level scoring exactly the head-to-head branch's minimum
    /// passes it: the sample the pass rule needs to be decidable at its own thresholds. At this size branch (a) still
    /// needs more than ten points of difference in mid-range scores (`MiniGameCalibration.requiredGames` is the size at
    /// which ten always suffice); fewer games only ever make a pass harder, never easier.
    public static func requiredGames(_ rule:MiniGameCalibration.HeadToHeadRule,confidence:Double)->Int {
        var n=2
        while n<100_000,MiniGameCalibration.wilson(score:rule.minimumScore,games:n,confidence:confidence).lowerBound<=rule.lowerBoundAbove{n+=2}
        return n
    }
    /// The least difference between two scores that always separates their intervals at `games` per pairing.
    public static func separatingDifference(games:Int,confidence:Double)->Double {
        var d=0.0
        while d<1,!stride(from:0.0,through:1-d,by:0.001).allSatisfy({p in
            MiniGameCalibration.wilson(score:p,games:games,confidence:confidence).upperBound<MiniGameCalibration.wilson(score:min(1,p+d),games:games,confidence:confidence).lowerBound}){d+=0.005}
        return d
    }
    /// Everything wrong with `manifest`, empty when it may be played. Checked before any game. The starts' FENs are
    /// compared with the published scenarios by a unit test, which has the rules to read them.
    public static func problems(_ manifest:Manifest)->[String] {
        var found:[String]=[]
        func require(_ condition:Bool,_ message:String){if !condition{found.append(message)}}
        require(manifest.schema==1,"schema must be 1")
        require(manifest.levels==levels,"levels must be \(levels), weakest first")
        require(manifest.references==references,"references must be \(references)")
        require(manifest.drawScore==0.5,"a draw scores half a point")
        require((100...2000).contains(manifest.maximumPlies),"maximumPlies must be 100...2000")
        require(UInt64(manifest.seed,radix:16) != nil,"seed must be hexadecimal")
        let rule=manifest.passRule
        require(rule.reference=="greedy","the pass rule plays greedy")
        require(rule.minimumDifference==0.10,"the pass rule needs at least 10 points of difference")
        require(rule.confidence==0.95,"the pass rule uses 95% Wilson intervals")
        require(rule.headToHead==MiniGameCalibration.HeadToHeadRule(saturatedScore:0.90,minimumScore:0.60,lowerBoundAbove:0.50),"the head-to-head branch needs greedy saturated at 90%, then at least 60% against the level below with the lower bound above 50%")
        require(manifest.opponent==Opponent.current,"the opponent must be the levels as the app plays them: \(Opponent.current)")
        let needed=requiredGames(rule.headToHead,confidence:rule.confidence)
        require(manifest.gamesPerPairing>=needed,"gamesPerPairing \(manifest.gamesPerPairing) is below the \(needed) games at which a level scoring \(Int(rule.headToHead.minimumScore*100))% head-to-head can pass")
        require(manifest.gamesPerPairing%2==0,"gamesPerPairing must split evenly between two sides")
        require(!manifest.entries.isEmpty,"the manifest names its entries")
        require(Set(manifest.entries.map(\.key)).count==manifest.entries.count,"each entry and variant appears once")
        for entry in manifest.entries {
            let name=entry.key,opponent=entry.learner=="w" ? "b":"w"
            require(entry.kind==kind,"\(name): entry kind \(entry.kind) is not \(kind)")
            require([.positionGame,.ending].contains(entry.check),"\(name): only position games and endings are calibrated here")
            require(entry.learner=="w" || entry.learner=="b","\(name): the learner is w or b")
            require(!entry.starts.isEmpty && Set(entry.starts.map(\.scenario)).count==entry.starts.count,"\(name): the starts are distinct published scenarios")
            require(entry.starts.allSatisfy{$0.fen.split(separator:" ").count==6 && $0.fen.split(separator:" ")[1]==Substring(entry.learner)},"\(name): every start is a full FEN with the learner to move")
            require(entry.sides==["w","b"] || entry.sides==[opponent],"\(name): the level plays both sides, or only the opponent's")
            let symmetric=entry.sides.count==2
            require(entry.references==(symmetric ? references:["random","greedy"]),"\(name): \(symmetric ? "a start for either side plays every reference":"a level only defends, so it has no head-to-head with the level below as the learner's side")")
            require(entry.scoring==(symmetric ? .chess:.goal),"\(name): \(symmetric ? "both sides play for checkmate, so it is scored as chess":"the learner plays for a goal, so it is scored by the goal")")
            require(["random","greedy"].contains(entry.accessibility.reference),"\(name): accessibility is measured against a fixed reference")
            require(entry.accessibility.minimumReferenceScore>0 && entry.accessibility.minimumReferenceScore<1,"\(name): accessibility threshold must be inside (0, 1)")
        }
        return found
    }
    /// The pairings every level of `entry` plays, in order: each of the entry's references the level has.
    public static func pairings(_ manifest:Manifest,_ entry:Entry)->[(level:TrainingOpponentLevel,reference:String)] {
        TrainingOpponentLevel.allCases.flatMap{level in entry.references.filter{Player(reference:$0,below:level) != nil}.map{(level,$0)}}
    }
    /// SplitMix64 of a hash of the entry, pairing and index: the seed of one game, its reference's and its levels'.
    public static func seed(_ manifestSeed:UInt64,_ key:String,_ pairing:String,_ index:Int)->UInt64 {
        var hash:UInt64=0xcbf29ce484222325;for byte in "\(key)|\(pairing)|\(index)".utf8{hash=(hash ^ UInt64(byte)) &* 0x100000001b3}
        var random=TrainingRandom(seed:manifestSeed ^ hash);return random.next()
    }
    /// The side that scored a game, nil for a draw: the referee's row (nil when the ply cap stopped it), read by `scoring`.
    public static func winner(_ row:PositionGameRow?,learner:String,scoring:Scoring)->String? {
        let opponent=learner=="w" ? "b":"w"
        guard let row else{return scoring == .goal ? opponent:nil}
        if row.success{return learner}
        switch (scoring,row) {
        case (.chess,.stalemate),(.chess,.automaticDraw),(.chess,.claimedDraw):return nil
        default:return opponent
        }
    }

    // MARK: Results and verdicts

    public struct EntryResult:Codable,Equatable {
        public var entry:String,variant:String,pairings:[MiniGameCalibration.Pairing]
        public init(entry:String,variant:String,pairings:[MiniGameCalibration.Pairing]){self.entry=entry;self.variant=variant;self.pairings=pairings}
        public var key:String {PositionGameCalibration.key(entry:entry,variant:variant)}
    }
    public struct Verdict:Codable,Equatable {
        /// The adjacent level pairs, Gentle-Steady and Steady-Strong.
        public var entry:String,variant:String,pairs:[MiniGameCalibration.PairVerdict],referenceScoreAgainstGentle:Double,gentleAccessible:Bool
        /// The comparisons that decided the offering, in the order they were made (`verdict`).
        public var decisions:[MiniGameCalibration.PairVerdict]
        /// The levels the entry offers, weakest first: its fallback, and each other level that passes against the
        /// nearest level already offered on the fallback's side of it (Gentle also needs to be accessible).
        public var offered:[String]
    }
    /// What an entry's results allow it to offer under `manifest`. Fails loudly on results that do not answer it.
    public static func verdict(_ result:EntryResult,manifest:Manifest)throws -> Verdict {
        struct Incomplete:Error,CustomStringConvertible {let description:String}
        guard let entry=manifest.entries.first(where:{$0.key==result.key}) else{throw Incomplete(description:"\(result.key) is not in the manifest")}
        let share=manifest.gamesPerPairing/entry.sides.count
        func tally(_ level:TrainingOpponentLevel,_ reference:String)throws -> MiniGameCalibration.Tally {
            guard entry.references.contains(reference) else{return MiniGameCalibration.Tally()}
            guard let pairing=result.pairings.first(where:{$0.level==level.rawValue && $0.reference==reference}),
                  pairing.asWhite.games==(entry.sides.contains("w") ? share:0),pairing.asBlack.games==(entry.sides.contains("b") ? share:0)
            else{throw Incomplete(description:"\(result.key): \(level.rawValue) against \(reference) is missing or incomplete")}
            return pairing.total
        }
        // Every pairing the manifest names is complete, those the verdict does not read (random) included.
        for pairing in pairings(manifest,entry){_ = try tally(pairing.level,pairing.reference)}
        let rule=manifest.passRule,all=TrainingOpponentLevel.allCases
        // A pair without a head-to-head (a level that only defends) has an empty tally: its interval is all of [0, 1],
        // so branch (b) cannot pass and only branch (a) decides.
        let pairs=try zip(all,all.dropFirst()).map{try MiniGameCalibration.pair(lower:$0.rawValue,tally($0,rule.reference),higher:$1.rawValue,tally($1,rule.reference),headToHead:tally($1,"level-below"),rule:rule,draw:manifest.drawScore)}
        let against=1-(try tally(.gentle,entry.accessibility.reference)).score(draw:manifest.drawScore)
        let accessible=against>=entry.accessibility.minimumReferenceScore-1e-9
        // Outward from the fallback, each level is compared with the nearest level already offered on the fallback's
        // side, so every two neighbouring offered levels are separated by a measured comparison. Branch (a) compares
        // their scores against greedy, so it holds for any two levels; branch (b) needs their head-to-head games, which
        // only adjacent levels play (the level below), so a level two steps away is decided by (a) alone. A level that
        // fails is not offered, and the next one out is compared with the same offered level.
        let fallback=MiniGameOffering.fallbackLevel(for:entry.check),start=all.firstIndex(of:fallback)!
        var offered=[fallback],decisions:[MiniGameCalibration.PairVerdict]=[]
        func compare(_ lower:TrainingOpponentLevel,_ higher:TrainingOpponentLevel)throws -> MiniGameCalibration.PairVerdict {
            let adjacent=all.firstIndex(of:higher)!-all.firstIndex(of:lower)!==1
            let verdict=MiniGameCalibration.pair(lower:lower.rawValue,try tally(lower,rule.reference),higher:higher.rawValue,try tally(higher,rule.reference),headToHead:adjacent ? try tally(higher,"level-below"):MiniGameCalibration.Tally(),rule:rule,draw:manifest.drawScore)
            decisions.append(verdict);return verdict
        }
        for level in all[..<start].reversed() {if try compare(level,offered[0]).passed,level != .gentle || accessible{offered.insert(level,at:0)}}
        for level in all[(start+1)...] {if try compare(offered.last!,level).passed{offered.append(level)}}
        return Verdict(entry:result.entry,variant:result.variant,pairs:pairs,referenceScoreAgainstGentle:against,gentleAccessible:accessible,decisions:decisions,offered:offered.map(\.rawValue))
    }
    /// The published results file, as the harness writes it (the fields a verdict needs). `manifest` is the manifest it
    /// played, which must equal the tracked one for the results to count.
    public struct Results:Codable {
        public struct Identity:Codable {public var engine:String,engineName:String,options:[String:String],sourceSHA256:[String:String]}
        public var manifest:Manifest,entries:[EntryResult],verdicts:[Verdict],smoke:Bool,identity:Identity
    }
}
