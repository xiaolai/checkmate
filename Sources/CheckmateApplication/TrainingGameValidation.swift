import CheckmateAssets
import CheckmateDomain
import CheckmateRules
/// Starts for playable games (plan: Finish the Game, guided games): legal and nonterminal. An ending starts with the
/// learner to move: exactly king and queen or king and rook against a lone king, halfmove clock 0, the mating piece
/// safe. A guided game may start with the opponent's move (Black from the initial setup).
@MainActor enum TrainingGameValidation {
    static func validate(_ scenario:TrainingScenario,runtimeFactory:(() throws -> any ChessScriptRuntime)?)throws {
        func fail(_ reason:String)throws -> Never {throw CheckmateError.invalid(String(localized:"Training scenario \(scenario.id): \(reason)",bundle:.checkmate))}
        guard let fen=scenario.fen,scenario.nodes==nil,scenario.choices==nil,scenario.noAction != true else{try fail(String(localized:"a game start is a position only",bundle:.checkmate))}
        let legality=try TrainingLegality(fen:fen,prelude:scenario.prelude ?? [],runtimeFactory:runtimeFactory)
        guard try !legality.outcomes().isEmpty,try legality.automaticDraw()==nil,try legality.turn()==scenario.learner || scenario.check == .guidedGame else{try fail(String(localized:"the learner must be to move in a game that is not over",bundle:.checkmate))}
        let board=try legality.board(),learner=Character(scenario.learner)
        switch scenario.check {
        case .ending:
            guard (scenario.prelude ?? []).isEmpty,fen.split(separator:" ").dropFirst(4).first=="0" else{try fail(String(localized:"an ending starts from its position with the halfmove clock at 0",bundle:.checkmate))}
            let piece=scenario.variant=="kqk" ? "q":"r"
            let mine=board.filter{$0.value.first==learner}.map{String($0.value.last!)}.sorted(),theirs=board.filter{$0.value.first != learner}.map(\.value)
            guard mine==["k",piece].sorted(),theirs.count==1 else{try fail("a \(scenario.variant) ending is king and \(piece == "q" ? "queen":"rook") against a lone king")}
            guard let square=board.first(where:{$0.value==scenario.learner+piece})?.key,let king=board.first(where:{$0.value.first != learner})?.key else{try fail("missing pieces")}
            if TrainingGeometry.attacks(from:king,board:board).contains(square),TrainingGeometry.defenders(of:square,board:board).isEmpty{try fail(String(localized:"the mating piece must not be capturable",bundle:.checkmate))}
        case .guidedGame:
            guard scenario.workflow=="guided-game" else{try fail(String(localized:"a guided game belongs to the guided-game workflow",bundle:.checkmate))}
            guard try legality.status() == .neither else{try fail(String(localized:"a guided game starts quietly, not in check",bundle:.checkmate))}
        // A position game (mini-game plan D3): every piece type it keeps is the learner's at the start, and a pawn race
        // has exactly one learner pawn, the one followed until it promotes.
        case .positionGame:
            guard let goal=scenario.goal?.kind,goal.positionGame else{try fail(String(localized:"a position game names its goal",bundle:.checkmate))}
            let mine=board.values.filter{$0.first==learner}
            guard (scenario.keep ?? []).allSatisfy({kept in mine.contains{String($0.last!)==kept}}) else{try fail(String(localized:"a position game keeps only piece types the learner has",bundle:.checkmate))}
            if goal == .promoteAndHold{guard mine.filter({$0.last=="p"}).count==1 else{try fail(String(localized:"a pawn race starts with exactly one learner pawn",bundle:.checkmate))}}
        default:try fail(String(localized:"not a game objective",bundle:.checkmate))
        }
    }
}
