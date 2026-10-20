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
        let c=BeginnerContext(scenario:scenario,definition:definition,runtimeFactory:runtimeFactory,check:check,fen:fen,legality:legality,board:board,outcomes:outcomes,legal:legal,expected:expected,noAction:noAction,root:root,accepted:accepted,captures:captures,validator:validator,fail:fail)
        switch check {
        case .defense:try validateDefense(c)
        case .material:try validateMaterial(c)
        case .diagnosis:try validateDiagnosis(c)
        case .exchange:try validateExchange(c)
        case .castle:try validateCastle(c)
        case .promotion:try c.simple(try TrainingSpecialRules.promotions(legality),"promotions");try c.requireNoAction(false)
        case .enPassant:try validateEnPassant(c)
        case .castleReason:try validateCastleReason(c)
        case .enPassantChoice:try validateEnPassantChoice(c)
        case .forks,.pins:try validateRelationship(c)
        case .kingSquares:_ = try validateKingSquares(legality,expected:expected,fail:fail);try c.requireNoAction(false)
        case .status:try validateStatus(c)
        case .mateThreatCreate,.mateThreatPrevent:try validateMateThreat(c)
        case .ending,.guidedGame,.positionGame:break
        case .moment:try validateMoment(c)
        }
    }
    /// What every beginner task check shares, derived once by `validateBeginner` (in its original order, so an
    /// injected runtime failure surfaces from the same query) before it dispatches on the task.
    private struct BeginnerContext {
        let scenario:TrainingScenario,definition:TrainingEntryDefinition,runtimeFactory:(() throws -> any ChessScriptRuntime)?
        let check:TrainingCheck,fen:String,legality:TrainingLegality
        /// The presented position and its legal moves.
        let board:Position,outcomes:[MoveOutcome],legal:Set<String>
        let expected:TrainingExpected,noAction:Bool
        /// The teaching graph's root, the moves it accepts, and the legal captures from the presented position.
        let root:TrainingTeachingNode?,accepted:Set<String>,captures:Set<String>
        /// Present only on the deep (certification) path.
        let validator:TrainingContinuationValidator?
        /// Rejects the scenario, naming it.
        let fail:(String)throws -> Never
        func requireNoAction(_ value:Bool)throws {guard noAction==value else{try fail(value ? "this no-action case must be marked noAction":"only a case where acting is wrong is marked noAction")}}
        /// A one-move rule task: the accepted moves are exactly `answer`, and no reply is shown.
        func simple(_ answer:Set<String>,_ what:String)throws {
            guard !answer.isEmpty,accepted==answer,root?.accepted.count==answer.count else{try fail("accepted \(what) differ from the rules: \(answer.sorted())")}
            guard root?.replies.isEmpty==true,scenario.nodes?.count==1 else{try fail("a one-move rule task shows no reply")}
        }
    }
    private static func validateDefense(_ c:BeginnerContext)throws {
        let scenario=c.scenario,board=c.board,accepted=c.accepted
        guard let target=scenario.goal?.target,board[target]?.first==Character(scenario.learner),board[target]?.last != "k" else{try c.fail("the target must be one of the learner's pieces, not the king")}
        guard !accepted.isEmpty else{try c.fail("at least one move must save the piece")}
        guard let wrong=c.expected.wrong,!wrong.isEmpty,Set(wrong).isSubset(of:c.legal),Set(wrong).isDisjoint(with:accepted) else{try c.fail("name at least one plausible passive move that fails")}
        try c.requireNoAction(false)
        let learner=Character(scenario.learner)
        let tags=c.outcomes.filter{accepted.contains($0.uci)}.map{outcome in TrainingMaterial.defenseTags(before:board,after:TrainingMaterial.board(fen:outcome.after) ?? [:],from:outcome.from,to:outcome.to,target:target,learner:learner)}
        let shared=tags.dropFirst().reduce(tags.first ?? []){$0.intersection($1)}
        let methods:[String:TrainingMaterial.DefenseMethod]=["move-away":.moveAway,"protect":.protect,"capture-attacker":.captureAttacker,"block":.block]
        if let method=methods[scenario.variant]{guard shared.contains(method) else{try c.fail("not every saving move uses \(method.rawValue); classify it as mixed-method")}}
        else{guard shared.subtracting([.other]).isEmpty else{try c.fail("every saving move shares one method; classify it under that method")}}
        try c.validator?.certifyGraph(scenario,runtimeFactory:c.runtimeFactory)
    }
    private static func validateMaterial(_ c:BeginnerContext)throws {
        let scenario=c.scenario,accepted=c.accepted,captures=c.captures,outcomes=c.outcomes
        let acceptedCaptures=accepted.intersection(captures)
        if c.noAction{guard acceptedCaptures.isEmpty,!captures.isEmpty else{try c.fail("a declined-capture case has a legal capture and accepts none")}}
        switch (c.definition.objective,scenario.variant) {
        case (.captureWisely,"free-piece"):guard !acceptedCaptures.isEmpty,scenario.goal?.kind == .gain else{try c.fail("a free piece is won by a capture")};try c.requireNoAction(false)
        case (.captureWisely,_):
            guard let wrong=c.expected.wrong,!wrong.isEmpty,Set(wrong).isSubset(of:captures),Set(wrong).isDisjoint(with:accepted) else{try c.fail("name the tempting capture that fails")}
            // A tempting capture exists, so the case is a declined capture exactly when no capture is accepted.
            try c.requireNoAction(acceptedCaptures.isEmpty)
        case (.simpleTactics,"fork-realize"):
            guard outcomes.contains(where:{accepted.contains($0.uci) && TrainingRelationship.forked(by:$0.to,board:TrainingMaterial.board(fen:$0.after) ?? [:]).count>=2}) else{try c.fail("no accepted move makes a fork")}
            try c.requireNoAction(false)
        case (.simpleTactics,_):
            let opponent:Character=scenario.learner=="w" ? "b":"w",pinned=TrainingRelationship.pinned(color:opponent,board:c.board)
            guard outcomes.contains(where:{outcome in accepted.contains(outcome.uci) && (pinned.contains(outcome.to) || !TrainingRelationship.pinned(color:opponent,board:TrainingMaterial.board(fen:outcome.after) ?? [:]).subtracting(pinned).isEmpty)}) else{try c.fail("no accepted move makes or uses a pin")}
            try c.requireNoAction(false)
        default:break
        }
        guard !accepted.isEmpty else{try c.fail("a material task needs at least one move that meets its goal")}
        try c.validator?.certifyGraph(scenario,runtimeFactory:c.runtimeFactory)
    }
    private static func validateDiagnosis(_ c:BeginnerContext)throws {
        let scenario=c.scenario
        guard scenario.choices==TrainingConcern.choices,let genuine=c.expected.choices,!genuine.isEmpty,Set(genuine).isSubset(of:TrainingConcern.choices) else{try c.fail("a diagnosis offers every concern and names the genuine ones")}
        try c.requireNoAction(false)
        if let validator=c.validator {
            guard let found=try concerns(scenario,legality:c.legality,validator:validator) else{try c.fail("a diagnosis position has the learner out of check")}
            guard Set(genuine)==Set(found.map(\.label)) else{try c.fail("the genuine concerns differ: \(found.map(\.rawValue).sorted())")}
            try validator.certifyGraph(scenario,runtimeFactory:c.runtimeFactory)
        }
    }
    private static func validateExchange(_ c:BeginnerContext)throws {
        let scenario=c.scenario
        guard scenario.choices==TrainingExchangeResult.choices,let stated=scenario.stated,!stated.isEmpty,let choice=c.expected.choice,TrainingExchangeResult.choices.contains(choice) else{try c.fail("an exchange question states its line and offers the three results")}
        _ = try TrainingLegality(fen:c.fen,prelude:(scenario.prelude ?? [])+stated,runtimeFactory:c.runtimeFactory)
        guard c.captures.contains(stated[0]) else{try c.fail("the stated line starts with the learner's capture")}
        try c.requireNoAction(false)
        if let validator=c.validator{guard TrainingExchangeResult(rawValue:try validator.exchangeSign(scenario))?.label==choice else{try c.fail("the exchange result differs from the oracle")}}
    }
    private static func validateCastle(_ c:BeginnerContext)throws {
        let scenario=c.scenario,board=c.board
        try c.simple(try TrainingSpecialRules.castlingMoves(c.legality),"castling moves");try c.requireNoAction(false)
        guard let wrong=c.expected.wrong,!wrong.isEmpty else{try c.fail("include a plausible illegal castling attempt")}
        for attempt in wrong {
            // A castling attempt: the king two files along its rank, or onto its own rook.
            let from=String(attempt.prefix(2)),to=String(attempt.dropFirst(2).prefix(2))
            guard board[from]==scenario.learner+"k",let (fx,fy)=TrainingGeometry.coordinates(from),let (tx,ty)=TrainingGeometry.coordinates(to),fy==ty,abs(fx-tx)==2 || board[to]==scenario.learner+"r" else{try c.fail("\(attempt) is not a castling attempt")}
            guard case .ruleError=try c.legality.grade(from:from,to:to,promotion:nil,castling:true) else{try c.fail("\(attempt) is not graded as a rule error")}
        }
    }
    private static func validateEnPassant(_ c:BeginnerContext)throws {
        try c.simple(try TrainingSpecialRules.enPassantMoves(c.legality),"en-passant captures");try c.requireNoAction(false)
        guard let last=c.scenario.prelude?.last,let (_,from)=TrainingGeometry.coordinates(String(last.prefix(2))),let (_,to)=TrainingGeometry.coordinates(String(last.dropFirst(2).prefix(2))),abs(from-to)==2 else{try c.fail("the context moves must end with the pawn's two-square step")}
    }
    private static func validateCastleReason(_ c:BeginnerContext)throws {
        let scenario=c.scenario
        guard scenario.choices==TrainingCastleReason.choices,let destination=scenario.target else{try c.fail("a castling question names the king's square and offers every reason")}
        let reasons=try TrainingSpecialRules.castleReasons(c.legality,destination:destination)
        guard reasons.count==1,let reason=reasons.first,reason.label==c.expected.choice else{try c.fail("castling has \(reasons.map(\.rawValue).sorted()); curate exactly the oracle's one reason")}
        try c.requireNoAction(reason != .allowed)
        if reason == .moved{guard try showsCastlerMoving(scenario,fen:c.fen,destination:destination,runtimeFactory:c.runtimeFactory) else{try c.fail("the context moves must show the king or rook moving")}}
    }
    private static func validateEnPassantChoice(_ c:BeginnerContext)throws {
        let scenario=c.scenario
        guard scenario.choices==TrainingPassantReason.choices,let target=scenario.target else{try c.fail("an en-passant question names the pawn and offers every reason")}
        let reasons=try TrainingSpecialRules.passantReasons(c.legality,target:target,prelude:scenario.prelude ?? [])
        guard reasons.count==1,let reason=reasons.first,reason.label==c.expected.choice else{try c.fail("en passant has \(reasons.map(\.rawValue).sorted()); curate exactly the oracle's one reason")}
        try c.requireNoAction(reason != .allowed)
    }
    /// Forks or pins: the answer squares are exactly the geometry's.
    private static func validateRelationship(_ c:BeginnerContext)throws {
        let color=Character(c.scenario.askColor ?? "w")
        let answer=c.check == .forks ? TrainingRelationship.forks(by:color,board:c.board):TrainingRelationship.pinned(color:color,board:c.board)
        guard let squares=c.expected.squares,Set(squares)==answer,squares.count==answer.count else{try c.fail("the answer set differs from the geometry: \(answer.sorted())")}
        try c.requireNoAction(answer.isEmpty)
    }
    private static func validateStatus(_ c:BeginnerContext)throws {
        guard c.scenario.choices==TrainingStatus.choices,c.expected.choice==(try c.legality.status()).label else{try c.fail("the classification differs from the oracle")}
        try c.requireNoAction(false)
    }
    private static func validateMateThreat(_ c:BeginnerContext)throws {
        let scenario=c.scenario,accepted=c.accepted,create=c.check == .mateThreatCreate
        guard !accepted.isEmpty,accepted.count<c.legal.count else{try c.fail("some moves must succeed and some must fail")}
        guard scenario.nodes?.count==1 else{try c.fail("a mate-threat task is one decision")}
        try c.requireNoAction(false)
        if create{guard try c.legality.matingMoves().isEmpty else{try c.fail("with a mate in one available this is a mate-in-one task")}}
        if let validator=c.validator {
            let found=try validator.threat(scenario,create:create)
            guard Set(found.accepted)==accepted,c.root?.replies==found.replies else{try c.fail("mate-threat answers differ from the exact one-reply query: \(found.accepted)")}
            if !create{guard found.opponentThreat else{try c.fail("the opponent must threaten mate now")}}
        }
    }
    private static func validateMoment(_ c:BeginnerContext)throws {
        let scenario=c.scenario,accepted=c.accepted
        // Re-derived exactly, cheaply enough to run whenever a moment is staged or resumed.
        guard let root=c.root,scenario.nodes?.count==1,!accepted.isEmpty,accepted.count<c.legal.count else{try c.fail("a moment is one decision with some moves right and some wrong")}
        try c.requireNoAction(false)
        switch scenario.variant {
        case "mate-find":guard accepted==(try c.legality.matingMoves()),root.replies.isEmpty else{try c.fail("the accepted moves are exactly the checkmates")}
        case "mate-avoid":
            let found=try (c.validator ?? TrainingContinuationValidator(runtimeFactory:c.runtimeFactory)).threat(scenario,create:false)
            // The learner's own move created the threat, so none need exist yet; the answers are re-derived exactly.
            guard Set(found.accepted)==accepted,root.replies==found.replies else{try c.fail("the accepted moves are exactly those that allow no mate in one")}
        default:try c.fail("unknown moment")
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
