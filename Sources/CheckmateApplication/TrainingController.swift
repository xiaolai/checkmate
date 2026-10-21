import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import Foundation
import Combine
/// A training exercise staged before the workspace changes (plan rule 1): its scenario is chosen, validated and its
/// evaluator built, so a failure leaves the current activity exactly as it was.
public struct PreparedTrainingExercise {
    fileprivate let definition:TrainingEntryDefinition,scenario:TrainingScenario,freshness:TrainingFreshness
    fileprivate let legality:TrainingLegality?
    /// A resume: the saved attempt it was rebuilt from and the rebuilt exercise, together, so one is never used without
    /// the other. It is entered only while `source` is still the saved attempt.
    struct Resumption {let source:TrainingSessionSnapshot,exercise:TrainingController.Exercise}
    fileprivate let resumed:Resumption?
    /// Practice: a moment from the learner's own guided game, or a board tried before. Never first-try evidence.
    fileprivate let retry:Bool
    init(definition:TrainingEntryDefinition,scenario:TrainingScenario,freshness:TrainingFreshness,legality:TrainingLegality?,resumed:Resumption?,retry:Bool=false){self.definition=definition;self.scenario=scenario;self.freshness=freshness;self.legality=legality;self.resumed=resumed;self.retry=retry}
    public var entry:String {definition.id}
}
/// Owns the new-exercise lifecycle (plan rule 7): one reducer for selection, submission, hints, reveal, retry and
/// leaving. Every change advances the revision and is saved with the global state; results never mutate a stale
/// exercise. Existing mini-games keep their own controller (`LearningPlayer`) and board.
@MainActor public final class TrainingController:ObservableObject {
    /// `suspended`: the scenario failed a runtime check and was withdrawn; nothing was counted. `ended`: a guided game
    /// the learner ended; it is neither won nor lost.
    public enum Status:String {case active,correct,incorrect,revealed,suspended,ended}
    /// The exercise shown, with its runtime evaluator. `board` is what the learner sees now.
    public struct Exercise {
        public let definition:TrainingEntryDefinition
        public internal(set) var snapshot:TrainingSessionSnapshot
        let legality:TrainingLegality?
        public internal(set) var board:Position,drillState:MovementDrill.State?
        public internal(set) var selection:[String]=[],picked:String?,pendingPromotion:(from:String,to:String)?
        public internal(set) var status:Status = .active,feedback="",hintLevel=0,hintText:String?,hintSquares:[String]=[],solution:String?
        public internal(set) var lastMove:(from:String,to:String)?
        /// Increment B: the teaching node the learner decides at, the diagnosis stage (0 concern, 1 action), the moves
        /// played in this attempt after the context moves (learner moves and replies) and the rules at that position.
        public internal(set) var node=0,stage=0,line:[String]=[]
        var current:TrainingLegality?
        /// The square a pawn may capture on en passant in the position the learner moves in now, or nil.
        @MainActor public var enPassant:String? {(current ?? legality)?.enPassant}
        /// Playable games: why play is paused (the defender failed, or the game grew too long to save), the break
        /// reminder after many moves, and a draw the learner may claim now.
        public internal(set) var paused:String?,reminder=false,claimable:String?
        /// Guided games: a habit worth reviewing after the learner's last move (a heuristic, never a verdict), and the
        /// exact moments found while playing, to retry after the game.
        public internal(set) var habit:String?,moments:[TrainingMoment]=[]
        /// Games: the parity of the learner's plies in the line, from the validated start (0 when the learner moves first).
        var parity=0
        /// A `promoteAndHold` game's tracked pawn (mini-game plan D3): at the start, then after each ply of the line.
        var pawns:[PositionGamePawn]=[]
        /// How the learner answers now.
        public var task:TrainingTask {
            if let check=scenario.check{return check == .diagnosis && stage==1 ? .move:check.task}
            switch definition.objective {case .findAttackers,.findDefenders,.kingSafeSquares:return .select;case .classifyStatus:return .choose;default:return .move}
        }
        public var scenario:TrainingScenario {snapshot.scenario}
        public var movesUsed:Int {snapshot.actions.reduce(0){count,action in if case .move=action{return count+1};if case .undo=action{return count-1};return count}}
        public var finished:Bool {status != .active}
        /// The prompt for the current stage (a diagnosis asks for its action after the concern).
        public var prompt:String {scenario.check == .diagnosis && stage==1 ? Self.actionPrompt(scenario.goal):scenario.prompt}
        static func actionPrompt(_ goal:TrainingGoal?)->String {goal?.kind == .gain ? String(localized:"Now win material, or checkmate.",bundle:.checkmate):String(localized:"Now make a move that gives nothing away.",bundle:.checkmate)}
    }
    public let session:GameSession,learning:LearningPlayer
    public private(set) var provider:TrainingScenarioProvider?
    /// Why the training content could not load, if it did not; the library then shows only the existing games.
    public private(set) var contentError:String?
    @Published public internal(set) var exercise:Exercise?
    /// A message for the library: a failed start or resume, or a save that could not be written.
    @Published public private(set) var notice:String?
    public var now:()->Date={Date()}
    public var calendar=Calendar.current
    public var seed:()->UInt64={UInt64.random(in:1...UInt64.max)}
    public var runtimeFactory:(() throws -> any ChessScriptRuntime)?
    /// Each committed ply, the learner's or the defender's, once it is recorded: the window animates, sounds and
    /// announces it, as practice's `GameSession.onMove` does. A slip, a pending promotion or a refused save never lands.
    public var onMove:((MoveRecord)->Void)?
    /// The committed `outcome`, played from `before`, as the move record `onMove` takes.
    func landed(_ outcome:MoveOutcome,from before:String){onMove?(MoveRecord(color:outcome.color,from:outcome.from,to:outcome.to,piece:outcome.piece,flags:outcome.flags,san:outcome.san,before:before,after:outcome.after,captured:outcome.captured,promotion:outcome.promotion))}
    /// The practice defender for playable games; the composition injects the engine.
    public let games=TrainingEndgameController()
    /// A saved attempt holds at most this many actions (`TrainingState.validate`); further actions are refused.
    static let maximumSavedActions=TrainingState.maximumActions
    /// The finished guided game whose moment is being retried, so the learner can return to its other moments.
    public internal(set) var guidedReview:Exercise?
    private var publishDeferred=false
    public init(session:GameSession,learning:LearningPlayer,provider:TrainingScenarioProvider?=nil){
        self.session=session;self.learning=learning
        if let provider{self.provider=provider}else{do{self.provider=try TrainingScenarioProvider.bundled()}catch{contentError=userFacing(error)}}
    }
    func userFacing(_ error:Error)->String {(error as? CheckmateError)?.description ?? String(localized:"Training content could not be loaded.",bundle:.checkmate)}
    public var catalog:TrainingCatalog? {provider?.catalog}
    public var training:TrainingState {session.state.training ?? TrainingState()}
    /// Whether this exercise is the activity shown (the board may belong to a review opened over it).
    var showing:Bool {if case .training(let entry)=session.activity.place{return entry==exercise?.definition.id};return false}
    var interactive:Bool {showing && !session.reviewSuspended}
    // MARK: Navigation
    /// Shows the library. An unfinished exercise stays saved for Continue.
    public func openLibrary(){learning.pause();games.cancel();exercise=nil;guidedReview=nil;go(.trainingLibrary);publish()}
    /// The saved unfinished exercise the library offers as Continue, if training records are writable. One from a newer
    /// version (`TrainingState.newerActive`) is never offered.
    public var resumable:TrainingSessionSnapshot? {session.state.trainingWritable ? training.active:nil}
    /// What the library says about records kept for a newer version of Checkmate; empty when there are none.
    public var keptForNewerVersion:[String] {
        let training=training,retries=training.newerRetryCount
        var lines:[String]=[]
        if training.newerActive != nil{lines.append(String(localized:"An unfinished exercise from a newer version of Checkmate is kept for it. Until it is finished there, an exercise started here cannot be continued after you leave it.",bundle:.checkmate))}
        if retries>0{lines.append(retries==1 ? String(localized:"A suggested board from a newer version of Checkmate is kept for it.",bundle:.checkmate):String(localized:"\(retries) suggested boards from a newer version of Checkmate are kept for it.",bundle:.checkmate))}
        return lines
    }
    /// Stages a new exercise for `entry`. Throws (and changes nothing) when the content is unavailable or invalid.
    /// `generatedTier` applies to generated drills only; curated content is chosen regardless of its descriptive tier.
    public func prepare(entry id:String,generatedTier:Int=1,variant:String?=nil)throws -> PreparedTrainingExercise {
        guard let provider,let definition=provider.catalog.entry(id),definition.objective != .legacyGame else{throw CheckmateError.unavailable(contentError ?? String(localized:"This training entry is not available.",bundle:.checkmate))}
        guard TrainingTools.offered(definition) else{throw CheckmateError.unavailable(String(localized:"This training entry is not offered yet.",bundle:.checkmate))}
        guard session.state.trainingWritable else{throw CheckmateError.unavailable(String(localized:"Training progress is read-only until its saved record is recovered.",bundle:.checkmate))}
        let seen=Set(training.summaries[id]?.clusters ?? [])
        // A scenario that fails runtime validation is withdrawn for the session and another is tried.
        for _ in 0..<8 {
            switch provider.next(for:definition,seen:seen,seed:seed(),generatedTier:generatedTier,variant:variant,previous:definition.objective == .mixedPractice ? previousMixedSkill:nil) {
            case .exhausted:throw CheckmateError.unavailable(String(localized:"No new board could be made this time. Try again.",bundle:.checkmate))
            case .scenario(let scenario,let freshness):
                do{try TrainingValidationService.validate(scenario,definition:definition,runtimeFactory:runtimeFactory);return PreparedTrainingExercise(definition:definition,scenario:scenario,freshness:freshness,legality:try legality(for:scenario),resumed:nil)}
                catch{if scenario.review != nil{provider.suspend(scenario.id)}}
            }
        }
        throw CheckmateError.unavailable(String(localized:"This training entry could not prepare a valid exercise.",bundle:.checkmate))
    }
    /// Stages one named curated scenario, such as an existing game's normal-chess bridge.
    public func prepare(scenario id:String)throws -> PreparedTrainingExercise {
        guard let provider,let scenario=provider.scenario(id),let definition=provider.catalog.entry(scenario.entry) else{throw CheckmateError.unavailable(contentError ?? String(localized:"This exercise is not available.",bundle:.checkmate))}
        guard TrainingTools.offered(definition) else{throw CheckmateError.unavailable(String(localized:"This training entry is not offered yet.",bundle:.checkmate))}
        guard session.state.trainingWritable else{throw CheckmateError.unavailable(String(localized:"Training progress is read-only until its saved record is recovered.",bundle:.checkmate))}
        try TrainingValidationService.validate(scenario,definition:definition,runtimeFactory:runtimeFactory)
        let seen=Set(training.summaries[definition.id]?.clusters ?? [])
        return PreparedTrainingExercise(definition:definition,scenario:scenario,freshness:seen.contains(scenario.cluster) ? .repeat:.new,legality:try legality(for:scenario),resumed:nil)
    }
    /// Stages the saved unfinished exercise: its concrete scenario is revalidated and its actions replayed first.
    public func prepareResume()throws -> PreparedTrainingExercise {
        guard let snapshot=resumable,let provider,let definition=provider.catalog.entry(snapshot.entry) else{throw CheckmateError.unavailable(String(localized:"There is no saved exercise to continue.",bundle:.checkmate))}
        guard TrainingTools.offered(definition) else{throw CheckmateError.unavailable(String(localized:"This training entry is not offered yet.",bundle:.checkmate))}
        try TrainingValidationService.validate(snapshot.scenario,definition:definition,runtimeFactory:runtimeFactory)
        let rules=try legality(for:snapshot.scenario)
        let exercise=try replay(snapshot,definition:definition,legality:rules)
        return PreparedTrainingExercise(definition:definition,scenario:snapshot.scenario,freshness:TrainingFreshness(rawValue:snapshot.freshness) ?? .new,legality:rules,resumed:PreparedTrainingExercise.Resumption(source:snapshot,exercise:exercise))
    }
    /// Stages a queued board for another try: practice, never new first-try evidence.
    public func prepareRetry(id:String)throws -> PreparedTrainingExercise {
        guard session.state.trainingWritable,let item=training.retryQueue.first(where:{$0.id==id}),let provider,let definition=provider.catalog.entry(item.entry) else{throw CheckmateError.unavailable(String(localized:"This suggestion is no longer available.",bundle:.checkmate))}
        guard TrainingTools.offered(definition) else{throw CheckmateError.unavailable(String(localized:"This training entry is not offered yet.",bundle:.checkmate))}
        try TrainingValidationService.validate(item.scenario,definition:definition,runtimeFactory:runtimeFactory)
        return PreparedTrainingExercise(definition:definition,scenario:item.scenario,freshness:.repeat,legality:try legality(for:item.scenario),resumed:nil,retry:true)
    }
    /// Retry suggestions, due ones first, each explaining why and when.
    public var suggestions:[TrainingRecommendation.Suggestion] {TrainingRecommendation.suggestions(in:training,now:now(),calendar:calendar)}
    private func legality(for scenario:TrainingScenario)throws -> TrainingLegality? {try scenario.fen.map{try TrainingLegality(fen:$0,prelude:scenario.prelude ?? [],runtimeFactory:runtimeFactory)}}
    /// An exercise checked and built against the saved record it was staged from; entering it cannot fail.
    public struct StagedExercise {let prepared:PreparedTrainingExercise,state:Exercise,base:TrainingState,record:TrainingState?}
    /// Stages an exercise without changing anything. Starting a new one while another is unfinished records that one as
    /// abandoned: a resume whose saved attempt changed since it was prepared, an attempt that cannot be recorded, or an
    /// exercise its first save would refuse (`nextSaved`) throws here, before any workspace is left.
    public func stage(_ prepared:PreparedTrainingExercise)throws -> StagedExercise {
        var staged=session.state,abandoning=false
        let state:Exercise
        if let resumed=prepared.resumed {
            // The replay was built from `source`. A saved attempt that changed since holds progress the replay lacks:
            // entering the replay would save over it, so the resume is refused and Continue prepares from the new one.
            guard training.active==resumed.source else{throw CheckmateError.unavailable(String(localized:"The saved exercise changed while it was being opened, so it was not continued. Choose Continue again; your progress is unchanged.",bundle:.checkmate))}
            state=resumed.exercise
        } else {
            // An unfinished attempt that cannot be recorded as abandoned is never overwritten by the new one.
            if let old=training.active,staged.trainingWritable {
                do{try TrainingStore.finish(old,outcome:.abandoned,in:&staged,now:now(),calendar:calendar);abandoning=true}
                catch{throw CheckmateError.unavailable(Sentences.join(String(localized:"The unfinished exercise could not be recorded: \(userFacing(error))",bundle:.checkmate,comment:"The value is the reason, a whole sentence"),String(localized:"Your progress is unchanged.",bundle:.checkmate)))}
            }
            let retry=prepared.retry || TrainingStore.attempted(prepared.scenario,in:training),id=UUID().uuidString
            let snapshot=TrainingSessionSnapshot(id:id,entry:prepared.definition.id,scenario:prepared.scenario,freshness:prepared.freshness.rawValue,startedAt:now(),retry:retry,opponent:frozenOpponent(prepared.scenario,attempt:id))
            do{state=try initial(prepared.definition,snapshot:snapshot,legality:prepared.legality)}catch{throw CheckmateError.unavailable(Sentences.join(String(localized:"This exercise could not be started: \(userFacing(error))",bundle:.checkmate,comment:"The value is the reason, a whole sentence"),String(localized:"Your progress is unchanged.",bundle:.checkmate)))}
        }
        // `begin(staged:)` saves `state` first, after the workspace is left: the same rule `save` applies is checked
        // here, against the record it will be saved into, so that save cannot be refused (a resumed attempt already
        // at the revision bound, too many actions, or over the storage budget).
        guard Self.nextSaved(state.snapshot,in:staged.training ?? TrainingState(),writable:staged.trainingWritable) != nil else{throw CheckmateError.unavailable(String(localized:"This exercise can no longer be saved, so it was not opened. Your progress is unchanged.",bundle:.checkmate))}
        return StagedExercise(prepared:prepared,state:state,base:training,record:abandoning ? staged.training:nil)
    }
    /// Stages and enters an exercise; a refusal changes nothing and says why.
    public func begin(_ prepared:PreparedTrainingExercise){
        do{begin(staged:try stage(prepared))}catch{refuse(userFacing(error))}
    }
    /// Whether `staged` was built against the training record saved now. Entering it otherwise would save over progress
    /// made since, so a caller checks this before leaving the current activity.
    public func isCurrent(_ staged:StagedExercise)->Bool {training==staged.base}
    /// Enters a staged exercise; it cannot fail. Every refusal happened while staging, and the caller has checked
    /// `isCurrent` with nothing in between that changes the record: a stale one here is a programming error.
    public func begin(staged:StagedExercise){
        precondition(isCurrent(staged),"A staged training exercise was entered after the training record changed.")
        let state=staged.state
        learning.pause();games.cancel()
        if staged.prepared.scenario.check != .moment{guidedReview=nil}
        if let record=staged.record{session.state.training=record}
        exercise=state;notice=nil
        go(.training(entry:staged.prepared.definition.id))
        // A resumed game whose last saved move was the learner's asks the defender again; a pending reply is never replayed.
        if save(state),state.task == .game{requestReply()}
    }
    /// Opens an existing mini-game from the library: its one saved board, resumed, or replaced by an explicit restart.
    public func playLegacy(_ kind:MiniGameKind,restart:Bool=false){exercise=nil;learning.startMini(kind,restart:restart,fromLibrary:true)}
    func go(_ place:Place){if var visit=session.activity.review{visit.returnTo=place;session.enter(.reviewing(visit))}else{session.enter(.at(place))}}
    // MARK: Exercise state
    /// Throws when the position cannot be read: an exercise never starts on an empty or guessed board.
    private func initial(_ definition:TrainingEntryDefinition,snapshot:TrainingSessionSnapshot,legality:TrainingLegality?)throws -> Exercise {
        let scenario=snapshot.scenario
        let board=try scenario.drill.map{$0.board($0.initial)} ?? scenario.diagram ?? legality?.board() ?? [:]
        var state=Exercise(definition:definition,snapshot:snapshot,legality:legality,board:board,drillState:scenario.drill?.initial)
        if scenario.check != nil{state.current=legality;if state.task == .game{state.claimable=try legality?.claimableDraw();state.parity=try legality?.turn()==scenario.learner ? 0:1}}
        // Validation admitted exactly one learner pawn: it is the pawn followed.
        if scenario.check == .positionGame,scenario.goal?.kind == .promoteAndHold {
            guard let square=board.first(where:{$0.value==scenario.learner+"p"})?.key else{throw CheckmateError.invalid(String(localized:"A pawn race needs its pawn.",bundle:.checkmate))}
            state.pawns=[.pawn(square)]
        }
        return state
    }
    /// Rebuilds an attempt from its actions on the concrete scenario; any action that no longer applies fails it.
    private func replay(_ snapshot:TrainingSessionSnapshot,definition:TrainingEntryDefinition,legality:TrainingLegality?)throws -> Exercise {
        var state=try initial(definition,snapshot:TrainingSessionSnapshot(id:snapshot.id,entry:snapshot.entry,scenario:snapshot.scenario,freshness:snapshot.freshness,revision:0,startedAt:snapshot.startedAt,retry:snapshot.retry,opponent:snapshot.settledOpponent),legality:legality)
        var path=state.scenario.drill.map{[$0.initial]} ?? []
        for action in snapshot.actions {
            switch action {
            case .move(let from,let to,let promotion) where state.task == .game:try replayGameMove(&state,uci:from+to+(promotion ?? ""))
            case .reply(let move) where state.task == .game:try replayGameReply(&state,move)
            case .undo where state.task == .game:try replayGameUndo(&state)
            case .move(let from,let to,let promotion) where state.scenario.check != nil:try replayMove(&state,uci:from+to+(promotion ?? ""))
            case .move,.undo:
                guard let drill=state.scenario.drill else{throw CheckmateError.invalid(String(localized:"A saved move no longer applies.",bundle:.checkmate))}
                try Self.drillStep(drill,&path,action)
                let reached=path.last ?? drill.initial
                state.drillState=reached;state.board=drill.board(reached)
                if case .move(let from,let to,_)=action{state.lastMove=(from,to)}else{state.lastMove=nil}
            case .hint(let level):state.hintLevel=level
            case .reply(let move):try replayReply(&state,move)
            case .choose(let option) where state.scenario.check == .diagnosis && state.stage==0:try replayConcern(&state,option)
            default:throw CheckmateError.invalid(String(localized:"A finished attempt cannot be resumed.",bundle:.checkmate))
            }
            state.snapshot.actions.append(action)
        }
        guard !awaitingReply(state) else{throw CheckmateError.invalid(String(localized:"A saved move is missing its reply.",bundle:.checkmate))}
        state.snapshot.recordedHelp=snapshot.recordedHelp;state.snapshot.revision=snapshot.revision
        if state.hintLevel>0{if state.task == .game{restoreGameHint(&state)}else{applyHint(&state,level:state.hintLevel)}}
        return state
    }
    /// The drill states an attempt's actions reach, oldest first: a move pushes the state it reaches, an undo pops one.
    /// Shared by undo and resume; throws when a move no longer applies or an undo has nothing to take back.
    private static func drillPath(_ drill:MovementDrill,_ actions:[TrainingAction])throws -> [MovementDrill.State] {
        var path=[drill.initial]
        for action in actions{try drillStep(drill,&path,action)}
        return path
    }
    /// Applies one action to a drill path: a move pushes the state it reaches, an undo pops one, anything else is kept.
    private static func drillStep(_ drill:MovementDrill,_ path:inout [MovementDrill.State],_ action:TrainingAction)throws {
        switch action {
        case .move(let from,let to,_):guard let last=path.last,last.square==from,let next=drill.apply(last,to:to) else{throw CheckmateError.invalid(String(localized:"A saved move no longer applies.",bundle:.checkmate))};path.append(next)
        case .undo:guard path.count>1 else{throw CheckmateError.invalid(String(localized:"A saved undo no longer applies.",bundle:.checkmate))};path.removeLast()
        default:break
        }
    }
    // MARK: Learner actions
    /// A square chosen on the board: toggles a set answer, or picks and moves a piece. Never grades a set task.
    public func click(_ square:String){
        guard interactive,var state=exercise,!state.finished,ChessNotation.validSquare(square) else{return}
        if state.scenario.check != nil{clickBeginner(square);return}
        switch state.definition.objective {
        case .findAttackers,.findDefenders,.kingSafeSquares:toggle(&state,square);exercise=state;publish()
        case .reachTarget:
            guard state.scenario.drill != nil,let current=state.drillState else{return}
            if square==current.square{state.picked=state.picked==nil ? square:nil;exercise=state;publish();return}
            exercise=state;attempt(from:current.square,to:square,promotion:nil)
        case .mateInOne,.escapeCheck:
            let mover=state.scenario.learner
            if let from=state.picked,from != square,state.board[square]?.hasPrefix(mover) != true{attempt(from:from,to:square,promotion:nil);return}
            pick(&state,square);exercise=state;publish()
        default:break
        }
    }
    /// Adds `square` to a set answer, or removes it. Never grades.
    func toggle(_ state:inout Exercise,_ square:String){
        if let index=state.selection.firstIndex(of:square){state.selection.remove(at:index)}else{state.selection.append(square)}
        state.feedback=""
    }
    /// Picks the learner's own piece on `square` (choosing it again drops it); any other piece is explained.
    func pick(_ state:inout Exercise,_ square:String){
        let mover=state.scenario.learner
        state.picked=state.board[square]?.hasPrefix(mover)==true && state.picked != square ? square:nil
        state.feedback=state.picked==nil && state.board[square] != nil && state.board[square]?.hasPrefix(mover) != true ? String(localized:"Select one of your own pieces.",bundle:.checkmate):""
    }
    /// A graded attempt that is not a legal move: a selection slip or a promotion choice counts nothing; a rule error is
    /// graded by the objective's illegal-input policy, with `ending` after a counted one.
    func gradeNonlegal(_ grade:TrainingMoveGrade,_ state:Exercise,from:String,to:String,promotion:String?,ending:String=""){
        var state=state
        switch grade {
        case .selection(let message):state.feedback=message;exercise=state;publish()
        case .needsPromotion:state.pendingPromotion=(from,to);state.feedback=String(localized:"Choose a piece to promote to.",bundle:.checkmate);exercise=state;publish()
        case .ruleError(let reason) where state.definition.illegalInput == .ruleError:state.snapshot.actions.append(.move(from:from,to:to,promotion:promotion));state.feedback=Sentences.join(reason,String(localized:"The board has not changed.",bundle:.checkmate),ending);finish(state,.incorrect)
        case .ruleError(let reason):state.feedback=Sentences.join(reason,String(localized:"That move is not legal here, so it was not counted.",bundle:.checkmate));exercise=state;publish()
        case .legal:break
        }
    }
    /// What recording an agent's help did (mini-game plan D5). Only `recorded` and `alreadyRecorded` leave the shown
    /// attempt recorded as helped (`helped`); every other outcome recorded nothing, and the caller must not apply or
    /// disclose the help: graded, it would count as the learner's unassisted work.
    public enum AgentHelpOutcome:String,Equatable,CaseIterable {
        /// Saved now: the attempt's revision advanced by one.
        case recorded
        /// The attempt was already recorded as helped; nothing was saved.
        case alreadyRecorded
        /// The defender is choosing its reply: saving would advance the revision its reply was asked for.
        case defenderThinking
        /// The attempt has ended.
        case finished
        /// No attempt is shown, or a review over it owns the board.
        case stale
        /// The attempt could no longer be saved: too many actions, the revision bound, or the storage budget.
        case storageFull
        /// Training records are read-only, so no help can be recorded.
        case unwritable
        public var helped:Bool {self == .recorded || self == .alreadyRecorded}
    }
    /// An agent's submission, hint or coaching on the learner's behalf: the attempt is recorded as helped before it
    /// applies. Refused while the defender is thinking: saving would advance the revision its pending reply was asked
    /// for. An exercise starts and resumes only while training is writable, so `unwritable` is a guard, not a path.
    @discardableResult public func recordAgentHelp()->AgentHelpOutcome {
        guard interactive,var state=exercise else{return .stale}
        guard !state.finished else{return .finished}
        guard !games.thinking else{return .defenderThinking}
        guard session.state.trainingWritable else{return .unwritable}
        guard !state.snapshot.recordedHelp else{return .alreadyRecorded}
        state.snapshot.recordedHelp=true;return save(state) ? .recorded:.storageFull
    }
    /// Replaces the selected squares, as an agent relaying the learner's choice does. Never grades.
    public func replaceSelection(_ squares:[String]){guard interactive,var state=exercise,!state.finished,state.task == .select else{return};state.selection=Array(Set(squares.filter(ChessNotation.validSquare))).sorted();exercise=state;publish()}
    /// Closing the promotion chooser without a piece is a selection correction: nothing is counted.
    public func cancelPromotion(){guard interactive,var state=exercise,!state.finished,state.pendingPromotion != nil else{return};state.pendingPromotion=nil;state.feedback=String(localized:"Promotion canceled. Nothing was counted.",bundle:.checkmate);exercise=state;publish()}
    public func clearSelection(){guard interactive,var state=exercise,!state.finished else{return};state.selection=[];state.picked=nil;exercise=state;publish()}
    /// Grades the selected squares (or none) as the learner's whole answer.
    public func submit(none:Bool=false){
        guard interactive,var state=exercise,!state.finished,state.task == .select else{return}
        let answer=none ? []:state.selection
        do {
            let expected=try correctSquares(state)
            state.snapshot.actions.append(.submit(squares:answer.sorted()))
            let right=Set(answer)==expected && answer.count==expected.count
            state.feedback=right ? Sentences.join(String(localized:"Correct.",bundle:.checkmate),state.scenario.explanation):none ? (expected.isEmpty ? "":String(localized:"There is at least one. Look again.",bundle:.checkmate)):String(localized:"Not quite: some of your squares are wrong or missing.",bundle:.checkmate)
            finish(state,right ? .correct:.incorrect)
        }catch{fault()}
    }
    public func choose(_ option:String){
        guard interactive,var state=exercise,!state.finished,state.task == .choose,(state.scenario.choices ?? []).contains(option) else{return}
        if state.scenario.check != nil{chooseBeginner(option);return}
        do {
            let status=try state.legality?.status() ?? .neither
            state.snapshot.actions.append(.choose(option))
            let right=option==status.label
            state.feedback=right ? Sentences.join(String(localized:"Correct.",bundle:.checkmate),state.scenario.explanation):String(localized:"Not quite. Is the king under attack, and does the side to move have a legal move?",bundle:.checkmate)
            finish(state,right ? .correct:.incorrect)
        }catch{fault()}
    }
    /// A raw move attempt from a click pair, a drag or an agent. Graded per the objective's illegal-input policy.
    public func attempt(from:String,to:String,promotion:String?){
        guard interactive,var state=exercise,!state.finished else{return}
        if state.task == .game{gameAttempt(from:from,to:to,promotion:promotion);return}
        if state.scenario.check != nil{attemptBeginner(from:from,to:to,promotion:promotion);return}
        state.picked=nil;state.pendingPromotion=nil
        switch state.definition.objective {
        case .reachTarget:
            guard let drill=state.scenario.drill,let current=state.drillState,from==current.square else{state.feedback=String(localized:"Move only the marked piece.",bundle:.checkmate);exercise=state;publish();return}
            guard let next=drill.apply(current,to:to) else{state.feedback=String(localized:"The \(PieceName.of(String(drill.piece.suffix(1)))) cannot move from \(from) to \(to) here.",bundle:.checkmate);exercise=state;publish();return}
            state.drillState=next;state.board=drill.board(next);state.lastMove=(from,to);state.snapshot.actions.append(.move(from:from,to:to,promotion:nil))
            let budget=state.scenario.budget ?? .max,used=state.movesUsed,remaining=drill.distance(from:next)
            if next.square==drill.target{state.feedback=Sentences.join(String(localized:"You reached \(drill.target) in \(used) moves.",bundle:.checkmate,comment:"The first value is a board square, such as e4"),state.scenario.explanation);finish(state,.correct)}
            else if remaining.map({used+$0>budget}) ?? true{state.feedback=remaining==nil ? String(localized:"The piece can no longer reach \(drill.target) from here.",bundle:.checkmate):Sentences.join(String(localized:"\(drill.target) can no longer be reached within \(budget) moves.",bundle:.checkmate),state.scenario.explanation);finish(state,.incorrect)}
            else{state.feedback="";save(state)}
        case .mateInOne,.escapeCheck:
            guard let legality=state.legality else{return}
            do {
                let grade=try legality.grade(from:from,to:to,promotion:promotion)
                guard case .legal(let outcome)=grade else{gradeNonlegal(grade,state,from:from,to:to,promotion:promotion);return}
                let board=try boardAfter(outcome.after)
                state.snapshot.actions.append(.move(from:from,to:to,promotion:outcome.promotion));state.lastMove=(from,to);state.board=board
                let right=state.definition.objective == .escapeCheck || outcome.checkmate
                state.feedback=right ? Sentences.join(String(localized:"Correct.",bundle:.checkmate),state.scenario.explanation):outcome.check ? String(localized:"That is check, but the king can still escape, block or capture.",bundle:.checkmate):outcome.stalemate ? String(localized:"That is stalemate, a draw. Look for a move that gives check.",bundle:.checkmate):String(localized:"That move does not give check.",bundle:.checkmate)
                if finish(state,right ? .correct:.incorrect){landed(outcome,from:legality.fen)}
            }catch{fault()}
        default:break
        }
    }
    /// Concept, then relevant pieces, then the solution (plan rule 6). Any hint is recorded help. Returns whether the
    /// hint was given and recorded; when false nothing was recorded and the learner was told why where one applies.
    @discardableResult public func hint()->Bool {
        guard interactive,var state=exercise,!state.finished else{return false}
        if state.task == .game{return gameHint()}
        if state.hintLevel>=2{return reveal()}
        state.hintLevel+=1;state.snapshot.actions.append(.hint(level:state.hintLevel));state.snapshot.recordedHelp=true
        applyHint(&state,level:state.hintLevel);return save(state)
    }
    private func applyHint(_ state:inout Exercise,level:Int){
        state.hintText=state.scenario.hints.first ?? state.definition.rules.first;state.hintSquares=[]
        guard level>=2 else{return}
        do {
            switch state.definition.objective {
            case .reachTarget:if let drill=state.scenario.drill,let current=state.drillState,let distance=drill.distance(from:current){state.hintText=String(localized:"The shortest route from here takes \(distance) more moves.",bundle:.checkmate)}
            case .findAttackers,.findDefenders,.kingSafeSquares:let count=try correctSquares(state).count;state.hintText=count==0 ? String(localized:"Think carefully: is there any at all?",bundle:.checkmate):String(localized:"There are \(count) to find.",bundle:.checkmate,comment:"A hint: how many squares the learner still has to find")
            case .mateInOne:if let from=try state.legality?.matingMoves().sorted().first.map({String($0.prefix(2))}){state.hintSquares=[from];state.hintText=String(localized:"The highlighted piece can give checkmate.",bundle:.checkmate)}
            case .escapeCheck:if let legality=state.legality{let board=try legality.board(),turn=try legality.turn();if let king=board.first(where:{$0.value==turn+"k"})?.key{state.hintSquares=TrainingGeometry.attackers(of:king,color:turn=="w" ? "b":"w",board:board).sorted();state.hintText=String(localized:"The highlighted piece is giving check: move away, block the line, or capture it.",bundle:.checkmate)}}
            case .classifyStatus:if let legality=state.legality{state.hintText=try legality.status() == .check || legality.status() == .checkmate ? String(localized:"The king to move is attacked right now.",bundle:.checkmate):String(localized:"The king to move is not attacked right now.",bundle:.checkmate)}
            default:state.hintText=state.scenario.hints.dropFirst().first ?? state.hintText;state.hintSquares=state.node==0 ? state.scenario.focus ?? []:[]
            }
        }catch{state.hintText=state.scenario.hints.first}
    }
    /// Shows a correct answer and ends the attempt; a revealed attempt never counts as a success. Returns whether
    /// the attempt ended revealed.
    @discardableResult public func reveal()->Bool {
        guard interactive,var state=exercise,!state.finished,state.task != .game else{return false}
        state.snapshot.actions.append(.reveal);state.snapshot.recordedHelp=true
        do{state.solution=try solutionText(state)}catch{fault();return false}
        state.feedback=(state.solution ?? "")+" "+state.scenario.explanation;return finish(state,.revealed)
    }
    /// Takes back the last movement-drill step. Undo is recorded help.
    public func undo(){
        if interactive,let state=exercise,state.task == .game{gameUndo();return}
        guard interactive,var state=exercise,!state.finished,let drill=state.scenario.drill,state.movesUsed>0 else{return}
        do {
            let reached=try Self.drillPath(drill,state.snapshot.actions+[.undo]).last ?? drill.initial
            state.drillState=reached;state.board=drill.board(reached);state.lastMove=nil;state.picked=nil
            state.snapshot.actions.append(.undo);state.snapshot.recordedHelp=true;state.feedback=String(localized:"Move taken back.",bundle:.checkmate);save(state)
        }catch{fault()}
    }
    /// The same position again: practice, never new first-try evidence. Staged first, so a failure keeps this exercise.
    public func retry(){
        guard interactive,let state=exercise,state.finished,state.status != .suspended else{return}
        do {
            try TrainingValidationService.validate(state.scenario,definition:state.definition,runtimeFactory:runtimeFactory)
            begin(PreparedTrainingExercise(definition:state.definition,scenario:state.scenario,freshness:.repeat,legality:try legality(for:state.scenario),resumed:nil,retry:true))
        }catch{refuse(userFacing(error))}
    }
    /// A new scenario for the same entry; a generated drill keeps the current one's tier unless another is named.
    public func next(generatedTier:Int?=nil){guard interactive,let state=exercise else{return};do{begin(try prepare(entry:state.definition.id,generatedTier:generatedTier ?? state.scenario.tier))}catch{refuse(userFacing(error))}}
    /// Back to the library; an unfinished attempt stays saved for Continue, unless a newer version's attempt holds its slot.
    public func leave(){guard showing else{return};openLibrary()}
    // MARK: Evaluation
    private func correctSquares(_ state:Exercise)throws -> Set<String> {
        switch state.definition.objective {
        case .findAttackers:guard let diagram=state.scenario.diagram,let target=state.scenario.target else{return []};return TrainingGeometry.attackers(of:target,color:Character(state.scenario.learner),board:diagram)
        case .findDefenders:guard let diagram=state.scenario.diagram,let target=state.scenario.target else{return []};return TrainingGeometry.defenders(of:target,board:diagram)
        case .kingSafeSquares:guard let legality=state.legality else{throw CheckmateError.invalid(String(localized:"No position.",bundle:.checkmate))};return try legality.kingDestinations()
        default:return try beginnerSquares(state)
        }
    }
    private func solutionText(_ state:Exercise)throws -> String {
        switch state.definition.objective {
        case .findAttackers,.findDefenders,.kingSafeSquares:let squares=try correctSquares(state).sorted();return squares.isEmpty ? String(localized:"The answer is None.",bundle:.checkmate):String(localized:"The answer is \(squares.joined(separator:", ")).",bundle:.checkmate)
        case .mateInOne:let mates=Sentences.either(try state.legality?.outcomes().filter(\.checkmate).map(\.san) ?? []);return String(localized:"Checkmate: \(mates).",bundle:.checkmate,comment:"The moves that give checkmate")
        case .escapeCheck:let escapes=try state.legality?.outcomes().prefix(3).map(\.san).joined(separator:", ") ?? "";return String(localized:"Legal escapes include \(escapes).",bundle:.checkmate,comment:"Up to three moves, separated by commas")
        case .classifyStatus:let label=try state.legality?.status().label ?? String(localized:"Neither",bundle:.checkmate);return String(localized:"The answer is \(label).",bundle:.checkmate)
        case .reachTarget:
            guard let drill=state.scenario.drill,let current=state.drillState else{return ""}
            guard let route=Self.drillRoute(drill,from:current) else{return String(localized:"The piece can no longer reach \(drill.target) from here.",bundle:.checkmate)}
            let steps=route.dropFirst().reduce(route.first ?? ""){String(localized:"\($0), then \($1)",bundle:.checkmate,comment:"Steps of a route, one after the other")}
            return String(localized:"One shortest route from here: \(steps).",bundle:.checkmate)
        default:return try beginnerSolution(state)
        }
    }
    /// The squares of one shortest route from `state` to the drill's target, or nil when it cannot be reached. Each step
    /// keeps the remaining distance one shorter; passing through the target early would end the drill, so it is the last.
    static func drillRoute(_ drill:MovementDrill,from state:MovementDrill.State)->[String]? {
        guard var left=drill.distance(from:state) else{return nil}
        var route:[String]=[],at=state
        while left>0 {
            guard let step=drill.moves(at).lazy.compactMap({drill.apply(at,to:$0.to)}).first(where:{$0.square==drill.target ? left==1:left>1 && drill.distance(from:$0)==left-1}) else{return nil}
            route.append(step.square);at=step;left-=1
        }
        return route
    }
    // MARK: Recording and projection
    /// Ends the attempt `candidate` with `outcome`. The record is staged first: when it cannot be written, the shown
    /// exercise stays as it was (still active, nothing recorded) and the learner is told. Read-only training shows the
    /// result without recording it. Returns whether the attempt ended.
    @discardableResult func finish(_ candidate:Exercise,_ outcome:TrainingOutcome)->Bool {
        var state=candidate
        state.status=outcome == .correct ? .correct:outcome == .revealed ? .revealed:outcome == .abandoned ? .ended:.incorrect
        state.snapshot.revision+=1;state.snapshot.opponent?.witness=state.snapshot.revision
        var staged=session.state
        do{try TrainingStore.finish(state.snapshot,outcome:outcome,in:&staged,now:now(),calendar:calendar);session.state.training=staged.training}
        catch where session.state.trainingWritable{refuse(String(localized:"This result could not be recorded, so the exercise is still open: \(userFacing(error))",bundle:.checkmate,comment:"The value is the reason, a whole sentence"));return false}
        catch{notice=userFacing(error)}
        exercise=state;publish();session.emit(semantic:false,save:true);return true
    }
    /// A runtime fault voids the attempted action: nothing is graded or recorded, and the learner can try again.
    func fault(){guard var state=exercise else{return};state.feedback=String(localized:"Something went wrong checking that answer. Nothing was counted; please try again.",bundle:.checkmate);exercise=state;publish()}
    /// Saves `candidate` as the unfinished attempt (one atomic global save with everything else) and shows it. An
    /// attempt that could no longer be saved valid is refused: the shown exercise is kept, nothing is recorded, and
    /// the learner is told. Returns whether it was saved.
    @discardableResult func save(_ candidate:Exercise)->Bool {
        let writable=session.state.trainingWritable
        guard let snapshot=Self.nextSaved(candidate.snapshot,in:training,writable:writable) else{refuse(String(localized:"This attempt has grown too long to save, so that was not recorded. Finish it, or start again.",bundle:.checkmate));return false}
        var state=candidate;state.snapshot=snapshot
        // A newer version's attempt keeps the active slot: this one is shown and finished, but not saved for Continue.
        if writable,training.newerActive==nil{var record=training;record.active=state.snapshot;TrainingStore.prune(&record);session.state.training=record}
        exercise=state;publish();session.emit(semantic:false,save:true);return true
    }
    /// `snapshot` as the next save writes it (its revision advanced), or nil when no save may write it: more actions
    /// than are kept, a revision past the bound the loader accepts, or, where training is writable, an attempt that no
    /// longer fits `record`'s storage budget. The one rule `save` applies and `stage` checks ahead of `begin(staged:)`,
    /// so a staged exercise's first save is never refused.
    /// Every save stamps the frozen opponent's witness with the revision it writes (mini-game plan D4).
    static func nextSaved(_ snapshot:TrainingSessionSnapshot,in record:TrainingState,writable:Bool)->TrainingSessionSnapshot? {
        var next=snapshot;next.revision+=1;next.opponent?.witness=next.revision
        guard next.actions.count<=maximumSavedActions,next.revision<=TrainingState.maximumCount,!writable || TrainingStore.fits(next,in:record) else{return nil}
        return next
    }
    /// Says why something could not be done, on the exercise shown or else in the library. Nothing else changes.
    func refuse(_ message:String){notice=message;if showing,var shown=exercise{shown.feedback=message;exercise=shown};publish()}
    /// The read-only projection agents may see: the board, the learner's own selection and visible counts only.
    public func publish(){
        guard session.mode == .training,!(session.activity.place.lessonIndex == nil && learning.mini) else{return}
        guard !session.reviewSuspended else{publishDeferred=true;return};publishDeferred=false
        guard showing,let state=exercise else{session.setTraining(.library);return}
        let scenario=state.scenario,definition=state.definition
        session.setTraining(TrainingProjection(view:"exercise",entryId:definition.id,title:definition.title,objective:definition.objective.rawValue,ruleMode:definition.ruleMode.rawValue,rules:definition.rules,prompt:state.prompt,pieces:state.board,turn:state.task == .game ? (try? state.current?.turn()) ?? scenario.learner:scenario.fen != nil ? scenario.learner:nil,learnerSide:scenario.learner,target:scenario.target ?? scenario.drill?.target ?? scenario.goal?.target,selected:state.selection.isEmpty ? state.picked.map{[$0]}:state.selection,movesUsed:scenario.drill != nil ? state.movesUsed:nil,moveBudget:scenario.budget,choices:state.task == .choose ? scenario.choices:nil,status:state.status.rawValue,feedback:state.feedback.isEmpty ? nil:state.feedback,assisted:state.snapshot.recordedHelp,sessionRevision:state.snapshot.revision,attemptId:state.snapshot.id))
    }
    /// After a review closes: deliver the projection held back while the review owned the board.
    public func resumeAfterReview(){if publishDeferred{publish()};if exercise?.task == .game{requestReply()}}
    /// A review over the board owns it, as it does for practice and mini-games: a pending defender reply is cancelled
    /// (its answer is never applied) and asked for again when the review returns here.
    public func pauseForReview(){games.cancel()}
}
extension Sentences {
    /// Alternatives inside a sentence ("Qh7# or Qg7#"), each joined by a translated "or".
    static func either(_ items:[String])->String {items.dropFirst().reduce(items.first ?? ""){String(localized:"\($0) or \($1)",bundle:.checkmate,comment:"Two alternatives inside a sentence, such as two moves")}}
}
