import CheckmateDomain
import CheckmateRules
/// The resolved result of a stated exchange line, as a three-way choice.
public enum TrainingExchangeResult:Int,CaseIterable {
    case behind = -1,even = 0,ahead = 1
    public var label:String {switch self{case .ahead:return "You come out ahead";case .even:return "It is an even trade";case .behind:return "You come out behind"}}
    public static let choices=[ahead,even,behind].map(\.label)
}
/// What needs attention in an unlabelled position (plan: Mixed Practice diagnosis). Several can be genuine; any
/// genuine one is accepted, and "Nothing urgent" only when none is.
public enum TrainingConcern:String,CaseIterable {
    case mate,mateThreat,winMaterial,danger,none
    public var label:String {switch self {
        case .mate:return "You can give checkmate now"
        case .mateThreat:return "Your opponent threatens checkmate"
        case .winMaterial:return "You can win material"
        case .danger:return "One of your pieces is in danger"
        case .none:return "Nothing urgent"
    }}
    public static let choices=allCases.map(\.label)
}
extension TrainingValidationService {
    /// Increment B: the scenario's evaluator re-derives every answer. Cheap rule checks run whenever a scenario is
    /// prepared; `deep` adds the bounded searches, run offline over the published corpus (plan rule 7).
    static func validateBeginner(_ scenario:TrainingScenario,definition:TrainingEntryDefinition,runtimeFactory:(() throws -> any ChessScriptRuntime)?,deep:Bool)throws {
        func fail(_ reason:String)throws -> Never {throw CheckmateError.invalid("Training scenario \(scenario.id): \(reason)")}
        guard let check=scenario.check,let fen=scenario.fen else{try fail("missing evaluator or position")}
        if check.task == .game{try TrainingGameValidation.validate(scenario,runtimeFactory:runtimeFactory);return}
        let legality=try TrainingLegality(fen:fen,prelude:scenario.prelude ?? [],runtimeFactory:runtimeFactory)
        guard try legality.turn()==scenario.learner else{try fail("the learner must be the side to move")}
        let board=try legality.board(),outcomes=try legality.outcomes(),legal=Set(outcomes.map(\.uci)),expected=scenario.expected ?? TrainingExpected(),noAction=scenario.noAction==true
        if check.searched || check == .exchange{guard board.values.filter({$0.last != "k"}).count<=8 else{try fail("more than eight pieces besides the kings")}}
        let root=scenario.nodes?.first
        if let root {
            guard try legality.fingerprint()==root.fingerprint else{try fail("the root fingerprint differs from the presented position")}
            guard Set(root.accepted).isSubset(of:legal),Set(root.replies.keys).isSubset(of:legal) else{try fail("the teaching graph names an illegal root move")}
        }
        let accepted=Set(root?.accepted ?? []),captures=Set(outcomes.filter{$0.captured != nil}.map(\.uci))
        let validator=deep ? try TrainingContinuationValidator(runtimeFactory:runtimeFactory):nil
        func requireNoAction(_ value:Bool)throws {guard noAction==value else{try fail(value ? "this no-action case must be marked noAction":"only a case where acting is wrong is marked noAction")}}
        func simple(_ answer:Set<String>,_ what:String)throws {
            guard !answer.isEmpty,accepted==answer,root?.accepted.count==answer.count else{try fail("accepted \(what) differ from the rules: \(answer.sorted())")}
            guard root?.replies.isEmpty==true,scenario.nodes?.count==1 else{try fail("a one-move rule task shows no reply")}
        }
        switch check {
        case .defense:
            guard let target=scenario.goal?.target,board[target]?.first==Character(scenario.learner),board[target]?.last != "k" else{try fail("the target must be one of the learner's pieces, not the king")}
            guard !accepted.isEmpty else{try fail("at least one move must save the piece")}
            guard let wrong=expected.wrong,!wrong.isEmpty,Set(wrong).isSubset(of:legal),Set(wrong).isDisjoint(with:accepted) else{try fail("name at least one plausible passive move that fails")}
            try requireNoAction(false)
            let learner=Character(scenario.learner)
            let tags=outcomes.filter{accepted.contains($0.uci)}.map{outcome in TrainingMaterial.defenseTags(before:board,after:TrainingMaterial.board(fen:outcome.after) ?? [:],from:outcome.from,to:outcome.to,target:target,learner:learner)}
            let shared=tags.dropFirst().reduce(tags.first ?? []){$0.intersection($1)}
            let methods:[String:TrainingMaterial.DefenseMethod]=["move-away":.moveAway,"protect":.protect,"capture-attacker":.captureAttacker,"block":.block]
            if let method=methods[scenario.variant]{guard shared.contains(method) else{try fail("not every saving move uses \(method.rawValue); classify it as mixed-method")}}
            else{guard shared.subtracting([.other]).isEmpty else{try fail("every saving move shares one method; classify it under that method")}}
            try validator?.certifyGraph(scenario,runtimeFactory:runtimeFactory)
        case .material:
            let acceptedCaptures=accepted.intersection(captures)
            if noAction{guard acceptedCaptures.isEmpty,!captures.isEmpty else{try fail("a declined-capture case has a legal capture and accepts none")}}
            switch (definition.objective,scenario.variant) {
            case (.captureWisely,"free-piece"):guard !acceptedCaptures.isEmpty,scenario.goal?.kind == .gain else{try fail("a free piece is won by a capture")};try requireNoAction(false)
            case (.captureWisely,_):
                guard let wrong=expected.wrong,!wrong.isEmpty,Set(wrong).isSubset(of:captures),Set(wrong).isDisjoint(with:accepted) else{try fail("name the tempting capture that fails")}
                // A tempting capture exists, so the case is a declined capture exactly when no capture is accepted.
                try requireNoAction(acceptedCaptures.isEmpty)
            case (.simpleTactics,"fork-realize"):
                guard outcomes.contains(where:{accepted.contains($0.uci) && TrainingRelationship.forked(by:$0.to,board:TrainingMaterial.board(fen:$0.after) ?? [:]).count>=2}) else{try fail("no accepted move makes a fork")}
                try requireNoAction(false)
            case (.simpleTactics,_):
                let opponent:Character=scenario.learner=="w" ? "b":"w",pinned=TrainingRelationship.pinned(color:opponent,board:board)
                guard outcomes.contains(where:{outcome in accepted.contains(outcome.uci) && (pinned.contains(outcome.to) || !TrainingRelationship.pinned(color:opponent,board:TrainingMaterial.board(fen:outcome.after) ?? [:]).subtracting(pinned).isEmpty)}) else{try fail("no accepted move makes or uses a pin")}
                try requireNoAction(false)
            default:break
            }
            guard !accepted.isEmpty else{try fail("a material task needs at least one move that meets its goal")}
            try validator?.certifyGraph(scenario,runtimeFactory:runtimeFactory)
        case .diagnosis:
            guard scenario.choices==TrainingConcern.choices,let genuine=expected.choices,!genuine.isEmpty,Set(genuine).isSubset(of:TrainingConcern.choices) else{try fail("a diagnosis offers every concern and names the genuine ones")}
            try requireNoAction(false)
            if let validator {
                guard let found=try concerns(scenario,legality:legality,validator:validator) else{try fail("a diagnosis position has the learner out of check")}
                guard Set(genuine)==Set(found.map(\.label)) else{try fail("the genuine concerns differ: \(found.map(\.rawValue).sorted())")}
                try validator.certifyGraph(scenario,runtimeFactory:runtimeFactory)
            }
        case .exchange:
            guard scenario.choices==TrainingExchangeResult.choices,let stated=scenario.stated,!stated.isEmpty,let choice=expected.choice,TrainingExchangeResult.choices.contains(choice) else{try fail("an exchange question states its line and offers the three results")}
            _ = try TrainingLegality(fen:fen,prelude:(scenario.prelude ?? [])+stated,runtimeFactory:runtimeFactory)
            guard captures.contains(stated[0]) else{try fail("the stated line starts with the learner's capture")}
            try requireNoAction(false)
            if let validator{guard TrainingExchangeResult(rawValue:try validator.exchangeSign(scenario))?.label==choice else{try fail("the exchange result differs from the oracle")}}
        case .castle:
            try simple(try TrainingSpecialRules.castlingMoves(legality),"castling moves");try requireNoAction(false)
            guard let wrong=expected.wrong,!wrong.isEmpty else{try fail("include a plausible illegal castling attempt")}
            for attempt in wrong {
                // A castling attempt: the king two files along its rank, or onto its own rook.
                let from=String(attempt.prefix(2)),to=String(attempt.dropFirst(2).prefix(2))
                guard board[from]==scenario.learner+"k",let (fx,fy)=TrainingGeometry.coordinates(from),let (tx,ty)=TrainingGeometry.coordinates(to),fy==ty,abs(fx-tx)==2 || board[to]==scenario.learner+"r" else{try fail("\(attempt) is not a castling attempt")}
                guard case .ruleError=try legality.grade(from:from,to:to,promotion:nil,castling:true) else{try fail("\(attempt) is not graded as a rule error")}
            }
        case .promotion:try simple(try TrainingSpecialRules.promotions(legality),"promotions");try requireNoAction(false)
        case .enPassant:
            try simple(try TrainingSpecialRules.enPassantMoves(legality),"en-passant captures");try requireNoAction(false)
            guard let last=scenario.prelude?.last,let (_,from)=TrainingGeometry.coordinates(String(last.prefix(2))),let (_,to)=TrainingGeometry.coordinates(String(last.dropFirst(2).prefix(2))),abs(from-to)==2 else{try fail("the context moves must end with the pawn's two-square step")}
        case .castleReason:
            guard scenario.choices==TrainingCastleReason.choices,let destination=scenario.target else{try fail("a castling question names the king's square and offers every reason")}
            let reasons=try TrainingSpecialRules.castleReasons(legality,destination:destination)
            guard reasons.count==1,let reason=reasons.first,reason.label==expected.choice else{try fail("castling has \(reasons.map(\.rawValue).sorted()); curate exactly the oracle's one reason")}
            try requireNoAction(reason != .allowed)
            if reason == .moved{guard try showsCastlerMoving(scenario,fen:fen,destination:destination,runtimeFactory:runtimeFactory) else{try fail("the context moves must show the king or rook moving")}}
        case .enPassantChoice:
            guard scenario.choices==TrainingPassantReason.choices,let target=scenario.target else{try fail("an en-passant question names the pawn and offers every reason")}
            let reasons=try TrainingSpecialRules.passantReasons(legality,target:target,prelude:scenario.prelude ?? [])
            guard reasons.count==1,let reason=reasons.first,reason.label==expected.choice else{try fail("en passant has \(reasons.map(\.rawValue).sorted()); curate exactly the oracle's one reason")}
            try requireNoAction(reason != .allowed)
        case .forks,.pins:
            let color=Character(scenario.askColor ?? "w")
            let answer=check == .forks ? TrainingRelationship.forks(by:color,board:board):TrainingRelationship.pinned(color:color,board:board)
            guard let squares=expected.squares,Set(squares)==answer,squares.count==answer.count else{try fail("the answer set differs from the geometry: \(answer.sorted())")}
            try requireNoAction(answer.isEmpty)
        case .kingSquares:_ = try validateKingSquares(legality,expected:expected,fail:fail);try requireNoAction(false)
        case .status:
            guard scenario.choices==TrainingStatus.choices,expected.choice==(try legality.status()).label else{try fail("the classification differs from the oracle")}
            try requireNoAction(false)
        case .mateThreatCreate,.mateThreatPrevent:
            guard !accepted.isEmpty,accepted.count<legal.count else{try fail("some moves must succeed and some must fail")}
            guard scenario.nodes?.count==1 else{try fail("a mate-threat task is one decision")}
            try requireNoAction(false)
            if check == .mateThreatCreate{guard try legality.matingMoves().isEmpty else{try fail("with a mate in one available this is a mate-in-one task")}}
            if let validator {
                let found=try validator.threat(scenario,create:check == .mateThreatCreate)
                guard Set(found.accepted)==accepted,root?.replies==found.replies else{try fail("mate-threat answers differ from the exact one-reply query: \(found.accepted)")}
                if check == .mateThreatPrevent{guard found.opponentThreat else{try fail("the opponent must threaten mate now")}}
            }
        case .ending,.guidedGame:break
        case .moment:
            // Re-derived exactly, cheaply enough to run whenever a moment is staged or resumed.
            guard let root,scenario.nodes?.count==1,!accepted.isEmpty,accepted.count<legal.count else{try fail("a moment is one decision with some moves right and some wrong")}
            try requireNoAction(false)
            switch scenario.variant {
            case "mate-find":guard accepted==(try legality.matingMoves()),root.replies.isEmpty else{try fail("the accepted moves are exactly the checkmates")}
            case "mate-avoid":
                let found=try (validator ?? TrainingContinuationValidator(runtimeFactory:runtimeFactory)).threat(scenario,create:false)
                // The learner's own move created the threat, so none need exist yet; the answers are re-derived exactly.
                guard Set(found.accepted)==accepted,root.replies==found.replies else{try fail("the accepted moves are exactly those that allow no mate in one")}
            default:try fail("unknown moment")
            }
        }
    }
    /// The concerns genuinely present in a diagnosis position, re-derived by the bounded searches; nil when the
    /// learner is in check, which a diagnosis position never is.
    private static func concerns(_ scenario:TrainingScenario,legality:TrainingLegality,validator:TrainingContinuationValidator)throws -> Set<TrainingConcern>? {
        var found=Set<TrainingConcern>()
        if !(try legality.matingMoves()).isEmpty{found.insert(.mate)}
        if try validator.threat(scenario,create:false).opponentThreat{found.insert(.mateThreat)}
        if !(try validator.classify(scenario.with(goal:TrainingGoal(kind:.gain,threshold:1)),plies:3)).accepted.isEmpty{found.insert(.winMaterial)}
        guard let danger=try validator.danger(scenario) else{return nil}
        if danger{found.insert(.danger)}
        return found.isEmpty ? [.none]:found
    }
    /// Whether a context move takes the learner's king, or the rook on `destination`'s side, off its home square:
    /// each candidate is checked against the piece actually standing there before it moves, not just its origin.
    private static func showsCastlerMoving(_ scenario:TrainingScenario,fen:String,destination:String,runtimeFactory:(() throws -> any ChessScriptRuntime)?)throws -> Bool {
        let rank=scenario.learner=="w" ? "1":"8",prelude=scenario.prelude ?? []
        let homes=["e"+rank:scenario.learner+"k",(destination.first=="g" ? "h":"a")+rank:scenario.learner+"r"]
        return try prelude.indices.contains{index in
            let from=String(prelude[index].prefix(2))
            guard let piece=homes[from] else{return false}
            return try TrainingLegality(fen:fen,prelude:Array(prelude[..<index]),runtimeFactory:runtimeFactory).board()[from]==piece
        }
    }
}
extension TrainingScenario {
    /// The same scenario judged against another goal (a diagnosis asks whether material can be won at all).
    func with(goal:TrainingGoal)->TrainingScenario {
        TrainingScenario(id:id,entry:entry,variant:variant,tier:tier,cluster:cluster,learner:learner,prompt:prompt,explanation:explanation,hints:hints,fen:fen,prelude:prelude,diagram:diagram,target:target,drill:drill,budget:budget,shortest:shortest,choices:choices,expected:expected,noAction:noAction,reserve:reserve,review:review,generation:generation,check:check,goal:goal,plies:plies,nodes:nodes,stated:stated,askColor:askColor,focus:focus,skills:skills,primarySkill:primarySkill,source:source,bridge:bridge,workflow:workflow)
    }
}
