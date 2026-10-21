import Foundation

/// Which mini-games let the learner play Black against the computer (L-23). A game qualifies when its start is the
/// same for both sides (each half is the other's turned through 180 degrees with colours swapped) and calibration found
/// every level it offers equally strong from either side: in each of that level's pairings, its score as White and as
/// Black (`Content/calibration/mini-game-results.json`, which plays every level from both sides) differ by at most
/// `tolerance`. So the offered levels describe the opponent whichever side the learner takes, and no new calibration is
/// needed. A unit test keeps `offered` equal to what the published results allow.
public enum MiniGameSides {
    public static let tolerance=0.15
    static let offered:Set<MiniGameKind>=[.pawnDuel,.rookSweep,.rooksAndPawns,.bishopSweep,.bishopsAndPawns]
    public static func offersChoice(_ kind:MiniGameKind)->Bool {offered.contains(kind)}
    /// Whether each side's half of the start is the other's turned through 180 degrees with colours swapped.
    public static func symmetricStart(_ kind:MiniGameKind)->Bool {
        let board=kind.initialBoard
        func turned(_ square:String)->String {String(Character(UnicodeScalar(UInt8(201)-square.utf8.first!)))+String(9-Int(square.suffix(1))!)}
        return !kind.solo && board.allSatisfy{square,piece in board[turned(square)]==(piece.hasPrefix("w") ? "b":"w")+piece.suffix(1)}
    }
    /// The games the published results allow: a symmetric start, and every pairing of every offered level within
    /// `tolerance` between its two sides.
    public static func allowed(by results:MiniGameCalibration.Results)->Set<MiniGameKind> {
        Set(results.entries.compactMap{entry in
            guard let kind=MiniGameKind(rawValue:entry.game),symmetricStart(kind),let offered=results.verdicts.first(where:{$0.game==entry.game})?.offered else{return nil}
            let gaps=entry.pairings.filter{offered.contains($0.level)}.map{abs($0.asWhite.score(draw:0.5)-$0.asBlack.score(draw:0.5))}
            return !gaps.isEmpty && gaps.allSatisfy{$0<=tolerance} ? kind:nil
        })
    }
    /// Takes back the learner's last move and the computer's reply. From White this is the game's own `undo`; from
    /// Black it goes back to the latest position with Black to move, before the learner's move. With nothing of the
    /// learner's to take back, it returns to the start and the computer plays its opening move again.
    public static func undo(_ game:inout MiniGameState,learner:String) {
        guard learner=="b",game.computer else{game.undo();return}
        guard let previous=game.history.popLast() else{return}
        game.snapshot=previous;if game.turn=="w",let blackTurn=game.history.popLast(){game.snapshot=blackTurn}
    }
}

/// The learner's side in one run of a mini-game against the computer: the run's identity (`MiniGameState.run`) and
/// `w` or `b`. A record of another run is ignored, so a restart by an older build never inherits it.
public struct MiniGameRunSide:Codable,Equatable {
    public var run:String,side:String
    public init(run:String,side:String){self.run=run;self.side=side}
    var valid:Bool {["w","b"].contains(side) && (1...64).contains(run.count)}
}

/// Games against the computer at one level, counted from the learner's side.
public struct MiniGameTally:Codable,Equatable {
    public var wins=0,draws=0,losses=0
    public init(wins:Int=0,draws:Int=0,losses:Int=0){self.wins=wins;self.draws=draws;self.losses=losses}
    private enum CodingKeys:String,CodingKey {case wins,draws,losses}
    /// A count that is missing reads as none; one that is negative or not a whole number fails, so damage is never
    /// counted over.
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        func count(_ key:CodingKeys)throws -> Int {let n=try c.decodeIfPresent(Int.self,forKey:key) ?? 0;guard (0...TrainingState.maximumCount).contains(n) else{throw DecodingError.dataCorruptedError(forKey:key,in:c,debugDescription:"A mini-game count is out of range.")};return n}
        wins=try count(.wins);draws=try count(.draws);losses=try count(.losses)
    }
}

/// A step the learner's results suggest for the next game (L-24): never applied without the learner choosing it.
public enum MiniGameLevelAdvice:Equatable {case stepUp(to:String),stepDown(to:String)}

