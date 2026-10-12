import CheckmateDomain
import CheckmateRules
/// Starts for playable games (plan: Finish the Game, guided games): legal and nonterminal. An ending starts with the
/// learner to move: exactly king and queen or king and rook against a lone king, halfmove clock 0, the mating piece
/// safe. A guided game may start with the opponent's move (Black from the initial setup).
@MainActor enum TrainingGameValidation {
    static func validate(_ scenario:TrainingScenario,runtimeFactory:(() throws -> any ChessScriptRuntime)?)throws {
        func fail(_ reason:String)throws -> Never {throw CheckmateError.invalid("Training scenario \(scenario.id): \(reason)")}
        guard let fen=scenario.fen,scenario.nodes==nil,scenario.choices==nil,scenario.noAction != true else{try fail("a game start is a position only")}
        let legality=try TrainingLegality(fen:fen,prelude:scenario.prelude ?? [],runtimeFactory:runtimeFactory)
        guard try !legality.outcomes().isEmpty,try legality.automaticDraw()==nil,try legality.turn()==scenario.learner || scenario.check == .guidedGame else{try fail("the learner must be to move in a game that is not over")}
        let board=try legality.board(),learner=Character(scenario.learner)
        switch scenario.check {
        case .ending:
            guard (scenario.prelude ?? []).isEmpty,fen.split(separator:" ").dropFirst(4).first=="0" else{try fail("an ending starts from its position with the halfmove clock at 0")}
            let piece=scenario.variant=="kqk" ? "q":"r"
            let mine=board.filter{$0.value.first==learner}.map{String($0.value.last!)}.sorted(),theirs=board.filter{$0.value.first != learner}.map(\.value)
            guard mine==["k",piece].sorted(),theirs.count==1 else{try fail("a \(scenario.variant) ending is king and \(piece == "q" ? "queen":"rook") against a lone king")}
            guard let square=board.first(where:{$0.value==scenario.learner+piece})?.key,let king=board.first(where:{$0.value.first != learner})?.key else{try fail("missing pieces")}
            if TrainingGeometry.attacks(from:king,board:board).contains(square),TrainingGeometry.defenders(of:square,board:board).isEmpty{try fail("the mating piece must not be capturable")}
        case .guidedGame:
            guard scenario.workflow=="guided-game" else{try fail("a guided game belongs to the guided-game workflow")}
            guard try legality.status() == .neither else{try fail("a guided game starts quietly, not in check")}
        default:try fail("not a game objective")
        }
    }
}
