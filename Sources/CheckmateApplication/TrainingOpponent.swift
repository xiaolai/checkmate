import CheckmateDomain
import CheckmateRules
import Foundation
/// How a standard-rule training game's opponent chooses its reply (mini-game plan D4), from the attempt's frozen
/// configuration. Gentle is the regret-bounded beginner opponent; Steady and Strong are one engine search at their
/// skill; an attempt saved before levels existed keeps the search it began with. Every level's search is node-limited.
@MainActor public enum OpponentStrategy:Equatable {
    /// Gentle: `BeginnerOpponent`, each search `searchNodes`, the decision at most `decisionNodes`.
    case beginner(searchNodes:Int,decisionNodes:Int)
    /// One search with `profile` and `limit`.
    case engine(OpponentProfile,limit:EngineSearchLimit)
    /// The strategy `configuration` names. A legacy attempt plays today's search for its scenario's evaluator.
    public init(_ configuration:TrainingOpponentConfiguration,check:TrainingCheck?){
        switch (configuration.strategy,configuration.limit) {
        case (.beginner,.nodes(let nodes)):self = .beginner(searchNodes:nodes,decisionNodes:nodes*(1+BeginnerPolicy.explorationCount))
        case (.engine,_):self = .engine(.skill(configuration.level.flatMap(TrainingOpponentPolicy.skill) ?? 20),limit:configuration.limit)
        default:self = .legacy(check)
        }
    }
    /// Today's search, for an attempt with no level: the coded profile for 300 ms.
    public static func legacy(_ check:TrainingCheck?)->Self {.engine(TrainingEndgameController.profile(for:check),limit:.movetime(TrainingEndgameController.budget))}
    /// The reply to the position reached from `startFEN` by `moves`. Gentle's `seed` and `severeStreak` make its
    /// choice repeatable and continue its run of severe mistakes; its decision says how that run continues.
    /// Checks `fairness` before searching; the beginner opponent checks again before each further search.
    func choose(startFEN:String,moves:[String],engine:any EngineService,seed:UInt64,severeStreak:Int,fairness:FairnessPolicy,runtimeFactory:(() throws -> any ChessScriptRuntime)?)async throws -> EngineAnalysis {
        try fairness.requireEngineHelp()
        switch self {
        case .beginner(let searchNodes,let decisionNodes):
            let rules=try runtimeFactory.map{try ChessRules(fen:startFEN,runtimeFactory:$0)} ?? ChessRules(fen:startFEN);for move in moves{try rules.move(uci:move)}
            return try await BeginnerOpponent.choose(rules:rules,engine:engine,seed:seed,severeStreak:severeStreak,fairness:fairness,limit:.nodes(searchNodes),decisionNodes:decisionNodes)
        case .engine(let profile,let limit):
            return try await engine.analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,limit:limit,multiPv:1,searchMoves:[])
        }
    }
}
extension TrainingController {
    // MARK: Opponent level (mini-game plan D4)
    /// The opponent a new attempt at `scenario` freezes: the level the learner prefers for its entry, as offered. None
    /// while position games are off, so nothing new is written, nor for exercises that are not games.
    func frozenOpponent(_ scenario:TrainingScenario,attempt:String)->TrainingOpponentConfiguration? {
        guard TrainingRolloutPolicy.positionGamesEnabled,scenario.check?.task == .game else{return nil}
        return .frozen(MiniGameOffering.level(entry:scenario.entry,variant:scenario.variant,check:scenario.check,settings:session.state.settings),attempt:attempt,seed:seed())
    }
    /// The levels the game shown offers, weakest first; a picker shows only when there are several.
    public func gameLevels(_ exercise:Exercise)->[TrainingOpponentLevel] {exercise.task == .game ? MiniGameOffering.levels(entry:exercise.definition.id,variant:exercise.scenario.variant,check:exercise.scenario.check):[]}
    /// The level the learner prefers for the game shown, as offered: the one its next attempt freezes.
    public func preferredGameLevel(_ exercise:Exercise)->TrainingOpponentLevel {MiniGameOffering.level(entry:exercise.definition.id,variant:exercise.scenario.variant,check:exercise.scenario.check,settings:session.state.settings)}
    /// Whether the unfinished game in progress plays at another level than the one chosen. It keeps its level, and the
    /// panel offers a new game at the chosen one.
    public func gameNewLevelOffered(_ exercise:Exercise)->Bool {
        guard exercise.task == .game,!exercise.finished,!exercise.line.isEmpty,let frozen=exercise.snapshot.opponent?.level else{return false}
        return frozen != preferredGameLevel(exercise)
    }
    /// Chooses the level of this entry's next games. A game with no move yet takes it now, losing nothing; a game in
    /// progress keeps its own (`gameNewLevelOffered`).
    public func setGameLevel(_ level:TrainingOpponentLevel){
        guard TrainingRolloutPolicy.positionGamesEnabled,interactive,var state=exercise,gameLevels(state).contains(level) else{return}
        // The picker and the new-game offer read the setting, which this controller does not publish: a game in
        // progress changes nothing else, so announce the change or the panel keeps showing the old level.
        objectWillChange.send()
        var settings=session.state.settings;settings.positionGameLevels=(settings.positionGameLevels ?? [:]).merging([state.definition.id:level.rawValue]){$1};session.updateSettings(settings)
        guard !state.finished,state.line.isEmpty,state.snapshot.opponent?.level != level,let frozen=frozenOpponent(state.scenario,attempt:state.snapshot.id) else{return}
        games.cancel();state.snapshot.opponent=frozen
        if save(state){requestReply()}
    }
    /// A new game on the same board at the chosen level; the one in progress is recorded as abandoned.
    public func startGameAtChosenLevel(){
        guard interactive,let state=exercise,state.task == .game,!state.finished else{return}
        do {
            try TrainingValidationService.validate(state.scenario,definition:state.definition,runtimeFactory:runtimeFactory)
            begin(PreparedTrainingExercise(definition:state.definition,scenario:state.scenario,freshness:TrainingFreshness(rawValue:state.snapshot.freshness) ?? .new,legality:try state.scenario.fen.map{try TrainingLegality(fen:$0,prelude:state.scenario.prelude ?? [],runtimeFactory:runtimeFactory)},resumed:nil,retry:state.snapshot.retry))
        }catch{refuse(userFacing(error))}
    }
}