/// The learner's record in one mini-game against the computer (L-24), and the side of the run in progress (L-23).
/// Saved under `miniGameRecords` by kind; every field is optional in the save, so a record written by this build and
/// read by a later one (or the reverse) keeps what each knows.
public struct MiniGameRecord:Codable,Equatable {
    /// Results by the level each run was frozen at (`MiniGameState.runLevel`).
    public var levels:[String:MiniGameTally]=[:]
    /// The latest results in a row at one level, newest last, `w`, `d` or `l`; a result at another level starts it again.
    public var streak:String=""
    public var streakLevel:String?
    /// The run already counted: undoing and replaying a finished run never counts it twice; a restart is a new run.
    public var creditedRun:String?
    public var side:MiniGameRunSide?
    public init(){}
    /// How many results in a row at one level suggest a step: three wins up, three losses down.
    public static let streakLength=3
    private enum CodingKeys:String,CodingKey {case levels,streak,streakLevel,creditedRun,side}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        levels=try c.decodeIfPresent([String:MiniGameTally].self,forKey:.levels) ?? [:]
        let streak=try c.decodeIfPresent(String.self,forKey:.streak) ?? ""
        guard streak.count<=Self.streakLength,streak.allSatisfy({"wdl".contains($0)}) else{throw DecodingError.dataCorruptedError(forKey:.streak,in:c,debugDescription:"A mini-game streak is damaged.")}
        self.streak=streak;streakLevel=try c.decodeIfPresent(String.self,forKey:.streakLevel);creditedRun=try c.decodeIfPresent(String.self,forKey:.creditedRun)
        // A side this build cannot use reads as none: the run is then played from White, as before sides existed.
        side=try c.decodeIfPresent(MiniGameRunSide.self,forKey:.side).flatMap{$0.valid ? $0:nil}
    }
    /// The learner's side in `game`: the stored side of this run, else White.
    public func side(of game:MiniGameState)->String {side.flatMap{$0.run==game.run ? $0.side:nil} ?? "w"}
    /// Settles the side of the run being opened: a run keeps its stored side; a run without one takes `preferred` when
    /// no move has been played, else White, the only side earlier builds played. Only a game that offers the choice,
    /// against the computer, can be played from Black.
    public mutating func settleSide(of game:MiniGameState,preferred:String) {
        guard side?.run != game.run else{return}
        let chosen=game.computer && MiniGameSides.offersChoice(game.kind) && game.history.isEmpty && preferred=="b" ? "b":"w"
        side=MiniGameRunSide(run:game.run,side:chosen)
    }
    /// Counts a finished run against the computer once, at its level, from the learner's side. Returns whether it counted.
    @discardableResult public mutating func count(_ game:MiniGameState)->Bool {
        guard game.computer,!game.kind.solo,game.isFinished,let level=game.runLevel?.profile,creditedRun != game.run else{return false}
        let learner=side(of:game),result=game.winner.map{$0==learner ? "w":"l"} ?? "d"
        var tally=levels[level] ?? MiniGameTally()
        switch result {case "w":tally.wins+=1;case "l":tally.losses+=1;default:tally.draws+=1}
        levels[level]=tally;creditedRun=game.run
        streak=(streakLevel==level ? streak:"")+result;streak=String(streak.suffix(Self.streakLength));streakLevel=level
        return true
    }
    /// The step the latest results suggest for a game whose next run plays `level`, among `offered` (weakest first):
    /// up after `streakLength` wins in a row at that level when a stronger one is offered, down after as many losses
    /// when a weaker one is. Results at another level, or a mixed run of results, suggest nothing.
    public func advice(level:String,offered:[String])->MiniGameLevelAdvice? {
        guard streakLevel==level,streak.count==Self.streakLength,let index=offered.firstIndex(of:level) else{return nil}
        if streak.allSatisfy({$0=="w"}),index+1<offered.count{return .stepUp(to:offered[index+1])}
        if streak.allSatisfy({$0=="l"}),index>0{return .stepDown(to:offered[index-1])}
        return nil
    }
}
