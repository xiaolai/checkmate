import CheckmateDomain
import CheckmateRules
import Foundation
/// Playable training games (plan: Finish the Game): the learner may play every legal move against the practice
/// defender, an injected `EngineService`. A reply carries the attempt and revision it was asked for, is verified legal
/// before it is committed, and is saved as an action so a resumed game replays exactly. An engine failure pauses the
/// game; it is never counted as the learner's loss and there is no silent fallback opponent.
@MainActor public final class TrainingEndgameController {
    /// The practice defender: the bundled engine at full strength with a short think. It defends well, but it is not
    /// a perfect tablebase, and its replies are not proof of the best defence.
    public static let profile=OpponentProfile.skill(20),budget=300
    public static let defenderNote="The defender is Stockfish at full strength with a short think: it resists well, but it is not perfect."
    /// Guided games are ordinary games against a gentle opponent: Stockfish at a low skill level, which makes mistakes.
    public static let guidedProfile=OpponentProfile.skill(3)
    public static let guidedNote="Your opponent is Stockfish at a low skill level: it plays real chess but makes mistakes. Notes on your moves are things worth reviewing, not wrong answers."
    public static func profile(for check:TrainingCheck?)->OpponentProfile {check == .guidedGame ? guidedProfile:profile}
    /// What the panel says about the opponent: the attempt's frozen level when it has one (mini-game plan D4), else
    /// today's defender.
    public static func note(for check:TrainingCheck?,opponent:TrainingOpponentConfiguration?=nil)->String {
        let today=check == .guidedGame ? guidedNote:defenderNote
        guard let level=opponent?.level else{return today}
        let sentence:String
        switch level {
        case .gentle:sentence="Your opponent is Gentle: Stockfish choosing among reasonable moves, so it makes real mistakes but rarely throws the game away."
        case .steady:sentence="Your opponent is Steady: Stockfish at a low skill level. It plays real chess but makes mistakes."
        case .strong:sentence="Your opponent is Strong: Stockfish at full strength with a short think. It resists well, but it is not perfect."
        }
        return check == .guidedGame ? sentence+" Notes on your moves are things worth reviewing, not wrong answers.":sentence
    }
    /// The beginner opponent's last decision, for tests: the severe-mistake run it began with.
    var lastDecision:OpponentDecision?
    /// After this many plies a break is suggested; that is never a loss. Zero or less turns the reminder off.
    public var reminderPlies=100
    /// Beyond this many recorded actions the game pauses and takes no more hints or undos: it could no longer be saved
    /// (an attempt holds at most 512), and room is kept for the reply to the learner's last move.
    public var maximumActions=500
    static let tooLong="This game has grown too long to save, so it is paused. Nothing is counted; start again or go back."
    public var engine:EngineService?
    /// The app's network-game fairness check (LAN-play plan D8); the app sets the session's, as it sets `engine`.
    public var fairness=FairnessPolicy()
    var work:Task<Void,Never>?,hintWork:Task<Void,Never>?
    /// Advanced by every cancellation, so an answer to an older request is recognised and dropped.
    private(set) var generation=0
    /// Whether the defender is choosing its reply now: the learner's input waits.
    public internal(set) var thinking=false
    public init(engine:EngineService?=nil){self.engine=engine}
    func cancel(){work?.cancel();work=nil;hintWork?.cancel();hintWork=nil;thinking=false;generation+=1}
}
extension TrainingController {
    // MARK: Position
    /// The rules at the current game position, rebuilt from the start with the whole history (repetition included).
    func gamePosition(_ state:Exercise)throws -> TrainingLegality {
        try TrainingLegality(fen:state.scenario.fen ?? "",prelude:(state.scenario.prelude ?? [])+state.line,runtimeFactory:runtimeFactory)
    }
    private var matingPiece:(Exercise)->String {{state in state.scenario.learner+(state.scenario.variant=="krk" ? "r":"q")}}
    /// The ending, by the plan's precedence: checkmate, stalemate, loss of the mating piece, another automatic draw.
    /// Claimed draws, pauses and leaving are handled where they happen.
    func gameEnding(_ state:Exercise,_ position:TrainingLegality)throws -> (outcome:TrainingOutcome,message:String)? {
        let learner=state.scenario.learner,turn=try position.turn()
        if state.scenario.check == .positionGame {return try positionGameEnding(state,position,mover:turn=="w" ? "b":"w")}
        switch try position.status() {
        case .checkmate:return turn==learner ? (.incorrect,"You were checkmated."):(.correct,"Checkmate! "+state.scenario.explanation)
        case .stalemate:
            if turn==learner{return (.incorrect,"Stalemate: you have no legal move and are not in check, so the game is a draw.")}
            if state.scenario.check == .guidedGame{return (.incorrect,"Stalemate: your opponent has no legal move and is not in check, so the game is a draw.")}
            return (.incorrect,"Stalemate: the defender has no legal move and is not in check, so the game is a draw. Leave the king a square while you close in.")
        default:break
        }
        if state.scenario.check == .ending,try !position.board().values.contains(matingPiece(state)){return (.incorrect,"The defender captured your \(state.scenario.variant=="krk" ? "rook":"queen"). Keep it protected, or out of the king's reach.")}
        if let reason=try position.automaticDraw(){return (.incorrect,"The game is drawn: \(reason).")}
        return nil
    }
    /// A position game's ending after `mover`'s ply, by D3's closed outcome matrix (mini-game plan): the first row that
    /// matches, or nil while the game goes on.
    private func positionGameEnding(_ state:Exercise,_ position:TrainingLegality,mover:String)throws -> (outcome:TrainingOutcome,message:String)? {
        guard let goal=state.scenario.goal?.kind,goal.positionGame else{throw CheckmateError.invalid("A position game names its goal.")}
        let scenario=state.scenario,status=try position.status(),board=try position.board(),draw=try position.automaticDraw()
        guard let row=PositionGameReferee.judge(goal:goal,keep:scenario.keep ?? [],learner:scenario.learner,mover:mover,checkmate:status == .checkmate,stalemate:status == .stalemate,automaticDraw:draw,board:board,pawn:state.pawns.last) else{return nil}
        return (row.success ? .correct:.incorrect,PositionGameReferee.message(row,mover:mover,learner:scenario.learner,explanation:scenario.explanation,keep:scenario.keep ?? [],board:board,reason:draw))
    }
    /// `played`: a ply was just added, which may bring the break reminder. Hints belong to the position they were
    /// given for, so a new position clears them; the recorded help stays.
    private func refreshGame(_ state:inout Exercise,_ position:TrainingLegality,played:Bool=false)throws {
        state.current=position;state.board=try position.board();state.claimable=try position.claimableDraw()
        state.hintLevel=0;state.hintText=nil;state.hintSquares=[]
        if played,games.reminderPlies>0,state.line.count % games.reminderPlies==0{state.reminder=true}
    }
    /// Whether the learner is to move in the game shown. While the opponent is to move (thinking, or paused after a
    /// failure) the position's draw claims and hints are not the learner's.
    private func learnerToMove(_ state:Exercise)->Bool {(try? state.current?.turn())==state.scenario.learner}
    /// Adds a played ply, live or replayed: the line, the last move, the guided note for a learner's move, and the
    /// position reached. `state` changes only when all of it succeeds. Recording, saving and endings stay with the caller.
    @discardableResult private func addGamePly(_ state:inout Exercise,_ outcome:MoveOutcome,before:TrainingLegality,learner:Bool,played:Bool)throws -> TrainingLegality {
        var next=state;next.line.append(outcome.uci);next.lastMove=(outcome.from,outcome.to)
        if let pawn=next.pawns.last{next.pawns.append(pawn.after(outcome,learner:state.scenario.learner))}
        let after=try gamePosition(next)
        if learner{try noteGuided(&next,before:before,played:outcome,after:after)}
        try refreshGame(&next,after,played:played);state=next;return after
    }
    // MARK: Learner input
    func gameAttempt(from:String,to:String,promotion:String?){
        guard var state=exercise,let position=state.current else{return}
        state.picked=nil;state.pendingPromotion=nil
        guard !games.thinking else{state.feedback="Wait for the defender's reply.";exercise=state;publish();return}
        guard state.paused==nil else{exercise=state;publish();return}
        do {
            guard try position.turn()==state.scenario.learner else{return}
            guard state.snapshot.actions.count<games.maximumActions else{state.paused=TrainingEndgameController.tooLong;exercise=state;publish();return}
            switch try position.grade(from:from,to:to,promotion:promotion) {
            case .selection(let message):state.feedback=message;exercise=state;publish()
            case .needsPromotion:state.pendingPromotion=(from,to);state.feedback="Choose a piece to promote to.";exercise=state;publish()
            case .ruleError(let reason):state.feedback=reason+" That move is not legal here, so it was not counted.";exercise=state;publish()
            case .legal(let outcome):
                let after=try addGamePly(&state,outcome,before:position,learner:true,played:true)
                state.snapshot.actions.append(.move(from:from,to:to,promotion:outcome.promotion));state.feedback=""
                if let ending=try gameEnding(state,after){state.feedback=ending.message;if finish(state,ending.outcome){landed(outcome,from:position.fen)};return}
                if save(state){landed(outcome,from:position.fen);requestReply()}
            }
        }catch{fault()}
    }
    /// Asks the defender for its reply to the current position, with the whole history from the start. It plays at the
    /// attempt's frozen level (mini-game plan D4), whatever the settings say now; an attempt without one plays today's
    /// search. Gentle's seed is the attempt's with the ply, so a reply asked again is chosen the same way.
    func requestReply(){
        guard showing,let state=exercise,state.task == .game,!state.finished,state.paused==nil,let position=state.current,let mover=try? position.turn(),mover != state.scenario.learner else{return}
        guard let engine=games.engine else{pauseGame("The practice defender is not available. Try again in a moment.");return}
        guard games.fairness.engineHelpAllowed else{pauseGame(FairnessPolicy.destinationUnavailable+".");return}
        let attempt=state.snapshot.id,revision=state.snapshot.revision,start=state.scenario.fen ?? "",moves=(state.scenario.prelude ?? [])+state.line,opponent=state.snapshot.opponent
        let strategy=opponent.map{OpponentStrategy($0,check:state.scenario.check)} ?? .legacy(state.scenario.check)
        let seed=(opponent.flatMap{UInt64($0.seed,radix:16)} ?? 1) &+ UInt64(moves.count+1),streak=opponent?.severeStreak ?? 0,beginner=opponent?.strategy == .beginner,factory=runtimeFactory
        games.cancel();games.thinking=true;objectWillChange.send();publish()
        let ticket=games.generation
        games.work=Task{[weak self,fairness=games.fairness] in
            // D8, again where the search starts: participation may have begun before this task first ran.
            guard fairness.engineHelpAllowed else{return}
            // A cancelled request may end in any error, or none: only the current request's answer or failure applies.
            do {
                let result=try await strategy.choose(startFEN:start,moves:moves,engine:engine,seed:seed,severeStreak:streak,fairness:fairness,runtimeFactory:factory)
                guard !Task.isCancelled,let self,self.games.generation==ticket,self.games.fairness.engineHelpAllowed else{return}
                if beginner{self.games.lastDecision=result.opponentDecision}
                self.receiveReply(result.bestMove,attempt:attempt,revision:revision,severeStreak:beginner ? BeginnerOpponent.nextSevereStreak(result,mover:mover,current:streak):nil)
            } catch {
                guard !Task.isCancelled,let self,self.games.generation==ticket else{return}
                self.replyFailed(attempt:attempt,revision:revision)
            }
        }
    }
    /// A reply for an attempt and revision that are no longer current is discarded. `severeStreak` is Gentle's run of
    /// severe mistakes after this reply, saved with it.
    func receiveReply(_ move:String?,attempt:String,revision:Int,severeStreak:Int?=nil){
        guard var state=exercise,state.snapshot.id==attempt,state.snapshot.revision==revision,!state.finished else{return}
        games.thinking=false;games.work=nil
        do {
            guard let move,let position=state.current,let outcome=try position.outcomes().first(where:{$0.uci==move}) else{pauseGame("The practice defender returned a move that is not legal here, so the game is paused. Nothing is counted.");return}
            let after=try addGamePly(&state,outcome,before:position,learner:false,played:true)
            state.snapshot.actions.append(.reply(outcome.uci));if let severeStreak{state.snapshot.opponent?.severeStreak=severeStreak}
            // An ending that cannot be recorded keeps the position before the reply, paused so the reply can be asked again.
            if let ending=try gameEnding(state,after){state.feedback=ending.message;if finish(state,ending.outcome){landed(outcome,from:position.fen)}else{pauseGame(notice ?? TrainingEndgameController.tooLong)};return}
            state.feedback="The defender played \(outcome.san)."
            if save(state){landed(outcome,from:position.fen)}else{pauseGame(TrainingEndgameController.tooLong)}
        }catch{pauseGame("The defender's reply could not be checked, so the game is paused. Nothing is counted.")}
    }
    func replyFailed(attempt:String,revision:Int){
        guard let state=exercise,state.snapshot.id==attempt,state.snapshot.revision==revision else{return}
        games.thinking=false;games.work=nil
        pauseGame("The practice defender stopped responding, so the game is paused. Nothing is counted; try again.")
    }
    private func pauseGame(_ message:String){guard var state=exercise else{return};games.cancel();state.paused=message;state.feedback=message;exercise=state;publish()}
    /// Whether a paused game is waiting for the defender, which can be asked again. A game paused on the learner's
    /// turn (it grew too long to save) has no reply to ask for.
    public func canRetryDefender(_ state:Exercise)->Bool {state.task == .game && !state.finished && state.paused != nil && !learnerToMove(state) && state.snapshot.actions.count<Self.maximumSavedActions}
    /// After a pause, asks the defender again. The learner's position and history are unchanged.
    public func retryDefender(){
        // The reply to the learner's last move was allowed for when it was played: only the hard saved limit applies here.
        guard interactive,var state=exercise,canRetryDefender(state) else{return}
        state.paused=nil;state.feedback="";exercise=state;publish();requestReply()
    }
    /// Claims a draw by threefold repetition or the 50-move rule. A claimed draw ends the game; it is not a mate.
    public func claimDraw(){
        guard interactive,var state=exercise,state.task == .game,!state.finished,!games.thinking,learnerToMove(state),let reason=state.claimable else{return}
        state.snapshot.actions.append(.claim(reason))
        state.feedback=state.scenario.check == .positionGame ? PositionGameReferee.message(.claimedDraw,mover:state.scenario.learner,learner:state.scenario.learner,explanation:"",reason:reason):"Draw claimed by \(reason). The goal is checkmate, so this one is not solved."
        finish(state,.incorrect)
    }
    /// The break reminder after many moves: the game is already saved, so keeping going and stopping are both fine.
    public func dismissReminder(){guard var state=exercise,state.reminder else{return};state.reminder=false;exercise=state;publish()}
    /// Whether Take back has a learner move to remove and room to record it.
    public func canUndo(_ state:Exercise)->Bool {lastLearnerPly(state) != nil && state.snapshot.actions.count<games.maximumActions}
    /// The index in the line of the learner's last move, if there is one.
    private func lastLearnerPly(_ state:Exercise)->Int? {state.line.indices.last{$0 % 2==state.parity}}
    /// Removes the learner's last move, the reply to it and what was noted from them. Shared by undo and resume.
    private func takeBackGamePly(_ state:inout Exercise)throws {
        guard let index=lastLearnerPly(state) else{throw CheckmateError.invalid("A saved undo no longer applies.")}
        state.line.removeSubrange(index...);if state.pawns.count>index+1{state.pawns.removeSubrange((index+1)...)};state.lastMove=nil;state.picked=nil;state.pendingPromotion=nil;state.paused=nil;state.reminder=false;state.moments.removeAll{$0.ply>=index};state.habit=nil
        try refreshGame(&state,try gamePosition(state))
    }
    /// Takes back the learner's last move and the reply to it. Undo is recorded help.
    func gameUndo(){
        guard var state=exercise,!state.finished,lastLearnerPly(state) != nil else{return}
        guard state.snapshot.actions.count<games.maximumActions else{state.feedback=TrainingEndgameController.tooLong;exercise=state;publish();return}
        games.cancel()
        do {
            try takeBackGamePly(&state)
            state.snapshot.actions.append(.undo);state.snapshot.recordedHelp=true;state.feedback="Move taken back."
            if save(state){return}
        }catch{fault()}
        // Nothing was taken back: a reply cancelled above is asked for again.
        requestReply()
    }
    /// Concept, then the pieces that matter, then one good move from the defender's engine. All recorded help.
    /// Returns whether the hint was given and saved as recorded help; when not, nothing was recorded.
    @discardableResult func gameHint()->Bool {
        guard var state=exercise,!state.finished else{return false}
        // Saving now would advance the revision the pending reply was asked for: the learner waits for it instead.
        guard !games.thinking else{state.feedback="Wait for the defender's reply.";exercise=state;publish();return false}
        // Hints are for the learner's own move: a paused game waits for the opponent's.
        guard learnerToMove(state) else{return false}
        guard state.snapshot.actions.count<games.maximumActions else{state.feedback=TrainingEndgameController.tooLong;exercise=state;publish();return false}
        state.hintLevel=min(state.hintLevel+1,3);state.snapshot.actions.append(.hint(level:state.hintLevel));state.snapshot.recordedHelp=true
        showGameHint(&state)
        // The request is tied to the revision `save` just wrote and to the current request generation, so a later
        // move, undo, review or exercise discards (and cancels) it.
        guard save(state) else{return false}
        guard state.hintLevel==3,let saved=exercise else{return true}
        guard let engine=games.engine,games.fairness.engineHelpAllowed else{stepBackHint();return true}
        let attempt=saved.snapshot.id,revision=saved.snapshot.revision,start=state.scenario.fen ?? "",moves=(state.scenario.prelude ?? [])+state.line,ticket=games.generation
        games.hintWork?.cancel()
        games.hintWork=Task{[weak self,fairness=games.fairness] in
            // D8, again where the search starts: participation may have begun before this task first ran.
            guard fairness.engineHelpAllowed else{return}
            let result=try? await engine.analyzeHistory(startFEN:start,moves:moves,profile:TrainingEndgameController.profile,budget:TrainingEndgameController.budget,multiPv:1)
            guard !Task.isCancelled,let self,self.games.generation==ticket,self.games.fairness.engineHelpAllowed,self.interactive,var shown=self.exercise,shown.snapshot.id==attempt,shown.snapshot.revision==revision else{return}
            self.games.hintWork=nil
            guard let move=result?.bestMove,let position=shown.current,let outcome=try? position.outcomes().first(where:{$0.uci==move}) else{self.stepBackHint();return}
            shown.hintSquares=[outcome.from,outcome.to];shown.hintText="One good move: \(outcome.san).";self.exercise=shown;self.publish()
        }
        return true
    }
    /// The text and squares of the game hint at `state.hintLevel`; the third hint's move is added when the engine names one.
    private func showGameHint(_ state:inout Exercise){
        let learner=state.scenario.learner
        state.hintText=state.hintLevel==1 ? state.scenario.hints.first:state.scenario.hints.dropFirst().first ?? state.scenario.hints.first
        guard state.hintLevel>=2 else{state.hintSquares=[];return}
        switch state.scenario.check {
        case .ending?:state.hintSquares=state.board.filter{$0.value==matingPiece(state) || ($0.value.last=="k" && $0.value.first != Character(learner))}.map(\.key).sorted()
        // A position game shows the pieces it must keep and the king to mate, or the pawn (or new piece) to look after.
        case .positionGame?:
            if case .pawn(let square)?=state.pawns.last{state.hintSquares=[square]}else if case .promoted(let square)?=state.pawns.last{state.hintSquares=[square]}
            else{let keep=Set((state.scenario.keep ?? []).map{learner+$0});state.hintSquares=state.board.filter{keep.contains($0.value) || ($0.value.last=="k" && $0.value.first != Character(learner))}.map(\.key).sorted()}
        default:state.hintSquares=[]
        }
    }
    /// A resumed game shows its saved hint as it was given. The third hint's move is not saved, so it resumes as the
    /// second and the learner may ask for a move again.
    func restoreGameHint(_ state:inout Exercise){state.hintLevel=min(state.hintLevel,2);showGameHint(&state)}
    /// The third hint names a move only when the engine finds one; otherwise the learner keeps the second hint and may ask again.
    private func stepBackHint(){
        guard var shown=exercise,shown.hintLevel==3 else{return}
        shown.hintLevel=2;shown.feedback="No move could be suggested just now. Ask for a hint again to retry.";exercise=shown;publish()
    }
    // MARK: Resume
    func replayGameMove(_ state:inout Exercise,uci:String)throws {
        guard let position=state.current,try position.turn()==state.scenario.learner,let outcome=try position.outcomes().first(where:{$0.uci==uci}) else{throw CheckmateError.invalid("A saved move no longer applies.")}
        try addGamePly(&state,outcome,before:position,learner:true,played:false)
    }
    func replayGameReply(_ state:inout Exercise,_ move:String)throws {
        guard let position=state.current,try position.turn() != state.scenario.learner,let outcome=try position.outcomes().first(where:{$0.uci==move}) else{throw CheckmateError.invalid("A saved reply no longer applies.")}
        try addGamePly(&state,outcome,before:position,learner:false,played:false)
    }
    func replayGameUndo(_ state:inout Exercise)throws {try takeBackGamePly(&state)}
}
