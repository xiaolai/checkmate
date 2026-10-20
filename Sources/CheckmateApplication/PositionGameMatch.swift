import CheckmateDomain
import CheckmateRules
import Foundation
/// One calibration game of a standard-rule training entry (mini-game plan D4, WI-020). A level plays exactly as an
/// attempt's frozen opponent plays it: `OpponentStrategy` from `TrainingOpponentConfiguration.frozen`, its seed advanced
/// by the ply as `requestReply` advances it, and Gentle's run of severe mistakes carried from one reply to the next.
/// Reference players stand in for the learner or for the opponent. The game ends at the first row of the closed outcome
/// matrix (`PositionGameReferee`), judged on the same facts a training game is judged on, or at the ply cap. Nobody
/// claims a draw: the opponent never does, and a reference has no reason to.
@MainActor public enum PositionGameMatch {
    public enum Player {
        /// An opponent level searching with `engine`; `seed` is its frozen configuration's.
        case level(TrainingOpponentLevel,engine:any EngineService,seed:UInt64)
        /// Uniformly among the legal moves.
        case random(seed:UInt64)
        /// The capture of the most valuable piece it can take (ties at random), else a random move.
        case greedy(seed:UInt64)
    }
    public struct Outcome:Equatable {
        /// The row that ended the game, or nil when the ply cap stopped it.
        public let row:PositionGameRow?
        public let line:[String]
        public var plies:Int {line.count}
    }
    /// The goal and kept pieces a scenario's game is judged by: a position game's own; an ending's as WI-017 restated it,
    /// checkmate keeping the mating piece, which its recorded regression shows ends every ending as the ending's own
    /// evaluator does; a guided game is ordinary chess, so it is judged by checkmate and keeps nothing.
    public static func rules(of scenario:TrainingScenario)throws -> (goal:TrainingGoal.Kind,keep:[String]) {
        switch scenario.check {
        case .positionGame?:
            guard let goal=scenario.goal?.kind,goal.positionGame else{throw CheckmateError.invalid("A position game names its goal.")}
            return (goal,scenario.keep ?? [])
        case .ending?:return (.checkmate,[scenario.variant=="krk" ? "r":"q"])
        case .guidedGame?:return (.checkmate,[])
        default:throw CheckmateError.invalid("Only position games, endings and guided games are calibrated.")
        }
    }
    /// Plays one game from `start` (learner to move) between `white` and `black`.
    public static func play(start:String,goal:TrainingGoal.Kind,keep:[String],learner:String,white:Player,black:Player,maximumPlies:Int)async throws -> Outcome {
        let rules=try ChessRules(fen:start)
        var line:[String]=[],streaks=["w":0,"b":0],pawn:PositionGamePawn?
        if goal == .promoteAndHold {
            guard let square=try rules.currentBoard().first(where:{$0.value==learner+"p"})?.key else{throw CheckmateError.invalid("A pawn race needs its pawn.")}
            pawn = .pawn(square)
        }
        while line.count<maximumPlies {
            let mover=try rules.currentTurn(),outcomes=try rules.moveOutcomes()
            guard !outcomes.isEmpty else{throw CheckmateError.invalid("The referee let a game go on with no legal move.")}
            let chosen:MoveOutcome
            switch mover=="w" ? white:black {
            case .level(let level,let engine,let seed):
                let configuration=TrainingOpponentConfiguration.frozen(level,attempt:"calibration",seed:seed),streak=streaks[mover] ?? 0
                let result=try await OpponentStrategy(configuration,check:.positionGame).choose(startFEN:start,moves:line,engine:engine,seed:seed &+ UInt64(line.count+1),severeStreak:streak,fairness:FairnessPolicy(),runtimeFactory:nil)
                if configuration.strategy == .beginner{streaks[mover]=BeginnerOpponent.nextSevereStreak(result,mover:mover,current:streak)}
                guard let move=result.bestMove,let outcome=outcomes.first(where:{$0.uci==move}) else{throw CheckmateError.invalid("The \(level.title) level returned no legal move.")}
                chosen=outcome
            case .random(let seed):chosen=reference(outcomes,greedy:false,seed:seed &+ UInt64(line.count+1))
            case .greedy(let seed):chosen=reference(outcomes,greedy:true,seed:seed &+ UInt64(line.count+1))
            }
            try rules.move(uci:chosen.uci);line.append(chosen.uci)
            pawn=pawn?.after(chosen,learner:learner)
            if let row=PositionGameReferee.judge(goal:goal,keep:keep,learner:learner,mover:mover,checkmate:chosen.checkmate,stalemate:chosen.stalemate,automaticDraw:try rules.automaticDrawReason(),board:try rules.currentBoard(),pawn:pawn) {
                return Outcome(row:row,line:line)
            }
        }
        return Outcome(row:nil,line:line)
    }
    /// A reference player's move among `outcomes`, which are never empty.
    static func reference(_ outcomes:[MoveOutcome],greedy:Bool,seed:UInt64)->MoveOutcome {
        var pool=outcomes
        if greedy {
            let gain={(move:MoveOutcome) in move.captured.map(TrainingMaterial.value) ?? 0},best=outcomes.map(gain).max() ?? 0
            if best>0{pool=outcomes.filter{gain($0)==best}}
        }
        var random=TrainingRandom(seed:seed);return random.pick(pool)
    }
}
