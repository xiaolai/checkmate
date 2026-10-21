import CheckmateAssets
import CheckmateDomain
import CheckmateRules
/// Re-derives every accepted answer with the exact evaluators and rejects a scenario whose authored oracle differs
/// (plan rule 4). Used offline by the content tests and at runtime before a curated scenario is shown.
@MainActor public enum TrainingValidationService {
    /// Must equal `VALIDATOR_VERSION` in Tools/prepare-training-content.py; bumped whenever accepted answers can change.
    public static let validatorVersion=1
    /// `deep` adds Increment B's bounded searches, which run offline over the published corpus, not when a
    /// scenario is prepared (plan rule 7).
    public static func validate(_ scenario:TrainingScenario,definition:TrainingEntryDefinition,runtimeFactory:(() throws -> any ChessScriptRuntime)?=nil,deep:Bool=false)throws {
        try scenario.validateStructure(for:definition)
        func fail(_ reason:String)throws -> Never {throw CheckmateError.invalid(String(localized:"Training scenario \(scenario.id): \(reason)",bundle:.checkmate))}
        if let review=scenario.review,review.validatorVersion != validatorVersion{try fail(String(localized:"validated by validator \(review.validatorVersion), current is \(validatorVersion)",bundle:.checkmate))}
        let expected=scenario.expected ?? TrainingExpected()
        switch definition.objective {
        case .reachTarget:try validateDrill(scenario,expected:expected,fail:fail)
        case .findAttackers,.findDefenders:try validateRecognition(scenario,objective:definition.objective,expected:expected,fail:fail)
        case .mateInOne,.escapeCheck,.kingSafeSquares,.classifyStatus:try validatePosition(scenario,objective:definition.objective,expected:expected,runtimeFactory:runtimeFactory,fail:fail)
        case .legacyGame:try fail(String(localized:"existing games have no scenarios",bundle:.checkmate))
        case .saveYourPiece,.captureWisely,.specialMoves,.simpleTactics,.finishTheGame,.mixedPractice,.guidedGame,.positionGame:
            try validateBeginner(scenario,definition:definition,runtimeFactory:runtimeFactory,deep:deep)
        }
    }
    /// A movement drill's route. The drill's encoding (pieces, squares, an empty start, the budget) is structural.
    private static func validateDrill(_ scenario:TrainingScenario,expected:TrainingExpected,fail:(String)throws -> Never)throws {
        guard let drill=scenario.drill,let budget=scenario.budget,drill.start != drill.target,drill.pieces[drill.target].map({$0.first != drill.color}) ?? true else{try fail("invalid drill")}
        guard let distance=drill.distance(from:drill.initial),distance==expected.distance else{try fail(String(localized:"the shortest route differs from the oracle",bundle:.checkmate))}
        guard budget>=distance,scenario.shortest != true || budget==distance else{try fail(String(localized:"the move budget cannot be met, or a shortest-route task allows slack",bundle:.checkmate))}
    }
    /// Attackers or defenders of the marked square on a diagram.
    private static func validateRecognition(_ scenario:TrainingScenario,objective:TrainingObjectiveKind,expected:TrainingExpected,fail:(String)throws -> Never)throws {
        guard let diagram=scenario.diagram,let target=scenario.target else{try fail("missing diagram")}
        let color=Character(scenario.learner)
        let answer=objective == .findDefenders ? TrainingGeometry.defenders(of:target,board:diagram):TrainingGeometry.attackers(of:target,color:color,board:diagram)
        if objective == .findDefenders{guard let occupant=diagram[target],occupant.first==color,occupant.last != "k" else{try fail(String(localized:"the marked square must hold one of the asked side's pieces, not its king",bundle:.checkmate))}}
        else{guard diagram[target].map({$0.first != color}) ?? true else{try fail(String(localized:"an attacked square cannot hold the asked side's own piece",bundle:.checkmate))}}
        guard let squares=expected.squares,Set(squares)==answer,squares.count==answer.count else{try fail(String(localized:"the answer set differs from the oracle",bundle:.checkmate))}
    }
    /// Increment A's standard-chess positions: mates, evasions, king squares and the status classification.
    private static func validatePosition(_ scenario:TrainingScenario,objective:TrainingObjectiveKind,expected:TrainingExpected,runtimeFactory:(() throws -> any ChessScriptRuntime)?,fail:(String)throws -> Never)throws {
        guard let fen=scenario.fen else{try fail("missing FEN")}
        let legality=try TrainingLegality(fen:fen,prelude:scenario.prelude ?? [],runtimeFactory:runtimeFactory)
        guard try legality.turn()==scenario.learner else{try fail(String(localized:"the learner must be the side to move",bundle:.checkmate))}
        switch objective {
        case .mateInOne:
            let mates=try legality.matingMoves(),all=try legality.outcomes()
            guard !mates.isEmpty,all.count>mates.count else{try fail(String(localized:"needs a legal mate and a legal non-mating move",bundle:.checkmate))}
            guard Set(expected.moves ?? [])==mates else{try fail(String(localized:"accepted mates differ from the oracle: \(String(describing:mates.sorted()))",bundle:.checkmate))}
        case .escapeCheck:
            guard try legality.status() == .check else{try fail(String(localized:"the side to move must be in check and able to escape",bundle:.checkmate))}
            guard Set(expected.moves ?? [])==Set(try legality.outcomes().map(\.uci)) else{try fail(String(localized:"accepted evasions differ from the oracle",bundle:.checkmate))}
            guard let wrong=expected.wrong,!wrong.isEmpty else{try fail(String(localized:"include at least one plausible illegal attempt",bundle:.checkmate))}
            for attempt in wrong {
                let grade=try legality.grade(from:String(attempt.prefix(2)),to:String(attempt.dropFirst(2).prefix(2)),promotion:attempt.count==5 ? String(attempt.suffix(1)):nil)
                guard case .ruleError=grade else{try fail(String(localized:"\(attempt) is not graded as a rule error",bundle:.checkmate))}
            }
        case .kingSafeSquares:
            let answer=try validateKingSquares(legality,expected:expected,fail:fail),board=try legality.board()
            guard let king=board.first(where:{$0.value==scenario.learner+"k"})?.key else{try fail("no king")}
            let neighbours=TrainingGeometry.attacks(from:king,board:board).filter{board[$0]?.first.map(String.init) != scenario.learner}
            guard !neighbours.subtracting(answer).isEmpty else{try fail(String(localized:"include at least one plausible but unsafe square",bundle:.checkmate))}
        default:
            guard scenario.choices==TrainingStatus.choices else{try fail(String(localized:"classification offers exactly the four labels",bundle:.checkmate))}
            guard expected.choice==(try legality.status()).label else{try fail(String(localized:"the classification differs from the oracle",bundle:.checkmate))}
        }
    }
    /// King-move questions (both increments): no castling rights, and the answer is exactly the king's legal
    /// destinations. Returns those destinations.
    static func validateKingSquares(_ legality:TrainingLegality,expected:TrainingExpected,fail:(String)throws -> Never)throws -> Set<String> {
        guard legality.fen.split(separator:" ")[2]=="-" else{try fail("king-move questions have no castling rights")}
        let answer=try legality.kingDestinations()
        guard let squares=expected.squares,Set(squares)==answer else{try fail(String(localized:"king destinations differ from the oracle: \(String(describing:answer.sorted()))",bundle:.checkmate))}
        return answer
    }
}
